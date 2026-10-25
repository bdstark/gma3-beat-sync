// SPDX-License-Identifier: GPL-2.0-or-later

//! The bridge's side of LB1 and LB2, sans-IO: what to answer, which timeline to publish and when to report the
//! session, for a datagram that arrived (or a session read) at a given time on the Link clock. Rules 1, 2 and 6 to 8
//! of "What the bridge does" and the session report of the protocol's specification (`docs/link-bridge.md` in the
//! link-bridge-protocol repository); [`crate::publish`] has the rest.

use link_bridge_protocol::{DecodeError, Message, Protocol, Session, State, Timeline};

/// A run lets go after this long without a timeline, µs; a session subscriber lapses after this long without an LB2
/// ping; a timeline counts as `publishing` in session reports for this long.
pub const SILENCE_US: i64 = 3_000_000;
/// `VERSION` answers go at most this often, µs.
pub const VERSION_EVERY_US: i64 = 1_000_000;
/// Session reports go at most this often (20 a second), µs.
pub const SESSION_EVERY_US: i64 = 50_000;
/// A session tempo that moved by more than this (BPM) since the last report is reported.
pub const SESSION_TEMPO_STEP: f64 = 0.001;
/// A session phase that moved by more than this (µs at the tempo) from where the last report puts it is reported.
pub const SESSION_PHASE_STEP_US: f64 = 1000.0;

/// The service run the bridge follows.
#[derive(Debug, Clone, Copy)]
struct Run {
    nonce: u64,
    /// The last timeline applied.
    seq: u32,
    /// When it arrived, on the Link clock.
    last_tl_us: i64,
    /// When the last timeline that sets the tempo or the phase arrived.
    held_us: Option<i64>,
    /// Whether its timelines are being published.
    publishing: bool,
    /// It said goodbye: nothing more from it is taken.
    ended: bool,
}

/// The LB2 service run the session is reported to.
#[derive(Debug, Clone, Copy)]
struct Subscriber {
    nonce: u64,
    /// When its last LB2 ping arrived.
    last_ping_us: i64,
    /// The last report sent, and when.
    last: Option<(Session, i64)>,
    /// A report is due (after a pong), whether or not the session changed.
    due: bool,
}

/// The session as the bridge's Link instance has it, read by the caller.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Snapshot {
    /// When it was read, on the Link clock, µs.
    pub at_us: i64,
    /// The beat at `at_us` at `quantum`.
    pub beat: f64,
    /// The tempo, BPM.
    pub bpm: f64,
    /// The bar `beat` is counted in.
    pub quantum: u8,
    /// Whether the session plays, if start and stop are shared.
    pub playing: Option<bool>,
    /// How many other peers are in the session.
    pub peers: u32,
}

/// What a datagram calls for.
#[derive(Debug, Default, PartialEq)]
pub struct Output {
    /// The answer to send back to the sender.
    pub reply: Option<Vec<u8>>,
    /// A timeline to publish.
    pub publish: Option<Timeline>,
    /// The sender is the session's subscriber now: reports go to its address.
    pub subscribe: bool,
    /// What to log.
    pub log: Vec<String>,
}

/// The bridge's protocol state.
#[derive(Debug, Default)]
pub struct Bridge {
    run: Option<Run>,
    subscriber: Option<Subscriber>,
    last_version_us: Option<i64>,
    /// The other protocol a sender last spoke, so it is logged once.
    other_protocol: Option<String>,
}

fn state_name(s: State) -> &'static str {
    match s {
        State::Play => "play",
        State::Stop => "stop",
    }
}

/// Whether a timeline sets anything in the session: the tempo, or the phase.
fn holds(t: &Timeline) -> bool {
    t.bpm > 0.0 || (t.state == State::Play && t.quantum > 0)
}

