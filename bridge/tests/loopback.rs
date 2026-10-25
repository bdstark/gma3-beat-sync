// SPDX-License-Identifier: GPL-2.0-or-later

//! The bridge on real sockets and a real Link instance that is **not** enabled: it never joins the network's
//! session, so these tests are safe to run anywhere. The session state they check is the bridge's own.

mod common;

use std::time::{Duration, Instant};

use common::{Running, Sender, phase, phase_error_us, wait_for};
use link_bridge::link::Link;
use link_bridge::publish::SessionState;
use link_bridge::server::{Config, Server};
use link_bridge_protocol::{Message, Protocol, State};

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
    sender.socket.send(b"LB3\tPING\tanything").unwrap();
    assert_eq!(sender.recv_versioned(), (Protocol::Lb2, Message::Version));
    sender.socket.send(b"LB3\tVERSION").unwrap();
    sender.socket.set_read_timeout(Some(Duration::from_millis(300))).unwrap();
    let mut buf = [0u8; 64];
    assert!(sender.socket.recv(&mut buf).is_err(), "a VERSION was answered");
    assert!((link.capture().tempo() - 130.0).abs() < 1e-6);
    let log = bridge.finish();
    assert!(log.iter().any(|l| l.contains("said goodbye")), "{log:?}");
    assert!(log.iter().any(|l| l.contains("a sender speaks LB3")), "{log:?}");
}

#[test]
fn only_loopback_addresses_are_listened_on() {
    let config = Config { listen: "192.0.2.1:7822".parse().unwrap(), enable_link: false, ..Config::default() };
    let err = Server::bind(&config).err().expect("refused");
    assert!(err.to_string().contains("loopback only"), "{err}");
    let config = Config { listen: "127.0.0.1:0".parse().unwrap(), enable_link: false, quantum: 0, ..Config::default() };
    let err = Server::bind(&config).err().expect("refused");
    assert!(err.to_string().contains("quantum 0"), "{err}");
}

/// The phase a session report gives at its own time, against the Link instance's at that time, in µs.
fn report_error_us(link: &Link, s: &link_bridge_protocol::Session) -> f64 {
    let q = f64::from(s.quantum);
    phase_error_us(link.capture().phase_at_time(s.at_us, q), s.beat.rem_euclid(q), s.bpm, q)
}

#[test]
fn an_lb2_service_gets_the_session_after_its_pongs() {
    let bridge = Running::start(false);
    let link = bridge.link.clone();
    let sender = Sender::speaking(bridge.addr, Protocol::Lb2);
    // Pongs come in LB2 (the sender checks), and the offset is as good as in LB1.
    let s = sender.clock(|| link.clock_us());
    assert!(s.offset.abs() < 1000, "off by {} µs (round trip {} µs)", s.offset, s.rtt);
    // 16 pings within a few ms: at most one report each, 50 ms apart, the first at once.
    let first = sender.next_session(Duration::from_millis(200)).expect("a session report");
    assert_eq!((first.nonce, first.seq), (sender.nonce, 1));
    assert_eq!((first.quantum, first.playing, first.peers, first.publishing), (4, None, 0, false));
    assert!((first.bpm - 120.0).abs() < 1e-9, "{first:?}");
    assert!(report_error_us(&link, &first) < 1.0, "{first:?}");
    // The pongs that came within 50 ms of it are followed by one more report when the limit allows, then nothing.
    let next = sender.next_session(Duration::from_millis(200)).expect("the report after the later pongs");
    assert_eq!(next.seq, 2);
    assert!(next.at_us - first.at_us >= 50_000, "{} µs apart", next.at_us - first.at_us);
    assert!(sender.next_session(Duration::from_millis(300)).is_none());
    sender.ping(17, || link.clock_us());
    assert_eq!(sender.next_session(Duration::from_millis(200)).map(|s| s.seq), Some(3));
    let log = bridge.finish();
    assert!(log.iter().any(|l| l.contains("reporting the session (LB2)")), "{log:?}");
}

#[test]
fn the_session_report_follows_a_change_made_by_another_peer() {
    let bridge = Running::start(false);
    let link = bridge.link.clone();
    let sender = Sender::speaking(bridge.addr, Protocol::Lb2);
    sender.ping(1, || link.clock_us());
    sender.next_session(Duration::from_millis(200)).expect("a session report");
    std::thread::sleep(Duration::from_millis(100));

    // What another peer's tempo change does to the bridge's instance: its session state changes under it.
    let mut state = link.capture();
    state.set_tempo(133.0, link.clock_us());
    let changed = Instant::now();
    link.commit(&state);
    let s = sender.next_session(Duration::from_millis(500)).expect("a report of the new tempo");
    let took = changed.elapsed();
    assert!((s.bpm - 133.0).abs() < 1e-3, "{s:?}");
    assert!(report_error_us(&link, &s) < 1.0, "{s:?}");
    assert!(took < Duration::from_millis(100), "{took:?}");
    println!("tempo change reported after {:.1} ms", took.as_secs_f64() * 1e3);

    // A phase moved by a quarter beat (113 ms at 133 BPM) is reported; the tempo stays.
    let mut state = link.capture();
    let now = link.clock_us();
    state.force_beat_at_time(state.phase_at_time(now, 4.0) + 0.25, now, 4.0);
    link.commit(&state);
    let s = sender.next_session(Duration::from_millis(500)).expect("a report of the new phase");
    assert!((s.bpm - 133.0).abs() < 1e-3 && report_error_us(&link, &s) < 1.0, "{s:?}");
    // Nothing more while nothing changes.
    assert!(sender.next_session(Duration::from_millis(300)).is_none());
    bridge.finish();
}

#[test]
fn the_report_says_when_the_session_is_this_services_and_an_lb1_service_gets_none() {
    let bridge = Running::start(false);
    let link = bridge.link.clone();
    let mut sender = Sender::speaking(bridge.addr, Protocol::Lb2);
    let offset = sender.clock(|| link.clock_us()).offset;
    while sender.next_session(Duration::from_millis(100)).is_some() {}
    sender.timeline(State::Play, link.clock_us() + offset, 7.5, 128.0, 4);
    let s =
        wait_for(Duration::from_secs(2), || sender.next_session(Duration::from_millis(100)).filter(|s| s.publishing))
            .expect("a report with publishing 1");
    assert!((s.bpm - 128.0).abs() < 1e-6, "{s:?}");
    // Goodbye ends both the publishing and the reports.
    sender.send(&Message::Bye { nonce: sender.nonce });
    assert!(sender.next_session(Duration::from_millis(300)).is_none());

    // An LB1 service: an LB1 pong, and never a report.
    let lb1 = Sender::new(bridge.addr);
    lb1.ping(1, || link.clock_us());
    assert!(lb1.next_session(Duration::from_millis(300)).is_none());
    assert!(lb1.sessions.borrow().is_empty());
    bridge.finish();
}
