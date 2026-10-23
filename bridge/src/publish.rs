// SPDX-License-Identifier: GPL-2.0-or-later

//! What a timeline does to the Link session (rules 3 to 5 of "What the bridge does" in gma3-phrase-sync's
//! `docs/link-bridge.md`), on any [`SessionState`]: the library's ([`crate::link::Session`]) or a fake in the tests.

use link_bridge_protocol::{State, Timeline};

/// A tempo this close to the session's (BPM) is left alone. The service resends a tempo only when it changes by
/// 0.001 BPM, and Link carries the tempo as whole microseconds per beat, so a smaller difference is rounding.
pub const TEMPO_TOLERANCE: f64 = 0.0005;
/// A phase this close to the timeline's (µs at the tempo) is left alone, so that repeats and the few tens of
/// microseconds of clock jitter don't re-time the other peers' bars every time a timeline arrives.
pub const PHASE_TOLERANCE_US: f64 = 100.0;

/// The part of a Link session state the bridge reads and changes. Times are µs on the Link clock.
pub trait SessionState {
    /// The session's tempo, BPM.
    fn tempo(&self) -> f64;
    /// Change the tempo at `at_us`, keeping the beat there.
    fn set_tempo(&mut self, bpm: f64, at_us: i64);
    /// The phase at `at_us` in a bar of `quantum` beats, in `[0, quantum)`.
    fn phase_at_time(&self, at_us: i64, quantum: f64) -> f64;
    /// Re-time the session so that `beat` falls at `at_us` at `quantum`. Link moves the session's phase only and
    /// keeps the beat count to itself, so a jump by whole bars changes nothing for the other peers.
    fn force_beat_at_time(&mut self, beat: f64, at_us: i64, quantum: f64);
    /// Whether the session plays (with start/stop shared).
    fn is_playing(&self) -> bool;
    /// Start or stop at `at_us`.
    fn set_is_playing(&mut self, playing: bool, at_us: i64);
}

/// What applying a timeline changed in the session state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Changes {
    /// The tempo was set.
    pub tempo: bool,
    /// The phase was re-timed.
    pub phase: bool,
    /// Start (`Some(true)`) or stop (`Some(false)`) was set.
    pub playing: Option<bool>,
}

impl Changes {
    /// Whether anything changed, so the state is worth committing.
    pub fn any(&self) -> bool {
        self.tempo || self.phase || self.playing.is_some()
    }
}