/// Whether `now` is worth reporting after `last`: anything but the beat and the time changed, the tempo moved by
/// more than [`SESSION_TEMPO_STEP`], or the phase by more than [`SESSION_PHASE_STEP_US`] from where `last` puts it.
fn changed(last: &Session, now: &Session) -> bool {
    if (last.quantum, last.playing, last.peers, last.publishing)
        != (now.quantum, now.playing, now.peers, now.publishing)
    {
        return true;
    }
    if (now.bpm - last.bpm).abs() > SESSION_TEMPO_STEP {
        return true;
    }
    let q = f64::from(now.quantum);
    let predicted = last.beat + (now.at_us - last.at_us) as f64 * last.bpm / 60e6;
    // The shorter way round the bar: a jump by whole bars is no change.
    let off = (now.beat - predicted + q / 2.0).rem_euclid(q) - q / 2.0;
    now.bpm > 0.0 && (off * 60e6 / now.bpm).abs() > SESSION_PHASE_STEP_US
}

impl Bridge {
    /// A bridge that follows no run yet.
    pub fn new() -> Bridge {
        Bridge::default()
    }

    /// Whether a run's timelines are being published.
    pub fn publishing(&self) -> bool {
        self.run.is_some_and(|r| r.publishing)
    }

    /// Whether an LB2 service is subscribed to session reports.
    pub fn subscribed(&self) -> bool {
        self.subscriber.is_some()
    }

    /// A datagram that arrived at `now_us` on the Link clock, with `peers` other peers in the session.
    pub fn receive(&mut self, data: &[u8], now_us: i64, peers: u32) -> Output {
        let mut out = Output::default();
        match Message::decode_versioned(data) {
            Ok((protocol, Message::Ping { nonce, seq, sender_us })) => {
                out.reply = Some(Message::Pong { nonce, seq, sender_us, bridge_us: now_us, peers }.encode_in(protocol));
                if protocol >= Protocol::Lb2 {
                    match self.subscriber.as_mut() {
                        Some(s) if s.nonce == nonce => {
                            s.last_ping_us = now_us;
                            s.due = true;
                        }
                        _ => {
                            out.log.push(format!("run {nonce:016x}: reporting the session ({protocol})"));
                            self.subscriber = Some(Subscriber { nonce, last_ping_us: now_us, last: None, due: true });
                        }
                    }
                    out.subscribe = true;
                }
            }
            Ok((_, Message::Timeline(t))) => {
                let run = match self.run {
                    Some(r) if r.nonce == t.nonce => {
                        if r.ended || t.seq <= r.seq {
                            return out; // late, or after the run's goodbye
                        }
                        r
                    }
                    old => {
                        out.log.push(match old {
                            Some(_) => format!("run {:016x}: replaces the previous run", t.nonce),
                            None => format!("run {:016x}: first timeline", t.nonce),
                        });
                        Run {
                            nonce: t.nonce,
                            seq: 0,
                            last_tl_us: now_us,
                            held_us: None,
                            publishing: false,
                            ended: false,
                        }
                    }
                };
                if !run.publishing {
                    out.log.push(format!(
                        "run {:016x}: publishing ({}, {} BPM, quantum {})",
                        t.nonce,
                        state_name(t.state),
                        t.bpm,
                        t.quantum
                    ));
                }
                let held_us = if holds(&t) { Some(now_us) } else { run.held_us };
                self.run = Some(Run { seq: t.seq, last_tl_us: now_us, held_us, publishing: true, ..run });
                out.publish = Some(t);
            }
            Ok((_, Message::Bye { nonce })) => {
                if let Some(r) = self.run.as_mut().filter(|r| r.nonce == nonce && !r.ended) {
                    r.ended = true;
                    if r.publishing {
                        r.publishing = false;
                        out.log.push(format!("run {nonce:016x}: said goodbye; letting go of the session"));
                    }
                }
                if self.subscriber.is_some_and(|s| s.nonce == nonce) {
                    self.subscriber = None;
                    out.log.push(format!("run {nonce:016x}: said goodbye; no more session reports"));
                }
            }
            Err(DecodeError::OtherProtocol(p)) => {
                // Say which protocol this side speaks (the newest), at most once a second, and never in answer to a
                // VERSION, so two sides on different protocols can't answer each other forever.
                let is_version = data.split(|b| *b == b'\t').nth(1) == Some(&b"VERSION"[..]);
                if !is_version && self.last_version_us.is_none_or(|v| now_us.saturating_sub(v) >= VERSION_EVERY_US) {
                    self.last_version_us = Some(now_us);
                    out.reply = Some(Message::Version.encode_in(Protocol::LATEST));
                }
                if self.other_protocol.as_deref() != Some(&p) {
                    out.log.push(format!("a sender speaks {p}, this bridge LB1 and LB2"));
                    self.other_protocol = Some(p);
                }
            }
            // A pong, session or VERSION (the bridge sends those, never asks for them), or a malformed datagram.
            _ => {}
        }
        out
    }

