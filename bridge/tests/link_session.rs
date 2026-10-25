// SPDX-License-Identifier: GPL-2.0-or-later

//! The bridge in a real Link session, checked through a second Link peer in this process.
//!
//! **These join the Link session on the network.** Two set its tempo and phase, so every other Link app on the network
//! (a DJ's software, a console following the session) follows them; run them only when nothing else is in the
//! session, or everything in it may be disturbed:
//!
//! ```sh
//! cargo test -p link-bridge --test link_session -- --ignored --skip watch
//! ```
//!
//! `watch_the_session` only reads: it sends no timeline and changes nothing, and prints the session reports an LB2
//! service would get from the session already on the network (another app's) for `LINK_BRIDGE_WATCH_S` seconds
//! (default 20), so a tempo change made in that app can be seen to arrive:
//!
//! ```sh
//! LINK_BRIDGE_WATCH_S=30 cargo test -p link-bridge --test link_session watch -- --ignored --nocapture
//! ```

mod common;

use std::time::{Duration, Instant};

use common::{Running, Sender, phase, phase_error_us, wait_for};
use link_bridge::link::Link;
use link_bridge::publish::SessionState;
use link_bridge_protocol::{Protocol, Session, State};

/// A second peer's bar phase may differ from the timeline's by this much: the bridge's clock offset (well under a
/// millisecond, checked here too) and Link's own measurement between the two peers.
const PHASE_TOLERANCE_US: f64 = 1000.0;

#[test]
#[ignore = "joins the Link session on the network; run with --ignored when nothing else is in it"]
fn tempo_and_phase_reach_another_peer() {
    let bridge = Running::start(true);
    let peer = Link::new(60.0);
    peer.enable(true);
    assert!(peer.is_enabled() && bridge.link.is_enabled());

    // The second peer's clock is the test's clock: the same clock as the bridge's, so the true offset is 0.
    let mut sender = Sender::new(bridge.addr);
    let sample = wait_for(Duration::from_secs(10), || {
        let s = sender.clock(|| peer.clock_us());
        (s.peers >= 1).then_some(s)
    })
    .expect("the bridge sees the second peer");
    assert!(sample.offset.abs() < 1000, "clock off by {} µs (round trip {} µs)", sample.offset, sample.rtt);
    let others = peer.peers();
    println!(
        "clock offset {} µs (true 0), round trip {} µs; the bridge sees {} peer(s), the second peer {others}",
        sample.offset, sample.rtt, sample.peers
    );

    let bpm = 126.5;
    let at = peer.clock_us() + sample.offset;
    let beat = 31.5;
    let mut last = (0.0, f64::MAX);
    // Repeat the timeline every 100 ms, as the service does at least every second, until the peer has it.
    let arrived = wait_for(Duration::from_secs(10), || {
        let now = peer.clock_us();
        sender.timeline(State::Play, now, beat + (now - at) as f64 * bpm / 60e6, bpm, 4);
        std::thread::sleep(Duration::from_millis(80));
        let s = peer.capture();
        let t = peer.clock_us();
        let err = phase_error_us(s.phase_at_time(t, 4.0), phase(at, beat, bpm, t, 4.0), bpm, 4.0);
        last = (s.tempo(), err);
        ((s.tempo() - bpm).abs() < 0.001 && err < PHASE_TOLERANCE_US).then_some(())
    });
    assert!(arrived.is_some(), "the second peer has {} BPM, phase off by {} µs", last.0, last.1);
    println!("second peer: {} BPM, phase within {:.0} µs", last.0, last.1);

    // Whole bars later in the deck's beat count (a new track): the session's bar phase stays.
    let t = peer.clock_us() + 1_000_000;
    let before = peer.capture().phase_at_time(t, 4.0);
    let now = peer.clock_us();
    sender.timeline(State::Play, now, beat + (now - at) as f64 * bpm / 60e6 + 64.0, bpm, 4);
    std::thread::sleep(Duration::from_millis(500));
    let after = peer.capture().phase_at_time(t, 4.0);
    assert!(phase_error_us(before, after, bpm, 4.0) < PHASE_TOLERANCE_US, "{before} → {after}");

    let log = bridge.finish();
    println!("{}", log.join("\n"));
}

/// The session report's phase at its own time against `peer`'s at that time (the same clock), in µs.
fn report_error_us(peer: &Link, s: &Session) -> f64 {
    let q = f64::from(s.quantum);
    phase_error_us(peer.capture().phase_at_time(s.at_us, q), s.beat.rem_euclid(q), s.bpm, q)
}

