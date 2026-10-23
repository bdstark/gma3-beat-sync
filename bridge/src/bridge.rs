// SPDX-License-Identifier: GPL-2.0-or-later

//! The bridge's side of LB1, sans-IO: what to answer and which timeline to publish, for a datagram that arrived at a
//! given time on the Link clock. Rules 1, 2, 6 and 7 of "What the bridge does" in gma3-phrase-sync's
//! `docs/link-bridge.md`; [`crate::publish`] has the rest.

use link_bridge_protocol::{DecodeError, Message, PROTOCOL, State, Timeline};

/// A run lets go after this long without a timeline, µs.
pub const SILENCE_US: i64 = 3_000_000;
/// `VERSION` answers go at most this often, µs.
pub const VERSION_EVERY_US: i64 = 1_000_000;

/// The service run the bridge follows.
#[derive(Debug, Clone, Copy)]
struct Run {
    nonce: u64,
    /// The last timeline applied.
    seq: u32,
    /// When it arrived, on the Link clock.
    last_tl_us: i64,
    /// Whether its timelines are being published.
    publishing: bool,
    /// It said goodbye: nothing more from it is taken.
    ended: bool,
}

/// What a datagram calls for.
#[derive(Debug, Default, PartialEq)]
pub struct Output {
    /// The answer to send back to the sender.
    pub reply: Option<Vec<u8>>,
    /// A timeline to publish.
    pub publish: Option<Timeline>,
    /// What to log.
    pub log: Vec<String>,
}

/// The bridge's protocol state.
#[derive(Debug, Default)]
pub struct Bridge {
    run: Option<Run>,
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

impl Bridge {
    /// A bridge that follows no run yet.
    pub fn new() -> Bridge {
        Bridge::default()
    }

    /// Whether a run's timelines are being published.
    pub fn publishing(&self) -> bool {
        self.run.is_some_and(|r| r.publishing)
    }

    /// A datagram that arrived at `now_us` on the Link clock, with `peers` other peers in the session.
    pub fn receive(&mut self, data: &[u8], now_us: i64, peers: u32) -> Output {
        let mut out = Output::default();
        match Message::decode(data) {
            Ok(Message::Ping { nonce, seq, sender_us }) => {
                out.reply = Some(Message::Pong { nonce, seq, sender_us, bridge_us: now_us, peers }.encode());
            }
            Ok(Message::Timeline(t)) => {
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
                        Run { nonce: t.nonce, seq: 0, last_tl_us: now_us, publishing: false, ended: false }
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
                self.run = Some(Run { seq: t.seq, last_tl_us: now_us, publishing: true, ..run });
                out.publish = Some(t);
            }
            Ok(Message::Bye { nonce }) => {
                if let Some(r) = self.run.as_mut().filter(|r| r.nonce == nonce && !r.ended) {
                    r.ended = true;
                    if r.publishing {
                        r.publishing = false;
                        out.log.push(format!("run {nonce:016x}: said goodbye; letting go of the session"));
                    }
                }
            }
            Err(DecodeError::OtherProtocol(p)) => {
                // Say which protocol this side speaks, at most once a second, and never in answer to a VERSION, so
                // two sides on different protocols can't answer each other forever.
                let is_version = data.split(|b| *b == b'\t').nth(1) == Some(&b"VERSION"[..]);
                if !is_version && self.last_version_us.is_none_or(|v| now_us.saturating_sub(v) >= VERSION_EVERY_US) {
                    self.last_version_us = Some(now_us);
                    out.reply = Some(Message::Version.encode());
                }
                if self.other_protocol.as_deref() != Some(&p) {
                    out.log.push(format!("a sender speaks {p}, this bridge {PROTOCOL}"));
                    self.other_protocol = Some(p);
                }
            }
            // A pong or VERSION (the bridge sends those, never asks for them), or a malformed datagram.
            _ => {}
        }
        out
    }

    /// Time passing, at `now_us` on the Link clock. Returns log lines.
    pub fn poll(&mut self, now_us: i64) -> Vec<String> {
        match self.run.as_mut() {
            Some(r) if r.publishing && now_us.saturating_sub(r.last_tl_us) >= SILENCE_US => {
                r.publishing = false;
                vec![format!("run {:016x}: no timeline for 3 s; letting go of the session", r.nonce)]
            }
            _ => vec![],
        }
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
        let lb2 = b"LB2\tTL\tanything";
        let out = b.receive(lb2, 0, 0);
        assert_eq!(out.reply.as_deref(), Some(&b"LB1\tVERSION"[..]));
        assert_eq!(out.log, ["a sender speaks LB2, this bridge LB1"]);
        let again = b.receive(lb2, VERSION_EVERY_US - 1, 0);
        assert_eq!((again.reply, again.log.len()), (None, 0));
        assert!(b.receive(lb2, VERSION_EVERY_US, 0).reply.is_some());
        // Never in answer to a VERSION, whatever its protocol.
        assert_eq!(b.receive(b"LB2\tVERSION", 10 * VERSION_EVERY_US, 0).reply, None);
        assert_eq!(b.receive(b"LB1\tVERSION", 20 * VERSION_EVERY_US, 0).reply, None);
        // A third protocol is logged too.
        assert_eq!(b.receive(b"LB3", 30 * VERSION_EVERY_US, 0).log, ["a sender speaks LB3, this bridge LB1"]);
    }

    #[test]
    fn malformed_and_unexpected_datagrams_are_ignored() {
        let mut b = Bridge::new();
        let pong = Message::Pong { nonce: NONCE, seq: 1, sender_us: 0, bridge_us: 0, peers: 0 }.encode();
        for d in [&b""[..], b"\xff\xfe", b"hello", b"LB1\tPING\t1\t2\t3", b"LB1\tTL\tnonsense", &pong] {
            assert_eq!(b.receive(d, 0, 0), Output::default(), "{}", String::from_utf8_lossy(d));
        }
        assert!(!b.publishing());
    }
}
