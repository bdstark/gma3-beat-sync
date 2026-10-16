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

## BS-03 — Full peer (only if BS-01 shows it is safe)

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