#[test]
#[ignore = "joins the Link session on the network and moves its tempo; run with --ignored when nothing else is in it"]
fn a_change_by_another_peer_reaches_the_session_report() {
    let bridge = Running::start(true);
    let peer = Link::new(60.0);
    peer.enable(true);
    let sender = Sender::speaking(bridge.addr, Protocol::Lb2);
    let mut seq = 0;
    let mut next = |sender: &Sender| {
        seq += 1;
        sender.ping(seq, || peer.clock_us());
        sender.next_session(Duration::from_millis(200))
    };
    let first = wait_for(Duration::from_secs(10), || next(&sender).filter(|s| s.peers >= 1))
        .expect("a session report that counts the second peer");
    println!("first report: {first:?}");
    assert!(!first.publishing);

    // The second peer, another app as far as the bridge knows, moves the tempo and the bar.
    let bpm = 131.5;
    let mut state = peer.capture();
    let now = peer.clock_us();
    state.set_tempo(bpm, now);
    state.force_beat_at_time(state.phase_at_time(now, 4.0) + 1.25, now, 4.0);
    let changed = Instant::now();
    peer.commit(&state);
    let s = wait_for(Duration::from_secs(5), || {
        sender.next_session(Duration::from_millis(100)).filter(|s| (s.bpm - bpm).abs() < 0.001)
    })
    .expect("a report of the new tempo");
    let took = changed.elapsed();
    let err = report_error_us(&peer, &s);
    println!(
        "report {:.1} ms after the change: {} BPM, phase within {err:.0} µs: {s:?}",
        took.as_secs_f64() * 1e3,
        s.bpm
    );
    assert!(err < PHASE_TOLERANCE_US, "phase off by {err} µs");
    assert!(!s.publishing && s.peers >= 1);
    println!("{}", bridge.finish().join("\n"));
}

#[test]
#[ignore = "joins the Link session on the network (reads only); run with --ignored --nocapture to watch it"]
fn watch_the_session() {
    let seconds: u64 = std::env::var("LINK_BRIDGE_WATCH_S").ok().and_then(|v| v.parse().ok()).unwrap_or(20);
    let bridge = Running::start(true);
    let clock = Link::new(120.0); // not enabled: only its clock is read
    let sender = Sender::speaking(bridge.addr, Protocol::Lb2);
    let start = Instant::now();
    let end = start + Duration::from_secs(seconds);
    let mut seq = 0;
    let mut reports: Vec<Session> = vec![];
    let mut next_ping = start;
    while Instant::now() < end {
        if Instant::now() >= next_ping {
            seq += 1;
            sender.ping(seq, || clock.clock_us());
            next_ping += Duration::from_secs(1);
        }
        while let Some(s) = sender.next_session(Duration::from_millis(50)) {
            let q = f64::from(s.quantum);
            println!(
                "{:7.3} s  seq {:3}  {:9.4} BPM  beat {:5.3} of {}  peers {}  playing {:?}  publishing {}",
                start.elapsed().as_secs_f64(),
                s.seq,
                s.bpm,
                s.beat.rem_euclid(q),
                s.quantum,
                s.peers,
                s.playing,
                u8::from(s.publishing)
            );
            reports.push(s);
        }
    }
    println!("{}", bridge.finish().join("\n"));
    assert!(!reports.is_empty(), "no session report");
    assert!(reports.windows(2).all(|w| w[1].seq == w[0].seq + 1 && w[1].at_us > w[0].at_us), "reports out of order");
    assert!(reports.iter().all(|s| !s.publishing), "the bridge published nothing, so nothing is this run's");
    let tempos: Vec<f64> = reports.iter().map(|s| s.bpm).collect();
    // Where each report's phase is against the one before it predicts it, for reports at the same tempo and peers
    // (joining a session moves the phase).
    let steady = reports
        .windows(2)
        .filter(|w| (w[1].bpm - w[0].bpm).abs() < 1e-9 && w[1].peers == w[0].peers)
        .map(|w| {
            let q = f64::from(w[1].quantum);
            phase_error_us(w[0].beat.rem_euclid(q), phase(w[1].at_us, w[1].beat, w[1].bpm, w[0].at_us, q), w[1].bpm, q)
        })
        .fold(0.0, f64::max);
    println!(
        "{} reports in {seconds} s; peers {}; tempo {:.4} to {:.4} BPM; at a steady tempo, phase within {steady:.1} µs of \
         the report before",
        reports.len(),
        reports.last().unwrap().peers,
        tempos.iter().cloned().fold(f64::MAX, f64::min),
        tempos.iter().cloned().fold(f64::MIN, f64::max)
    );
}
