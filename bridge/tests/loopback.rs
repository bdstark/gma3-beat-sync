// SPDX-License-Identifier: GPL-2.0-or-later

//! The bridge on real sockets and a real Link instance that is **not** enabled: it never joins the network's
//! session, so these tests are safe to run anywhere. The session state they check is the bridge's own.

mod common;

use std::time::Duration;

use common::{Running, Sender, phase, phase_error_us, wait_for};
use link_bridge::link::Link;
use link_bridge::publish::SessionState;
use link_bridge::server::{Config, Server};
use link_bridge_protocol::{Message, State};

/// Pongs are stamped on the Link clock as the ping arrives. Every Link instance in a process reads the same clock,
/// so the true offset between the test's clock and the bridge's is 0, and the measured one must be within 1 ms.
#[test]
fn the_clock_offset_from_pongs_is_within_a_millisecond() {
    let bridge = Running::start(false);
    let clock = Link::new(120.0);
    let sender = Sender::new(bridge.addr);
    let s = sender.clock(|| clock.clock_us());
    println!("clock offset {} µs (true 0), round trip {} µs", s.offset, s.rtt);
    assert!(s.offset.abs() < 1000, "off by {} µs (round trip {} µs)", s.offset, s.rtt);
    assert_eq!(s.peers, 0);
    bridge.finish();
}

#[test]
fn a_play_timeline_sets_the_tempo_and_the_bar_phase() {
    let bridge = Running::start(false);
    let link = bridge.link.clone();
    let mut sender = Sender::new(bridge.addr);
    let offset = sender.clock(|| link.clock_us()).offset;
    let at = link.clock_us() + offset;
    sender.timeline(State::Play, at, 31.5, 126.0, 4);
    let ok = wait_for(Duration::from_secs(2), || {
        let s = link.capture();
        let now = link.clock_us();
        let err = phase_error_us(s.phase_at_time(now, 4.0), phase(at, 31.5, 126.0, now, 4.0), 126.0, 4.0);
        ((s.tempo() - 126.0).abs() < 1e-6 && err < 100.0).then_some(())
    });
    assert!(ok.is_some(), "tempo {} BPM", link.capture().tempo());

    // A new track: the beat jumps by whole bars and the tempo stays. The bar's phase doesn't move.
    let before = link.capture().phase_at_time(at + 2_000_000, 4.0);
    sender.timeline(State::Play, at, 31.5 + 128.0, 126.0, 4);
    std::thread::sleep(Duration::from_millis(200));
    let after = link.capture().phase_at_time(at + 2_000_000, 4.0);
    assert!(phase_error_us(before, after, 126.0, 4.0) < 1.0, "{before} → {after}");

    // Stopped, at another tempo: the tempo follows, playing or not.
    sender.timeline(State::Stop, link.clock_us(), 0.0, 100.0, 0);
    assert!(
        wait_for(Duration::from_secs(2), || ((link.capture().tempo() - 100.0).abs() < 1e-6).then_some(())).is_some()
    );

    let log = bridge.finish();
    assert!(log.iter().any(|l| l.contains("publishing (play, 126 BPM, quantum 4)")), "{log:?}");
}

#[test]
fn bye_lets_go_and_another_protocol_gets_version() {
    let bridge = Running::start(false);
    let link = bridge.link.clone();
    let mut sender = Sender::new(bridge.addr);
    sender.timeline(State::Play, link.clock_us(), 0.0, 130.0, 4);
    sender.send(&Message::Bye { nonce: sender.nonce });
    // Later timelines of a run that said goodbye are not published.
    sender.timeline(State::Play, link.clock_us(), 0.0, 90.0, 4);
    sender.socket.send(b"LB2\tPING\tanything").unwrap();
    assert_eq!(sender.recv(), Message::Version);
    sender.socket.send(b"LB2\tVERSION").unwrap();
    sender.socket.set_read_timeout(Some(Duration::from_millis(300))).unwrap();
    let mut buf = [0u8; 64];
    assert!(sender.socket.recv(&mut buf).is_err(), "a VERSION was answered");
    assert!((link.capture().tempo() - 130.0).abs() < 1e-6);
    let log = bridge.finish();
    assert!(log.iter().any(|l| l.contains("said goodbye")), "{log:?}");
    assert!(log.iter().any(|l| l.contains("a sender speaks LB2")), "{log:?}");
}

#[test]
fn only_loopback_addresses_are_listened_on() {
    let config = Config { listen: "192.0.2.1:7822".parse().unwrap(), start_stop: false, enable_link: false };
    let err = Server::bind(&config).err().expect("refused");
    assert!(err.to_string().contains("loopback only"), "{err}");
}