/// Apply `tl` to `state` at `now_us`:
/// - `play`: the tempo becomes `bpm` (unless 0), and with a quantum the bar's phase is aligned so `beat` falls at
///   `at_us`;
/// - `stop`: the tempo only (unless 0);
/// - with `start_stop` (the bridge shares start and stop), `play` starts the session and `stop` stops it.
///
/// Nothing within [`TEMPO_TOLERANCE`] or [`PHASE_TOLERANCE_US`] is changed, so applying the same timeline twice
/// changes nothing the second time.
pub fn apply(state: &mut impl SessionState, tl: &Timeline, start_stop: bool, now_us: i64) -> Changes {
    let mut changes = Changes::default();
    if tl.bpm > 0.0 && (state.tempo() - tl.bpm).abs() > TEMPO_TOLERANCE {
        state.set_tempo(tl.bpm, tl.at_us);
        changes.tempo = true;
    }
    let playing = tl.state == State::Play;
    if playing && tl.quantum > 0 {
        let q = f64::from(tl.quantum);
        let want = tl.beat.rem_euclid(q);
        let have = state.phase_at_time(tl.at_us, q);
        // The shorter way round the bar.
        let off = (want - have + q / 2.0).rem_euclid(q) - q / 2.0;
        let tempo = state.tempo();
        if tempo > 0.0 && (off * 60e6 / tempo).abs() > PHASE_TOLERANCE_US {
            state.force_beat_at_time(tl.beat, tl.at_us, q);
            changes.phase = true;
        }
    }
    if start_stop && state.is_playing() != playing {
        state.set_is_playing(playing, now_us);
        changes.playing = Some(playing);
    }
    changes
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A session state that is a straight line: `beat0` at `t0`, at `bpm`.
    #[derive(Debug, Clone, Copy)]
    pub struct Fake {
        pub bpm: f64,
        pub beat0: f64,
        pub t0: i64,
        pub playing: bool,
    }

    impl Fake {
        pub fn new(bpm: f64) -> Fake {
            Fake { bpm, beat0: 0.0, t0: 0, playing: false }
        }

        pub fn beat_at(&self, t: i64) -> f64 {
            self.beat0 + (t - self.t0) as f64 * self.bpm / 60e6
        }
    }

    impl SessionState for Fake {
        fn tempo(&self) -> f64 {
            self.bpm
        }
        fn set_tempo(&mut self, bpm: f64, at_us: i64) {
            self.beat0 = self.beat_at(at_us);
            self.t0 = at_us;
            self.bpm = bpm;
        }
        fn phase_at_time(&self, at_us: i64, quantum: f64) -> f64 {
            self.beat_at(at_us).rem_euclid(quantum)
        }
        fn force_beat_at_time(&mut self, beat: f64, at_us: i64, _quantum: f64) {
            self.beat0 = beat;
            self.t0 = at_us;
        }
        fn is_playing(&self) -> bool {
            self.playing
        }
        fn set_is_playing(&mut self, playing: bool, _at_us: i64) {
            self.playing = playing;
        }
    }

    pub fn tl(state: State, at_us: i64, beat: f64, bpm: f64, quantum: u8) -> Timeline {
        Timeline { nonce: 1, seq: 1, state, at_us, beat, bpm, quantum }
    }

    #[test]
    fn play_sets_the_tempo_and_the_bar_phase() {
        let mut s = Fake::new(120.0);
        let c = apply(&mut s, &tl(State::Play, 5_000_000, 31.5, 126.0, 4), false, 5_000_000);
        assert_eq!(c, Changes { tempo: true, phase: true, playing: None });
        assert_eq!(s.bpm, 126.0);
        assert!((s.phase_at_time(5_000_000, 4.0) - 3.5).abs() < 1e-9);
        // Half a second later at 126 BPM: 1.05 beats on.
        assert!((s.phase_at_time(5_500_000, 4.0) - 0.55).abs() < 1e-9);
    }

    #[test]
    fn the_same_timeline_again_changes_nothing() {
        let mut s = Fake::new(120.0);
        let t = tl(State::Play, 5_000_000, 31.5, 126.0, 4);
        apply(&mut s, &t, true, 5_000_000);
        let before = s;
        // A repeat a second later, and the same line as a later beat and time.
        assert!(!apply(&mut s, &t, true, 6_000_000).any());
        assert!(!apply(&mut s, &tl(State::Play, 6_000_000, 31.5 + 2.1, 126.0, 4), true, 6_000_000).any());
        assert_eq!((s.bpm, s.beat0, s.t0, s.playing), (before.bpm, before.beat0, before.t0, before.playing));
    }

    #[test]
    fn a_jump_by_whole_bars_changes_nothing() {
        let mut s = Fake::new(126.0);
        apply(&mut s, &tl(State::Play, 0, 31.5, 126.0, 4), false, 0);
        assert!(!apply(&mut s, &tl(State::Play, 0, 31.5 + 64.0, 126.0, 4), false, 0).any());
        assert!(!apply(&mut s, &tl(State::Play, 0, 31.5 - 4.0, 126.0, 4), false, 0).any());
    }

    #[test]
    fn small_phase_errors_are_left_alone_and_larger_ones_fixed_the_short_way() {
        let mut s = Fake::new(120.0); // 500 ms a beat: 100 µs is 0.0002 beats
        // 0.0001 beats (50 µs) late: left alone.
        assert!(!apply(&mut s, &tl(State::Play, 0, 0.0001, 120.0, 4), false, 0).any());
        // Just before the bar line, 0.001 beats (500 µs) early, wraps the short way and is fixed.
        let c = apply(&mut s, &tl(State::Play, 0, 3.999, 120.0, 4), false, 0);
        assert!(c.phase);
        assert!((s.phase_at_time(0, 4.0) - 3.999).abs() < 1e-9);
    }

    #[test]
    fn quantum_0_gives_the_tempo_only() {
        let mut s = Fake::new(120.0);
        let c = apply(&mut s, &tl(State::Play, 0, 1.25, 100.0, 0), false, 0);
        assert_eq!(c, Changes { tempo: true, phase: false, playing: None });
        assert_eq!(s.phase_at_time(0, 4.0), 0.0);
    }

    #[test]
    fn stop_changes_the_tempo_only_and_bpm_0_keeps_it() {
        let mut s = Fake::new(120.0);
        let c = apply(&mut s, &tl(State::Stop, 0, 1.25, 128.0, 4), false, 0);
        assert_eq!(c, Changes { tempo: true, phase: false, playing: None });
        assert_eq!(s.bpm, 128.0);
        assert!(!apply(&mut s, &tl(State::Stop, 0, 2.0, 0.0, 4), false, 0).any());
        assert!(!apply(&mut s, &tl(State::Play, 0, 0.0, 0.0, 0), false, 0).any());
        assert_eq!(s.bpm, 128.0);
    }

    #[test]
    fn start_and_stop_only_when_shared() {
        let mut s = Fake::new(120.0);
        apply(&mut s, &tl(State::Play, 0, 0.0, 120.0, 4), false, 0);
        assert!(!s.playing);
        assert_eq!(apply(&mut s, &tl(State::Play, 0, 0.0, 120.0, 4), true, 7).playing, Some(true));
        assert!(s.playing);
        assert_eq!(apply(&mut s, &tl(State::Play, 0, 0.0, 120.0, 4), true, 8).playing, None);
        assert_eq!(apply(&mut s, &tl(State::Stop, 0, 0.0, 120.0, 4), true, 9).playing, Some(false));
        assert!(!s.playing);
    }
}
