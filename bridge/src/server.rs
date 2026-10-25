// SPDX-License-Identifier: GPL-2.0-or-later

//! The bridge on a UDP socket and a Link instance: datagrams in, pongs out, timelines into the session, and the
//! session reported to an LB2 service.

use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use link_bridge_protocol::MAX_QUANTUM;

use crate::bridge::{Bridge, Snapshot};
use crate::link::Link;
use crate::publish::{self, SessionState};

/// The address the bridge listens on by default.
pub const DEFAULT_LISTEN: &str = "127.0.0.1:7822";
/// The bar session reports count beats in by default.
pub const DEFAULT_QUANTUM: u8 = 4;
/// How long a receive waits before the loop checks the time, the session and whether to stop. Short enough that a
/// session change is seen well within the 50 ms between reports.
const RECEIVE_WAIT: Duration = Duration::from_millis(10);
/// The tempo of the Link instance's own timeline before it joins a session or a timeline arrives.
const INITIAL_BPM: f64 = 120.0;

/// How the bridge runs.
#[derive(Debug, Clone)]
pub struct Config {
    /// Where to listen: a loopback address.
    pub listen: SocketAddr,
    /// Share start and stop with the session (off by default: DJ booths rarely want the session stopped).
    pub start_stop: bool,
    /// Join the Link session. Off only in tests that must not touch the network's session.
    pub enable_link: bool,
    /// The bar session reports count beats in, 1 to 16 (Link doesn't share one).
    pub quantum: u8,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            listen: DEFAULT_LISTEN.parse().expect("a socket address"),
            start_stop: false,
            enable_link: true,
            quantum: DEFAULT_QUANTUM,
        }
    }
}

/// A bound bridge, ready to [`Server::run`].
pub struct Server {
    socket: UdpSocket,
    link: Arc<Link>,
    bridge: Bridge,
    start_stop: bool,
    quantum: u8,
    /// Where session reports go: the address of the subscriber's latest LB2 ping.
    subscriber: Option<SocketAddr>,
    /// The peers last logged.
    peers: Option<u32>,
}

impl Server {
    /// Bind the socket and create the Link instance (enabled unless `config` says otherwise).
    pub fn bind(config: &Config) -> io::Result<Server> {
        if !config.listen.ip().is_loopback() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{}: the bridge listens on loopback only (127.0.0.1 or ::1)", config.listen),
            ));
        }
        if !(1..=MAX_QUANTUM).contains(&config.quantum) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("quantum {}: must be 1 to {MAX_QUANTUM}", config.quantum),
            ));
        }
        let socket = UdpSocket::bind(config.listen)?;
        socket.set_read_timeout(Some(RECEIVE_WAIT))?;
        let link = Arc::new(Link::new(INITIAL_BPM));
        link.enable_start_stop_sync(config.start_stop);
        link.enable(config.enable_link);
        Ok(Server {
            socket,
            link,
            bridge: Bridge::new(),
            start_stop: config.start_stop,
            quantum: config.quantum,
            subscriber: None,
            peers: None,
        })
    }

    /// The address the socket is bound to.
    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.socket.local_addr()
    }

    /// The Link instance.
    pub fn link(&self) -> Arc<Link> {
        Arc::clone(&self.link)
    }

    /// Serve until `stop` is set, logging with `log`.
    pub fn run(&mut self, stop: &AtomicBool, mut log: impl FnMut(&str)) -> io::Result<()> {
        let mut buf = [0u8; 2048];
        while !stop.load(Ordering::Relaxed) {
            match self.socket.recv_from(&mut buf) {
                Ok((n, from)) => {
                    // The Link clock is read the moment the datagram is in, before anything else: a pong's time is
                    // when its ping arrived, and a reading taken late puts half the delay into the service's offset.
                    let now = self.link.clock_us();
                    self.datagram(&buf[..n], from, now, &mut log);
                }
                Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {}
                // Windows reports an ICMP port unreachable for an earlier send as an error on the next receive.
                Err(e) if e.kind() == io::ErrorKind::ConnectionReset => {}
                Err(e) => return Err(e),
            }
            for line in self.bridge.poll(self.link.clock_us()) {
                log(&line);
            }
            if !self.bridge.subscribed() {
                self.subscriber = None;
            } else if self.bridge.wants_session(self.link.clock_us()) {
                self.report(&mut log);
            }
            let peers = self.link.peers();
            if self.peers != Some(peers) {
                self.peers = Some(peers);
                log(&format!("link: {peers} other peer(s) in the session"));
            }
        }
        Ok(())
    }

    /// One datagram from `from`, received at `now_us` on the Link clock.
    fn datagram(&mut self, data: &[u8], from: SocketAddr, now_us: i64, log: &mut impl FnMut(&str)) {
        if !from.ip().is_loopback() {
            return; // only the service on this host may talk to the bridge
        }
        let out = self.bridge.receive(data, now_us, self.link.peers());
        if out.subscribe {
            self.subscriber = Some(from);
        }
        if let Some(reply) = out.reply
            && let Err(e) = self.socket.send_to(&reply, from)
        {
            log(&format!("reply to {from}: {e}"));
        }
        for line in &out.log {
            log(line);
        }
        if let Some(tl) = out.publish {
            let mut state = self.link.capture();
            let changes = publish::apply(&mut state, &tl, self.start_stop, self.link.clock_us());
            if changes.any() {
                self.link.commit(&state);
            }
        }
    }

    /// Read the session and send the subscriber a report if one is due or the session changed. Called between
    /// receives, never between a datagram's arrival and its clock reading; a capture is a short copy.
    fn report(&mut self, log: &mut impl FnMut(&str)) {
        let Some(to) = self.subscriber else { return };
        let state = self.link.capture();
        let at_us = self.link.clock_us();
        let q = f64::from(self.quantum);
        let snap = Snapshot {
            at_us,
            beat: state.beat_at_time(at_us, q),
            bpm: state.tempo(),
            quantum: self.quantum,
            // Without start/stop sharing the instance doesn't hear the other peers' start and stop.
            playing: self.start_stop.then(|| state.is_playing()),
            peers: self.link.peers(),
        };
        if let Some(report) = self.bridge.session(&snap)
            && let Err(e) = self.socket.send_to(&report, to)
        {
            log(&format!("session report to {to}: {e}"));
        }
    }
}
