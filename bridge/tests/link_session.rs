// SPDX-License-Identifier: GPL-2.0-or-later

//! The bridge in a real Link session, checked through a second Link peer in this process.
//!
//! **This joins the Link session on the network** and sets its tempo and phase, so every other Link app on the
//! network (a DJ's software, a console following the session) follows the test. It is ignored by default; run it only
//! when nothing else is in the session, or everything in it may be disturbed:
//!
//! ```sh
//! cargo test -p link-bridge --test link_session -- --ignored
//! ```

mod common;

use std::time::Duration;

use common::{Running, Sender, phase, phase_error_us, wait_for};
use link_bridge::link::Link;
use link_bridge::publish::SessionState;
use link_bridge_protocol::State;

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