    /// Time passing, at `now_us` on the Link clock. Returns log lines.
    pub fn poll(&mut self, now_us: i64) -> Vec<String> {
        let mut log = vec![];
        if let Some(r) = self.run.as_mut()
            && r.publishing
            && now_us.saturating_sub(r.last_tl_us) >= SILENCE_US
        {
            r.publishing = false;
            log.push(format!("run {:016x}: no timeline for 3 s; letting go of the session", r.nonce));
        }
        if let Some(s) = self.subscriber
            && now_us.saturating_sub(s.last_ping_us) >= SILENCE_US
        {
            self.subscriber = None;
            log.push(format!("run {:016x}: no LB2 ping for 3 s; no more session reports", s.nonce));
        }
        log
    }

    /// Whether a session report may go at `now_us`: there is a subscriber and the last report is at least
    /// [`SESSION_EVERY_US`] old. Only then is the session worth reading for [`Bridge::session`].
    pub fn wants_session(&self, now_us: i64) -> bool {
        self.subscriber.is_some_and(|s| s.last.is_none_or(|(_, at)| now_us.saturating_sub(at) >= SESSION_EVERY_US))
    }

    /// The session as read at `snap.at_us`: the report to send the subscriber, if one is due (after a pong) or the
    /// session changed, and the last one is old enough.
    pub fn session(&mut self, snap: &Snapshot) -> Option<Vec<u8>> {
        if !self.wants_session(snap.at_us) {
            return None;
        }
        let sub = self.subscriber?;
        let publishing = self.run.is_some_and(|r| {
            r.nonce == sub.nonce && !r.ended && r.held_us.is_some_and(|h| snap.at_us.saturating_sub(h) < SILENCE_US)
        });
        let seq = sub.last.map_or(1, |(l, _)| l.seq.wrapping_add(1));
        let report = Session {
            nonce: sub.nonce,
            seq,
            at_us: snap.at_us,
            beat: snap.beat,
            bpm: snap.bpm,
            quantum: snap.quantum,
            playing: snap.playing,
            peers: snap.peers,
            publishing,
        };
        if !sub.due && sub.last.is_some_and(|(l, _)| !changed(&l, &report)) {
            return None;
        }
        self.subscriber = Some(Subscriber { last: Some((report, snap.at_us)), due: false, ..sub });
        Some(Message::Session(report).encode_in(Protocol::Lb2))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONCE: u64 = 0x0000_01a2_b3c4_d5e6;

    fn tl(nonce: u64, seq: u32) -> Vec<u8> {
        Message::Timeline(Timeline {
            nonce,
            seq,
            state: State::Play,
            at_us: 90_002_000,
            beat: 31.5,
            bpm: 126.0,
            quantum: 4,
        })
        .encode()
    }

    fn published(out: &Output) -> Option<u32> {
        out.publish.map(|t| t.seq)
    }

    #[test]
    fn a_ping_is_answered_with_the_receipt_time_and_peers() {
        let mut b = Bridge::new();
        let ping = Message::Ping { nonce: NONCE, seq: 1, sender_us: 1500 }.encode();
        let out = b.receive(&ping, 90_001_520, 2);
        assert_eq!(out.reply.unwrap(), b"LB1\tPONG\t000001a2b3c4d5e6\t1\t1500\t90001520\t2");
        assert_eq!((out.publish, out.log.len()), (None, 0));
        // Any run's pings are answered, whichever run is being followed.
        b.receive(&tl(NONCE, 1), 0, 0);
        let other = Message::Ping { nonce: 7, seq: 9, sender_us: -3 }.encode();
        let pong = Message::decode(&b.receive(&other, 5, 0).reply.unwrap()).unwrap();
        assert_eq!(pong, Message::Pong { nonce: 7, seq: 9, sender_us: -3, bridge_us: 5, peers: 0 });
    }

    #[test]
    fn timelines_are_taken_in_order() {
        let mut b = Bridge::new();
        let first = b.receive(&tl(NONCE, 5), 0, 0);
        assert_eq!(published(&first), Some(5));
        assert!(first.log[0].contains("first timeline"), "{:?}", first.log);
        assert!(first.log[1].contains("publishing (play, 126 BPM, quantum 4)"), "{:?}", first.log);
        assert_eq!(published(&b.receive(&tl(NONCE, 5), 1, 0)), None); // a duplicate
        assert_eq!(published(&b.receive(&tl(NONCE, 4), 2, 0)), None); // late
        let next = b.receive(&tl(NONCE, 7), 3, 0); // one lost on the way
        assert_eq!((published(&next), next.log.len()), (Some(7), 0));
        assert_eq!(published(&b.receive(&tl(NONCE, 6), 4, 0)), None);
    }

    #[test]
    fn a_new_nonce_replaces_the_run() {
        let mut b = Bridge::new();
        b.receive(&tl(NONCE, 100), 0, 0);
        let out = b.receive(&tl(NONCE + 1, 1), 1, 0);
        assert_eq!(published(&out), Some(1));
        assert!(out.log[0].contains("replaces the previous run"), "{:?}", out.log);
        // The old run is now another run: its timelines replace the new one in turn (the latest run wins).
        assert_eq!(published(&b.receive(&tl(NONCE + 1, 2), 2, 0)), Some(2));
        assert_eq!(published(&b.receive(&tl(NONCE, 101), 3, 0)), Some(101));
    }

    #[test]
    fn bye_lets_go_and_nothing_more_from_that_run_is_taken() {
        let mut b = Bridge::new();
        b.receive(&tl(NONCE, 1), 0, 0);
        assert!(b.receive(&Message::Bye { nonce: NONCE + 1 }.encode(), 1, 0).log.is_empty()); // another run's
        assert!(b.publishing());
        let out = b.receive(&Message::Bye { nonce: NONCE }.encode(), 2, 0);
        assert!(out.log[0].contains("said goodbye"), "{:?}", out.log);
        assert!(!b.publishing());
        assert!(b.receive(&Message::Bye { nonce: NONCE }.encode(), 3, 0).log.is_empty()); // said once
        assert_eq!(published(&b.receive(&tl(NONCE, 2), 4, 0)), None); // reordered after the goodbye
        assert_eq!(published(&b.receive(&tl(NONCE + 1, 1), 5, 0)), Some(1)); // a restarted service
    }

    #[test]
    fn three_seconds_without_a_timeline_lets_go_until_the_next() {
        let mut b = Bridge::new();
        assert!(b.poll(10 * SILENCE_US).is_empty());
        b.receive(&tl(NONCE, 1), 1_000_000, 0);
        assert!(b.poll(1_000_000 + SILENCE_US - 1).is_empty());
        assert!(b.publishing());
        let log = b.poll(1_000_000 + SILENCE_US);
        assert!(log[0].contains("no timeline for 3 s"), "{log:?}");
        assert!(!b.publishing());
        assert!(b.poll(1_000_000 + 2 * SILENCE_US).is_empty()); // said once
        let back = b.receive(&tl(NONCE, 2), 9_000_000, 0);
        assert_eq!(published(&back), Some(2));
        assert!(back.log[0].contains("publishing"), "{:?}", back.log);
        // Each timeline restarts the wait.
        b.receive(&tl(NONCE, 3), 11_000_000, 0);
        assert!(b.poll(9_000_000 + SILENCE_US).is_empty());
    }

    #[test]
    fn another_protocol_is_answered_with_version_at_most_once_a_second() {
        let mut b = Bridge::new();
        let lb3 = b"LB3\tTL\tanything";
        let out = b.receive(lb3, 0, 0);
        // In the newest protocol the bridge speaks, so the sender can fall back to it.
        assert_eq!(out.reply.as_deref(), Some(&b"LB2\tVERSION"[..]));
        assert_eq!(out.log, ["a sender speaks LB3, this bridge LB1 and LB2"]);
        let again = b.receive(lb3, VERSION_EVERY_US - 1, 0);
        assert_eq!((again.reply, again.log.len()), (None, 0));
        assert!(b.receive(lb3, VERSION_EVERY_US, 0).reply.is_some());
        // Never in answer to a VERSION, whatever its protocol.
        assert_eq!(b.receive(b"LB3\tVERSION", 10 * VERSION_EVERY_US, 0).reply, None);
        assert_eq!(b.receive(b"LB2\tVERSION", 20 * VERSION_EVERY_US, 0).reply, None);
        assert_eq!(b.receive(b"LB1\tVERSION", 30 * VERSION_EVERY_US, 0).reply, None);
        // A fourth protocol is logged too.
        assert_eq!(b.receive(b"LB4", 40 * VERSION_EVERY_US, 0).log, ["a sender speaks LB4, this bridge LB1 and LB2"]);
    }

    #[test]
    fn malformed_and_unexpected_datagrams_are_ignored() {
        let mut b = Bridge::new();
        let pong = Message::Pong { nonce: NONCE, seq: 1, sender_us: 0, bridge_us: 0, peers: 0 }.encode();
        let session = Message::Session(Session {
            nonce: NONCE,
            seq: 1,
            at_us: 0,
            beat: 0.0,
            bpm: 120.0,
            quantum: 4,
            playing: None,
            peers: 0,
            publishing: false,
        })
        .encode();
        for d in [&b""[..], b"\xff\xfe", b"hello", b"LB1\tPING\t1\t2\t3", b"LB1\tTL\tnonsense", &pong, &session] {
            assert_eq!(b.receive(d, 0, 0), Output::default(), "{}", String::from_utf8_lossy(d));
        }
        assert!(!b.publishing() && !b.subscribed());
    }

    // The session report (LB2).

    fn lb2_ping(nonce: u64, seq: u32) -> Vec<u8> {
        Message::Ping { nonce, seq, sender_us: 1500 }.encode_in(Protocol::Lb2)
    }

    fn lb2_tl(nonce: u64, seq: u32, state: State, bpm: f64, quantum: u8) -> Vec<u8> {
        Message::Timeline(Timeline { nonce, seq, state, at_us: 0, beat: 0.0, bpm, quantum }).encode_in(Protocol::Lb2)
    }

    /// A session at 124 BPM, 4 beats to the bar, two other peers: beat 1031.5 at 90 001 530 µs.
    fn snap(at_us: i64) -> Snapshot {
        Snapshot {
            at_us,
            beat: 1031.5 + (at_us - 90_001_530) as f64 * 124.0 / 60e6,
            bpm: 124.0,
            quantum: 4,
            playing: None,
            peers: 2,
        }
    }

    fn report(b: &mut Bridge, snap: &Snapshot) -> Option<Session> {
        b.session(snap).map(|d| match Message::decode_versioned(&d) {
            Ok((Protocol::Lb2, Message::Session(s))) => s,
            other => panic!("{other:?}"),
        })
    }

    #[test]
    fn an_lb2_ping_gets_an_lb2_pong_and_then_the_session() {
        let mut b = Bridge::new();
        let out = b.receive(&lb2_ping(NONCE, 1), 90_001_520, 2);
        assert_eq!(out.reply.unwrap(), b"LB2\tPONG\t000001a2b3c4d5e6\t1\t1500\t90001520\t2");
        assert!(out.subscribe && b.subscribed());
        assert_eq!(out.log, ["run 000001a2b3c4d5e6: reporting the session (LB2)"]);
        assert!(b.wants_session(90_001_530));
        let d = b.session(&snap(90_001_530)).unwrap();
        assert_eq!(d, b"LB2\tSESSION\t000001a2b3c4d5e6\t1\t90001530\t1031.5\t124\t4\tunknown\t2\t0");
        // Nothing changed: nothing more until the next pong, which is followed by a report again.
        assert!(report(&mut b, &snap(90_001_530 + SESSION_EVERY_US)).is_none());
        assert!(report(&mut b, &snap(90_001_530 + 10 * SESSION_EVERY_US)).is_none());
        let again = b.receive(&lb2_ping(NONCE, 2), 91_000_000, 2);
        assert!(again.log.is_empty() && again.subscribe);
        assert_eq!(report(&mut b, &snap(91_000_010)).map(|s| (s.seq, s.at_us)), Some((2, 91_000_010)));
    }

    #[test]
    fn an_lb1_service_is_answered_in_lb1_and_gets_no_session() {
        let mut b = Bridge::new();
        let out = b.receive(&Message::Ping { nonce: NONCE, seq: 1, sender_us: 1500 }.encode(), 5, 0);
        assert!(out.reply.unwrap().starts_with(b"LB1\tPONG\t"));
        assert!(!out.subscribe && !b.subscribed() && !b.wants_session(5));
        assert!(b.session(&snap(5)).is_none());
        // Timelines in either protocol are taken alike.
        assert_eq!(published(&b.receive(&tl(NONCE, 1), 6, 0)), Some(1));
        assert_eq!(published(&b.receive(&lb2_tl(NONCE, 2, State::Play, 120.0, 4), 7, 0)), Some(2));
    }

    #[test]
    fn a_session_change_is_reported_at_most_20_times_a_second() {
        let mut b = Bridge::new();
        let t0 = 90_001_530;
        b.receive(&lb2_ping(NONCE, 1), t0, 2);
        assert_eq!(report(&mut b, &snap(t0)).map(|s| s.seq), Some(1));
        // Within the steps: not reported.
        let t = t0 + SESSION_EVERY_US;
        assert!(report(&mut b, &Snapshot { bpm: 124.0009, ..snap(t) }).is_none());
        let early = 0.9 * SESSION_PHASE_STEP_US * 124.0 / 60e6; // 0.9 ms of beats
        assert!(report(&mut b, &Snapshot { beat: snap(t).beat - early, ..snap(t) }).is_none());
        // A jump by whole bars is no change either.
        assert!(report(&mut b, &Snapshot { beat: snap(t).beat + 64.0, ..snap(t) }).is_none());
        // Another peer moved the tempo: reported.
        let faster = Snapshot { bpm: 124.0011, ..snap(t) };
        assert_eq!(report(&mut b, &faster).map(|s| (s.seq, s.bpm)), Some((2, 124.0011)));
        // The phase moved by 1.1 ms (from where the last report puts it, at its tempo), but only 10 ms later: held
        // back by the limit, then reported with the session as it is then.
        let late = |at: i64| Snapshot {
            at_us: at,
            beat: faster.beat + (at - t) as f64 * faster.bpm / 60e6 - 0.0023,
            ..faster
        };
        assert!(!b.wants_session(t + 10_000));
        assert!(report(&mut b, &late(t + 10_000)).is_none());
        assert_eq!(
            report(&mut b, &late(t + SESSION_EVERY_US)).map(|s| (s.seq, s.at_us)),
            Some((3, t + SESSION_EVERY_US))
        );
        // Peers, quantum and start/stop are reported at once (at the limit).
        let t = t + 2 * SESSION_EVERY_US;
        let base = late(t);
        assert!(report(&mut b, &base).is_none());
        let t = t + SESSION_EVERY_US;
        for (i, s) in [
            Snapshot { peers: 3, ..late(t) },
            Snapshot { peers: 3, quantum: 8, beat: base.beat, ..late(t + SESSION_EVERY_US) },
            Snapshot { peers: 3, quantum: 8, playing: Some(true), beat: base.beat, ..late(t + 2 * SESSION_EVERY_US) },
        ]
        .iter()
        .enumerate()
        {
            assert_eq!(report(&mut b, s).map(|r| r.seq), Some(4 + i as u32), "{s:?}");
        }
    }

    #[test]
    fn publishing_is_this_runs_timelines_that_set_the_session_in_the_last_3_s() {
        let mut b = Bridge::new();
        b.receive(&lb2_ping(NONCE, 1), 0, 2);
        assert!(!report(&mut b, &snap(0)).unwrap().publishing);
        // A stopped timeline with no tempo sets nothing.
        b.receive(&lb2_tl(NONCE, 1, State::Stop, 0.0, 4), 10_000, 2);
        assert!(report(&mut b, &snap(SESSION_EVERY_US)).is_none());
        // A playing one does: reported at once (at the limit).
        b.receive(&lb2_tl(NONCE, 2, State::Play, 124.0, 4), 100_000, 2);
        assert!(report(&mut b, &snap(100_000)).unwrap().publishing);
        // So does a stopped one with a tempo; the 3 s count from the last that set something.
        b.receive(&lb2_tl(NONCE, 3, State::Stop, 124.0, 0), 1_000_000, 2);
        b.receive(&lb2_tl(NONCE, 4, State::Stop, 0.0, 0), 2_000_000, 2);
        b.receive(&lb2_ping(NONCE, 2), 2_500_000, 2);
        assert!(report(&mut b, &snap(2_500_000)).unwrap().publishing);
        b.receive(&lb2_ping(NONCE, 3), 3_900_000, 2);
        assert!(report(&mut b, &snap(3_900_000)).unwrap().publishing);
        assert!(!report(&mut b, &snap(4_000_000)).unwrap().publishing);
        // Another run's timelines are not this run's.
        b.receive(&lb2_tl(NONCE + 1, 1, State::Play, 124.0, 4), 4_100_000, 2);
        b.receive(&lb2_ping(NONCE, 4), 4_200_000, 2);
        assert!(!report(&mut b, &snap(4_200_000)).unwrap().publishing);
    }

    #[test]
    fn the_subscription_ends_with_bye_or_3_s_without_an_lb2_ping() {
        let mut b = Bridge::new();
        b.receive(&lb2_ping(NONCE, 1), 0, 0);
        b.receive(&lb2_tl(NONCE, 1, State::Play, 124.0, 4), 0, 0);
        report(&mut b, &snap(0)).unwrap();
        let bye = b.receive(&Message::Bye { nonce: NONCE }.encode_in(Protocol::Lb2), 1, 0);
        assert!(bye.log.iter().any(|l| l.contains("no more session reports")), "{:?}", bye.log);
        assert!(!b.subscribed() && b.session(&snap(SESSION_EVERY_US)).is_none());

        // LB1 pings keep nothing alive.
        b.receive(&lb2_ping(NONCE + 1, 1), 10_000_000, 0);
        assert_eq!(report(&mut b, &snap(10_000_000)).map(|s| s.seq), Some(1));
        b.receive(&Message::Ping { nonce: NONCE + 1, seq: 2, sender_us: 0 }.encode(), 12_000_000, 0);
        assert!(b.poll(10_000_000 + SILENCE_US - 1).is_empty());
        let log = b.poll(10_000_000 + SILENCE_US);
        assert_eq!(log, ["run 000001a2b3c4d5e7: no LB2 ping for 3 s; no more session reports"]);
        assert!(!b.subscribed());
        // Subscribing again counts from 1 again.
        b.receive(&lb2_ping(NONCE + 1, 3), 20_000_000, 0);
        assert_eq!(report(&mut b, &snap(20_000_000)).map(|s| s.seq), Some(1));
    }

    #[test]
    fn another_runs_lb2_ping_takes_the_subscription_over() {
        let mut b = Bridge::new();
        b.receive(&lb2_ping(NONCE, 1), 0, 0);
        report(&mut b, &snap(0)).unwrap();
        b.receive(&lb2_ping(NONCE, 2), 1_000_000, 0);
        assert_eq!(report(&mut b, &snap(1_000_000)).map(|s| s.seq), Some(2));
        let out = b.receive(&lb2_ping(NONCE + 1, 1), 1_500_000, 0);
        assert!(out.subscribe && out.log[0].contains("000001a2b3c4d5e7: reporting the session"), "{:?}", out.log);
        assert_eq!(report(&mut b, &snap(1_500_000)).map(|s| (s.nonce, s.seq)), Some((NONCE + 1, 1)));
        // The old run's goodbye doesn't end the new one's subscription.
        b.receive(&Message::Bye { nonce: NONCE }.encode_in(Protocol::Lb2), 1_600_000, 0);
        assert!(b.subscribed());
    }
}
