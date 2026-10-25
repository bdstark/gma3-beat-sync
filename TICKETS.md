# Tickets

## Background

These tickets come from a field test of [gma3-mcp](https://github.com/bdstark/gma3-mcp) on 2026-10-15. An
operator asked an agent to switch lighting patterns after every fourth beat, with four measures between switches,
synchronised to a Link session.

grandMA3 2.5 cannot follow Link. The bundled manual does not mention it; speed masters follow tap, learn, a fader or
the sound input. So the agent wrote an external Python helper:
- it joined the session with the `aalink` package (which needs a pip install);
- it sent console commands over OSC: an "on" and an "off" macro, a step macro every 16 beats on the downbeat, and
  `ReSync` of the pattern sequences every bar;
- to make that work, the console's OSC input had to be enabled, allowed to run commands, and bound to loopback.

It was never run against a real session.

A probe the same day showed that the console's Lua can do the network part itself
([docs/probes/console-lua-network-2026-10-15.md](docs/probes/console-lua-network-2026-10-15.md)). A plugin needs no
install, no OSC and no computer, and it works on a hardware console too.

Identifiers are provisional. Each ticket follows the same workflow:
1. probe on a disposable show;
2. write a probe record in `docs/probes/`;
3. implement;
4. add harness and live tests;
5. write the docs, then open a PR.

## Shared acceptance criteria

- Every source file carries `SPDX-License-Identifier: GPL-2.0-or-later`.
- Protocol facts come from the Link source (cite the file) or a packet capture, and are recorded in a probe record.
- Nothing claims Link compatibility until the applicable cases of Link's `TEST-PLAN.md` pass. Use the trademark
  wording in [README.md](README.md#trademarks-and-affiliation): "Link" appears less prominently than the project's
  own name.
- The plugin never stalls the console. Blocking socket calls are bounded to a few milliseconds per frame.
- Failures are reported, never hidden:
  - no session;
  - a lost peer;
  - a speed master or sequence that does not exist;
  - a dropped frame.

## BS-00 — Repository setup (at the start of implementation)

**Request:** Finish the repository for GitHub before the first implementation PR.

- Community files: `CONTRIBUTING.md` (incoming contributions under GPL-2.0-or-later), `CODE_OF_CONDUCT.md`,
  `SECURITY.md` (the plugin opens UDP sockets on the console's network) and `ACCESSIBILITY.md`, modelled on
  gma3-mcp's.
- Issue and PR templates, repository description and topics, and branch protection on `main`.
- CI: Lua syntax check (Lua 5.5, the console's version), the protocol harness, and the test peer build.
- The Link library as a git submodule (`modules/link`, pinned to a release tag), with its license and its
  dependencies' licenses noted in the README.

## BS-01 — Probe: following a Link session from the console

**Request:** Establish that a grandMA3 Lua plugin can follow a Link session accurately enough.

**Depends on:** BS-04's test peer (or Ableton Live on the network).

Questions:
- **Discovery.** Does the plugin receive the session's multicast announcements, parse them, and know when peers
  leave? Record the message format, the header and the entries (session, timeline, start/stop, measurement
  endpoint) with citations to the Link source.
- **Measurement.** Does a peer's measurement endpoint answer pings from a follower that never announced itself?
  How accurate is a measurement made with a bounded blocking receive inside one frame? Compare it against the test
  peer's own beat time.
- **Two plugins.** Can this plugin's frame loop run alongside another plugin's loop, such as gma3-mcp's bridge?
  If not, can it use the console's `Timer()`?
- **Shared state.** Where can the plugin publish its status and read its configuration so another plugin or the
  command line can see it? Console global variables, a shared Lua global, or show objects.
- **Console actions.**
  - What does `ReSync` do to running phasers and chases?
  - Does setting a speed master's BPM every bar cause visible jumps?
  - What is the drift between Link beats and a phaser realigned on the bar, over five minutes?

### Acceptance criteria

- A probe record answering each question, with the probe scripts.
- A decision: a follower only, or a full peer (BS-03). Plus where status and configuration live; gma3-mcp builds
  on that interface.

**Status:** probed 2026-10-16:
[docs/probes/bs-01-follow-from-console-2026-10-16.md](docs/probes/bs-01-follow-from-console-2026-10-16.md).
Decision: **a follower only**. A plugin answers pings once per frame (9.3 ms median round trip against 0.3 ms for a
Link peer), which would put about 5 ms of error into every peer measuring through the console. The plugin runs a
frame loop beside other plugins (`Timer()` as the fallback). Configuration and status live in console global
variables `BeatSync.<Key>`, plus a shared Lua table; BS-02 fixes the names. A chase on a rate master drifts about
2.5 ms a minute; a Go per beat holds it. `ReSync` does nothing to chases; phasers could not be observed on this onPC.

## BS-02 — Follower plugin

**Request:** Follow a Link session's tempo, beat, bar and start/stop, and drive the show from it.

**Depends on:** BS-01.

### Acceptance criteria

- The session's tempo reaches a configured speed master. Changes below a threshold are not written every frame.
- Beat and bar position computed per frame, with a configurable quantum (beats per bar).
- Configured actions:
  - every N beats on a phase;
  - on the bar (for example `ReSync` of chosen sequences);
  - on start and on stop;
  - on joining and leaving a session.

  Each runs on the frame nearest its beat.
- Status published where BS-01 decided: running, peers, tempo, beat, phase, the last action, the measured drift and
  the frame jitter.
- Leaving and rejoining a session, and a show load, are reported and recovered.
- Link test plan cases: BEATTIME-1, BEATTIME-2 and STARTSTOPSTATE-1, against the test peer and, once, against
  Ableton Live.

**Status:** implemented in `plugin/gma3_beat_sync.xml` (the plugin, `gma3_beat_sync.lua`; the follower,
`beat_sync_follower.lua`; the protocol, `beat_sync_protocol.lua`), documented in [docs/plugin.md](docs/plugin.md).
Configuration and status are console global variables `BeatSync.<Key>` plus the shared Lua table `BeatSync`.
Live on onPC 2.5.1 against the test peer
([record](docs/probes/bs-02-follower-plugin-2026-10-16.md)): beat actions 23 ms after the beat as observed (about a
frame of console latency; `LeadMs` 17 brings it to 8 ms), no drift over 5 minutes; BEATTIME-1, BEATTIME-2 and
STARTSTOPSTATE-1 pass; leaving, rejoining and the ttl are handled. A show load ends the plugin's loop and the plugin
cannot restart itself; it reports `not running` and is started again by hand. Against Ableton Live (its session
relayed by LinkMaster): BEATTIME-2 and STARTSTOPSTATE-1 pass ([record](docs/probes/bs-02-live-ableton-2026-10-16.md)).
Beat and bar actions follow the beat regardless of start/stop by default (`StartStop` `off`), for beats relayed from a
DJ booth that never send a start.

## BS-03 — Full peer (only if BS-01 shows it is safe)

**Status:** implemented as an opt-in mode (`BeatSync.Mode` `peer`; the follower stays the default), documented in
[docs/plugin.md](docs/plugin.md). The [BS-03 probe](docs/probes/bs-03-full-peer-probe-2026-10-16.md) reversed
BS-01's "follower only": replies stamped for when each ping most likely arrived bring the error of a measuring
peer from 8 ms to about 0.15 ms. Live on onPC 2.5.1 against the test peer
([record](docs/probes/bs-03-peer-live-2026-10-16.md)): TEMPO-1, TEMPO-2, TEMPO-4, TEMPO-5 and STARTSTOPSTATE-2
pass, and `play` and `pause` start and stop the test peer. A peer measuring the console's clock through the plugin
is within 0.06 ms. Rerun on main after review round 1: the same results. TEMPO-3 is covered by TEMPO-2's restart into an existing session, because a show load ends the
plugin's loop. Not run against Ableton Live: its session reaches this computer only through a relay.

**Request:** Appear as a Link peer, send start/stop and propose tempo changes from the console.

**Depends on:** BS-02.

A peer answers other peers' measurement pings. If the plugin answers only once a frame, it adds up to a frame of
error to any peer that measures the session through it. Build this only if BS-01 shows replies can be prompt enough.

### Acceptance criteria

- Announcements, measurement replies and leave messages as the Link source does them.
- Link test plan cases TEMPO-1 to TEMPO-5 and STARTSTOPSTATE-2.
- Tempo changes from the console's speed master reach the session.

## BS-04 — Test peer and protocol harness

**Request:** Test against real Link code without Ableton Live, and test the protocol code without a console.

**Depends on:** BS-00 (the submodule).

### Acceptance criteria

- A small command-line test peer built from the Link submodule (LinkHut or a minimal program). It joins a session,
  sets the tempo, starts and stops, and prints its beat time for comparison.
- A Lua harness (stock Lua 5.5) for the message parser and the timeline arithmetic. It uses packets captured from
  the test peer, stored as fixtures.
- Live tests on onPC: the plugin follows the test peer within a stated tolerance.

**Status:** implemented in tools/test-peer (`gbs-test-peer`, `gbs-capture`, `gbs-vectors`),
`plugin/beat_sync_protocol.lua`, `test/lua/protocol_test.lua` with captured and hand-made fixtures labelled by
Link's own parser, and `test/live/follow_test_peer.mjs`. The live test runs the protocol module inside onPC (the
plugin is BS-02) and follows the test peer within the stated tolerance of 1 ms phase error: 0.022 ms at most in
three scenarios. Record: [docs/probes/bs-04-protocol-and-test-peer-2026-10-15.md](docs/probes/bs-04-protocol-and-test-peer-2026-10-15.md).
BS-02 repeats the live test with the plugin.

## BS-05 — Link bridge for gma3-phrase-sync

**Request:** Publish gma3-phrase-sync's timeline (the selected CDJ's tempo, beat and bar) to a Link session. The
service is MIT-licensed and keeps Link code out (decided 2026-10-23); it sends its timeline over loopback UDP in
protocol LB1 to a separate GPL program built on Ableton's Link library. The bridge lives here because this
repository is already GPL-2.0-or-later and has the library as a submodule. It shares no code with the plugin.

**Depends on:** BS-00 (the submodule); the protocol, LB1: its specification and the MIT crate that encodes it, in
[link-bridge-protocol](https://github.com/bdstark/link-bridge-protocol) (from gma3-phrase-sync PS-11b), pinned at 734d845.

### Acceptance criteria

- A Rust program in `bridge/` that uses the Link library from `modules/link` and the protocol crate for every
  message (no copy of either).
- "What the bridge does", rules 1 to 7 of `docs/link-bridge.md`: listens on loopback only (`127.0.0.1:7822` by
  default); answers each ping at once with the Link clock at its arrival and the number of peers; takes timelines in
  order per run, a new run replacing the old; `play` sets the tempo (unless 0) and aligns the bar's phase at the
  quantum (not the beat count); `stop` sets the tempo only (unless 0); start/stop sharing behind an option, off by
  default; lets go after `BYE` or 3 s without a timeline; answers another protocol with `VERSION`, at most once a
  second and never in answer to a `VERSION`.
- Unit tests of the protocol state and of the publishing, without sockets or Link, on a fake clock and session.
- Tests on loopback with the real library, without joining the network's session: the clock offset the service
  would measure is under 1 ms.
- A test in which a second Link peer sees the tempo and phase arrive.

**Status:** implemented in `bridge/` (`cargo run -p link-bridge -- --listen 127.0.0.1:7822`), described in
[README.md](README.md#the-bridge-for-gma3-phrase-sync-bridge) and [docs/testing.md](docs/testing.md#the-bridge-bridge).
The library is used through Ableton's C wrapper, `abl_link`, built by `bridge/build.rs` with CMake from the
submodule and bound by hand in one module (`bridge/src/link.rs`, the crate's only unsafe code): it is the same
Link-4.1 the test peer uses, it needs no libclang (bindgen) and no second copy of Link (the `rusty_link` crate
bundles its own). Phase is aligned with `forceBeatAtTime`, which Link documents for bridging an external clock into
a session; it moves the session's phase only. A tempo within 0.0005 BPM and a phase within 100 µs of the session's
are left alone, so repeats don't re-time the other peers. On loopback the clock offset is 0-1 µs against a true 0.
Against real Link on macOS (2026-10-23, `tests/link_session.rs`, a second peer in the same process): the bridge
counted the peer in its pongs, the second peer had 126.50008 BPM (Link carries whole microseconds per beat) and the
bar phase within 1 µs about a second after the first timeline, and a jump by whole bars left the phase. Built and
tested on macOS only; CI builds it on Linux and Windows once it can fetch the protocol crate.

## BS-06 — The bridge reports the Link session (LB2)

**Request:** Let gma3-phrase-sync read the Link session through the bridge, so it can use Link's tempo and bar as a
backup when no deck plays and see when Link disagrees with what its audio analysis hears (its AU-5). The service
stays free of Link code: it reads the session in a new protocol revision, LB2.

**Depends on:** BS-05; LB2 in [link-bridge-protocol](https://github.com/bdstark/link-bridge-protocol), pinned at
1ef87da.

### Acceptance criteria

- The bridge speaks LB1 and LB2: each message is answered in its own revision, timelines and goodbyes are taken in
  either, and a service that speaks only LB1 sees exactly LB1.
- `LB2 SESSION` to the latest LB2 pinger (the subscriber): after each pong, and when the tempo moves by more than
  0.001 BPM, the phase by more than 1 ms, or the quantum, start/stop, peers or `publishing` change; at most 20 a
  second. The subscription ends after 3 s without an LB2 ping or on `BYE`.
- `publishing` is 1 while the session's tempo or phase is the subscriber's own timeline (taken in the last 3 s).
- The session is read in the bridge's loop, never between a datagram's arrival and its clock reading.
- A newer protocol (`LB3`) gets `LB2 VERSION`.
- Unit tests on a fake clock and fake session reads; loopback tests with the real library, not enabled; a test with
  a second peer in the network's session (ignored by default); a read-only check against a session on the network.

**Status:** implemented in `bridge/` (`--quantum N` sets the bar reports count beats in, 4 by default). The session
is read with the app-thread capture between receives (a receive waits at most 10 ms), so a change is reported within
about 10 ms when the 50 ms limit allows; on loopback a tempo committed to the bridge's instance was reported after 4-9
ms. `playing` is `unknown` unless the bridge shares start/stop (`--start-stop`), since only then does the instance
hear the other peers' start and stop.

Read-only against real Link on macOS (2026-10-25, `watch_the_session`, 15 s, the session of another Link app on the
same host at 120 BPM): the first report came straight after the first pong with no peers; the bridge joined the
session about half a second later and the peer and the new phase were reported at once; then one report followed
each pong (16 in 15 s, `seq` 1-16 in order), every one at 120 BPM with peers 1 and `publishing` 0, and each report's
phase was within 0.0 µs of where the one before it put it. The tempo was not changed during the run: the session was another app's and was left
alone, and `a_change_by_another_peer_reaches_the_session_report` was not run, since it would move that session; the
loopback test covers a change. Built and tested on macOS only.
