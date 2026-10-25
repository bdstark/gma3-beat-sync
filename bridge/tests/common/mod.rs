// SPDX-License-Identifier: GPL-2.0-or-later

//! A bridge on a thread, and a sender speaking LB1 or LB2 to it the way gma3-phrase-sync's link sink does.

#![allow(dead_code)]

use std::cell::RefCell;
use std::net::{SocketAddr, UdpSocket};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

use link_bridge::link::Link;
use link_bridge::server::{Config, Server};
use link_bridge_protocol::{Message, Protocol, Session, State, Timeline};

/// A bridge serving on a thread until dropped.
pub struct Running {
    pub addr: SocketAddr,
    pub link: Arc<Link>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<Vec<String>>>,
}

impl Running {
    pub fn start(enable_link: bool) -> Running {
        let config = Config { listen: "127.0.0.1:0".parse().unwrap(), enable_link, ..Config::default() };
        let mut server = Server::bind(&config).unwrap();
        let addr = server.local_addr().unwrap();
        let link = server.link();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let thread = std::thread::spawn(move || {
            let mut lines = vec![];
            server.run(&flag, |l| lines.push(l.to_owned())).unwrap();
            lines
        });
        Running { addr, link, stop, thread: Some(thread) }
    }

    /// Stop the bridge and return what it logged.
    pub fn finish(mut self) -> Vec<String> {
        self.stop.store(true, Ordering::Relaxed);
        self.thread.take().unwrap().join().unwrap()
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// The service's side: a socket, a nonce, the protocol it writes, and the session reports it has received.
pub struct Sender {
    pub socket: UdpSocket,
    pub nonce: u64,
    pub protocol: Protocol,
    seq: u32,
    /// Session reports received while waiting for something else, oldest first.
    pub sessions: RefCell<Vec<Session>>,
}

/// One ping's result.
#[derive(Debug, Clone, Copy)]
pub struct Sample {
    pub rtt: i64,
    pub offset: i64,
    pub peers: u32,
}

impl Sender {
    /// A sender writing LB1, as before LB2.
    pub fn new(bridge: SocketAddr) -> Sender {
        Sender::speaking(bridge, Protocol::Lb1)
    }

    pub fn speaking(bridge: SocketAddr, protocol: Protocol) -> Sender {
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.connect(bridge).unwrap();
        socket.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        Sender { socket, nonce: 0x0000_01a2_b3c4_d5e6, protocol, seq: 0, sessions: RefCell::new(vec![]) }
    }

    pub fn send(&self, m: &Message) {
        self.socket.send(&m.encode_in(self.protocol)).unwrap();
    }

    /// The next datagram, its protocol and message.
    pub fn recv_versioned(&self) -> (Protocol, Message) {
        let mut buf = [0u8; 1500];
        let n = self.socket.recv(&mut buf).unwrap();
        Message::decode_versioned(&buf[..n]).unwrap()
    }

    /// The next session report, waiting at most `timeout`; reports received before are taken first.
    pub fn next_session(&self, timeout: Duration) -> Option<Session> {
        if !self.sessions.borrow().is_empty() {
            return Some(self.sessions.borrow_mut().remove(0));
        }
        self.socket.set_read_timeout(Some(timeout)).unwrap();
        let mut buf = [0u8; 1500];
        let got = loop {
            let Ok(n) = self.socket.recv(&mut buf) else { break None };
            if let Ok((Protocol::Lb2, Message::Session(s))) = Message::decode_versioned(&buf[..n]) {
                break Some(s);
            }
        };
        self.socket.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        got
    }

    pub fn recv(&self) -> Message {
        let mut buf = [0u8; 1500];
        let n = self.socket.recv(&mut buf).unwrap();
        Message::decode(&buf[..n]).unwrap()
    }

    /// Ping once, timing it on `clock` (µs), as the sink does: offset = bridge - (sent + rtt / 2).
    pub fn ping(&self, seq: u32, clock: impl Fn() -> i64) -> Sample {
        let sent = clock();
        self.send(&Message::Ping { nonce: self.nonce, seq, sender_us: sent });
        // Session reports (LB2) may come before the pong: the one after the previous pong, or a change.
        let reply = loop {
            let (protocol, m) = self.recv_versioned();
            match m {
                Message::Session(s) => self.sessions.borrow_mut().push(s),
                m => {
                    assert_eq!(protocol, self.protocol, "{m:?}");
                    break m;
                }
            }
        };
        let back = clock();
        let Message::Pong { nonce, seq: s, sender_us, bridge_us, peers } = reply else { panic!("{reply:?}") };
        assert_eq!((nonce, s, sender_us), (self.nonce, seq, sent));
        let rtt = back - sent;
        Sample { rtt, offset: bridge_us - (sent + rtt / 2), peers }
    }

    /// The offset from the shortest of 16 round trips.
    pub fn clock(&self, clock: impl Fn() -> i64) -> Sample {
        (1..=16).map(|seq| self.ping(seq, &clock)).min_by_key(|s| s.rtt).unwrap()
    }

    pub fn timeline(&mut self, state: State, at_us: i64, beat: f64, bpm: f64, quantum: u8) {
        self.seq += 1;
        let t = Timeline { nonce: self.nonce, seq: self.seq, state, at_us, beat, bpm, quantum };
        self.send(&Message::Timeline(t));
    }
}

/// Where the timeline (`beat` at `at_us`, `bpm`) puts the bar's phase at `t`.
pub fn phase(at_us: i64, beat: f64, bpm: f64, t: i64, quantum: f64) -> f64 {
    (beat + (t - at_us) as f64 * bpm / 60e6).rem_euclid(quantum)
}

/// The shorter distance between two phases, in µs at `bpm`.
pub fn phase_error_us(a: f64, b: f64, bpm: f64, quantum: f64) -> f64 {
    ((a - b + quantum / 2.0).rem_euclid(quantum) - quantum / 2.0).abs() * 60e6 / bpm
}

/// Poll `f` until it returns `Some` or `timeout` passes.
pub fn wait_for<T>(timeout: Duration, mut f: impl FnMut() -> Option<T>) -> Option<T> {
    let end = std::time::Instant::now() + timeout;
    loop {
        if let Some(v) = f() {
            return Some(v);
        }
        if std::time::Instant::now() > end {
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
