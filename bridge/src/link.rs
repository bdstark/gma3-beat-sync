// SPDX-License-Identifier: GPL-2.0-or-later

//! Ableton's Link library through its C wrapper, `abl_link` (`modules/link/extensions/abl_link`), which `build.rs`
//! builds from the submodule. This is the crate's only unsafe code: hand-written declarations of the few functions
//! the bridge uses, and safe types around them.
//!
//! Times are in microseconds on the Link clock ([`Link::clock_us`]), the clock the library takes its timestamps on.
#![allow(unsafe_code)]

use crate::publish::SessionState;

/// The declarations from `abl_link.h` (Link-4.1).
mod ffi {
    use std::ffi::c_void;

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct AblLink {
        pub impl_: *mut c_void,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct AblSessionState {
        pub impl_: *mut c_void,
    }

    unsafe extern "C" {
        pub fn abl_link_create(bpm: f64) -> AblLink;
        pub fn abl_link_destroy(link: AblLink);
        pub fn abl_link_is_enabled(link: AblLink) -> bool;
        pub fn abl_link_enable(link: AblLink, enable: bool);
        pub fn abl_link_is_start_stop_sync_enabled(link: AblLink) -> bool;
        pub fn abl_link_enable_start_stop_sync(link: AblLink, enabled: bool);
        pub fn abl_link_num_peers(link: AblLink) -> u64;
        pub fn abl_link_clock_micros(link: AblLink) -> i64;

        pub fn abl_link_create_session_state() -> AblSessionState;
        pub fn abl_link_destroy_session_state(state: AblSessionState);
        pub fn abl_link_capture_app_session_state(link: AblLink, state: AblSessionState);
        pub fn abl_link_commit_app_session_state(link: AblLink, state: AblSessionState);
        pub fn abl_link_tempo(state: AblSessionState) -> f64;
        pub fn abl_link_set_tempo(state: AblSessionState, bpm: f64, at_time: i64);
        pub fn abl_link_beat_at_time(state: AblSessionState, time: i64, quantum: f64) -> f64;
        pub fn abl_link_phase_at_time(state: AblSessionState, time: i64, quantum: f64) -> f64;
        pub fn abl_link_force_beat_at_time(state: AblSessionState, beat: f64, time: i64, quantum: f64);
        pub fn abl_link_set_is_playing(state: AblSessionState, is_playing: bool, time: i64);
        pub fn abl_link_is_playing(state: AblSessionState) -> bool;
    }
}

/// A Link instance. It starts disabled: it joins a session on the network only after [`Link::enable`].
pub struct Link {
    raw: ffi::AblLink,
}

// The functions used here are documented thread-safe in abl_link.h (the app-thread capture and commit, not the
// audio-thread ones).
unsafe impl Send for Link {}
unsafe impl Sync for Link {}

impl Link {
    /// A new, disabled instance whose own timeline starts at `bpm`.
    pub fn new(bpm: f64) -> Link {
        // SAFETY: abl_link_create allocates a new instance (it aborts rather than return null); `Drop` destroys it.
        let raw = unsafe { ffi::abl_link_create(bpm) };
        assert!(!raw.impl_.is_null(), "abl_link_create failed");
        Link { raw }
    }

    /// Join (or leave) the session on the network.
    pub fn enable(&self, enable: bool) {
        // SAFETY: `raw` is a live instance for as long as `self`.
        unsafe { ffi::abl_link_enable(self.raw, enable) }
    }

    /// Whether the instance is in the session.
    pub fn is_enabled(&self) -> bool {
        // SAFETY: as in `enable`.
        unsafe { ffi::abl_link_is_enabled(self.raw) }
    }

    /// Share start and stop with the other peers that do.
    pub fn enable_start_stop_sync(&self, enable: bool) {
        // SAFETY: as in `enable`.
        unsafe { ffi::abl_link_enable_start_stop_sync(self.raw, enable) }
    }

    /// Whether start and stop are shared.
    pub fn is_start_stop_sync_enabled(&self) -> bool {
        // SAFETY: as in `enable`.
        unsafe { ffi::abl_link_is_start_stop_sync_enabled(self.raw) }
    }

    /// How many other peers are in the session.
    pub fn peers(&self) -> u32 {
        // SAFETY: as in `enable`.
        let n = unsafe { ffi::abl_link_num_peers(self.raw) };
        u32::try_from(n).unwrap_or(u32::MAX)
    }

    /// The Link clock, µs: the clock every time given to or read from the library is on.
    pub fn clock_us(&self) -> i64 {
        // SAFETY: as in `enable`.
        unsafe { ffi::abl_link_clock_micros(self.raw) }
    }

    /// A snapshot of the session state, to read or change and [`Link::commit`].
    pub fn capture(&self) -> Session {
        // SAFETY: abl_link_create_session_state allocates a state that `Session`'s `Drop` destroys.
        let raw = unsafe { ffi::abl_link_create_session_state() };
        assert!(!raw.impl_.is_null(), "abl_link_create_session_state failed");
        // SAFETY: both are live.
        unsafe { ffi::abl_link_capture_app_session_state(self.raw, raw) };
        Session { raw }
    }

    /// Make `state` the session state; the library tells the other peers what changed.
    pub fn commit(&self, state: &Session) {
        // SAFETY: both are live.
        unsafe { ffi::abl_link_commit_app_session_state(self.raw, state.raw) }
    }
}

impl Drop for Link {
    fn drop(&mut self) {
        // SAFETY: `raw` came from abl_link_create and is destroyed once. The library says goodbye to the session.
        unsafe { ffi::abl_link_destroy(self.raw) }
    }
}

/// A captured session state (a timeline and a start/stop state).
pub struct Session {
    raw: ffi::AblSessionState,
}

impl Session {
    /// The beat at `time_us` at `quantum`. Its magnitude is this instance's own; only its phase is shared.
    pub fn beat_at_time(&self, time_us: i64, quantum: f64) -> f64 {
        // SAFETY: `raw` is a live state for as long as `self`.
        unsafe { ffi::abl_link_beat_at_time(self.raw, time_us, quantum) }
    }
}

impl SessionState for Session {
    fn tempo(&self) -> f64 {
        // SAFETY: as in `beat_at_time`.
        unsafe { ffi::abl_link_tempo(self.raw) }
    }

    fn set_tempo(&mut self, bpm: f64, at_us: i64) {
        // SAFETY: as in `beat_at_time`.
        unsafe { ffi::abl_link_set_tempo(self.raw, bpm, at_us) }
    }

    fn phase_at_time(&self, at_us: i64, quantum: f64) -> f64 {
        // SAFETY: as in `beat_at_time`.
        unsafe { ffi::abl_link_phase_at_time(self.raw, at_us, quantum) }
    }

    fn force_beat_at_time(&mut self, beat: f64, at_us: i64, quantum: f64) {
        // SAFETY: as in `beat_at_time`.
        unsafe { ffi::abl_link_force_beat_at_time(self.raw, beat, at_us, quantum) }
    }

    fn is_playing(&self) -> bool {
        // SAFETY: as in `beat_at_time`.
        unsafe { ffi::abl_link_is_playing(self.raw) }
    }

    fn set_is_playing(&mut self, playing: bool, at_us: i64) {
        // SAFETY: as in `beat_at_time`.
        unsafe { ffi::abl_link_set_is_playing(self.raw, playing, at_us) }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // SAFETY: `raw` came from abl_link_create_session_state and is destroyed once.
        unsafe { ffi::abl_link_destroy_session_state(self.raw) }
    }
}
