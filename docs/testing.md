# Testing

gma3-beat-sync is tested at three levels: the Lua harness with stock Lua 5.5, the test tools built from the Link
library in `modules/link`, and live tests on grandMA3 onPC.

## Checks (no console)

```sh
scripts/check.sh            # everything below
scripts/check.sh spdx       # every source file carries SPDX-License-Identifier: GPL-2.0-or-later
scripts/check.sh lua        # every .lua file parses with Lua 5.5
scripts/check.sh harness    # test/lua/*_test.lua
scripts/check.sh peer       # builds tools/test-peer into build/tools/bin, checks the test peer's JSON lines
scripts/check.sh fixtures   # every fixture's expect lines are what Link's parser reads (needs peer)
scripts/check.sh vectors    # test/fixtures/vectors.txt is what Link's arithmetic gives (needs peer)
scripts/check.sh bridge     # the bridge: cargo fmt --check, clippy -D warnings, cargo test (not part of "everything")
```

CI runs the same steps on Ubuntu with Lua 5.5.1 built from lua.org.

### The bridge (`bridge/`)

`cargo test -p link-bridge` runs, without joining the network's Link session:
- `src/bridge.rs`: the protocol state on a fake clock (pongs, ordering per run, a new run, `BYE`, the 3 s silence,
  `VERSION` and its limits, malformed datagrams);
- `src/publish.rs`: what a timeline does to a fake session (tempo, bar phase, a jump by whole bars, the tolerances,
  quantum 0, `stop`, start/stop sharing);
- `tests/loopback.rs`: the bridge on a loopback socket with a real Link instance that is not enabled. Every Link
  instance in a process reads the same clock, so the offset a sender measures from 16 pings must be 0; it is checked
  to be under 1 ms. A `play` timeline sets the instance's tempo and phase, a jump by whole bars leaves the phase.

`tests/link_session.rs` is ignored by default because it **joins the Link session on the network** and moves its
tempo and phase: every Link app on the network follows it. Run it only when nothing else is in the session:

```sh
cargo test -p link-bridge --test link_session -- --ignored --nocapture
```

It starts the bridge with Link enabled and a second Link peer in the same process, checks that the bridge counts the
peer in its pongs and that the offset is under 1 ms, sends `play` timelines, and waits until the second peer has the
tempo (within 0.001 BPM) and the bar phase (within 1 ms), then checks that a jump by whole bars leaves it.

### The harness (`test/lua/protocol_test.lua`)

It tests `plugin/beat_sync_protocol.lua` against Link's own code:

1. **Arithmetic:** every line of `test/fixtures/vectors.txt` (from `gbs-vectors`) is reproduced exactly: tempo,
   `toBeats`/`fromBeats`, phase and phase matching, phase-encoded beats, ghost transforms, the median and the
   client timeline update.
2. **Parsing:** every `packet` line in `test/fixtures/*.txt` is decoded and described the way `gbs-capture`
   describes Link's own reading of it (the `expect` line). The fixtures are captures from test peers and hand-made
   variants (malformed, truncated, unusual).
3. **Ping encoding:** the pings in the captures were encoded by Link's code; the module's pings match byte for
   byte.
4. **Measurement:** the data points of each captured pong agree within its round trip.
5. **Robustness:** every truncation of every fixture packet, and 20 random byte changes of each, decode without
   raising.

### The follower (`test/lua/follower_test.lua`)

It drives `plugin/beat_sync_follower.lua` with simulated peers (Alive, ByeBye and pong packets in the Link
layouts) on a simulated clock: measurement and the ghost-host offset, beats on the frame nearest them and bars on
the quantum, stop and leave, the 5 s ttl, pongs that do not belong to the ping in flight, failing measurements,
the choice between two sessions and between timelines of one session (as `link/Sessions.hpp` does), quantized and
immediate starts, the lead, missed beats, a quantum change, a timeline change, and the drift between measurements.
Peer mode (BS-03): founding its own session, its announcements and ByeBye, compensated pongs, joining a session that
is ahead and staying in it when its peers leave, another peer joining its session, tempo and start/stop proposals,
and joining a playing session without playing (STARTSTOPSTATE-2).

### The plugin (`test/lua/plugin_test.lua`)

It loads the plugin's three components as the console does (the shared signal table) with the console API mocked
(global variables, speed masters, sequences, `Cmd`, `Printf`) and mocked sockets, and runs `Main` one resume per
frame with an instruction limit per resume and a check that no frame blocks for more than 8 ms. Scenarios: following
with the speed master, `ReSync` and `OnBar` on the bars, numbered actions, `OnJoin` and `OnStart`; tempo changes
(threshold, SpeedScale above 225 BPM written once); stopping; configuration problems and fixing them while running;
ByeBye, rejoining and the ttl; StartStop on and off; failing commands; a show load; a second start and unknown
arguments. Peer mode: alone, the master keeps its tempo (TEMPO-5); started into a session, the master takes its tempo
(TEMPO-2); Responses to Alive messages, pings answered, an operator's tempo change sent without a write-back
(TEMPO-1), `play` and `pause`, ByeBye on stop, a missing interface address, a bad `Mode`, and no status variable
sharing a name with a configuration variable.

### The live chunk offline (`test/lua/follow_chunk_test.lua`)

It runs `test/live/follow_chunk.lua` with mocked sockets and a simulated clock, one resume per frame, and checks
that every resume yields within an instruction limit, that the time blocked per frame stays within the
measurement's budget, and that the chunk ends and closes its sockets. Scenarios: discovery flooded with other
packets, pongs that bring no data points, pongs of another ping or session, no replies, the normal path, and
flooding while following.

### The test peer's output (`tools/test-peer/json_lines_test.sh`)

`scripts/check.sh peer` runs it after the build: commands with quotes, backslashes, control characters and UTF-8
come back in valid JSON lines. It needs `python3` to parse them.

## Test tools (`tools/test-peer`)

```sh
build/tools/bin/gbs-test-peer --tempo 128 --play --interval-ms 20
```

- `gbs-test-peer [--tempo BPM] [--quantum BEATS] [--interval-ms MS] [--duration-s S] [--play] [--no-start-stop-sync] [--disabled]`
  joins a session through Link and prints JSON lines: `start`, `sample` (every interval), `peers`, `tempo`,
  `startstop`, `ack`, `end`. Each sample has `wall_us` (wall clock), `host_us` (Link's clock), `bpm`, `beat`,
  `phase`, `quantum`, `playing`, `peers`. Commands on stdin, one per line: `tempo <bpm>`, `play`, `stop`,
  `quantum <beats>`, `enable`, `disable`, `sample`, `quit`. `--play` plays 1 s after enabling (see the
  [BS-04 record](probes/bs-04-protocol-and-test-peer-2026-10-15.md#observations)).
- `gbs-capture [--seconds S] [--ping N] [--note TEXT]` records discovery packets and N ping/pong exchanges as a
  fixture; `gbs-capture --decode` (re)labels fixture lines read from stdin.
- `gbs-vectors` prints the arithmetic reference values.

`scripts/record-fixtures.sh` re-records the captured fixtures. Captures contain the machine's interface
addresses; record them only on a network you control.

The tools can stand in for Ableton Live in Link's [TEST-PLAN.md](https://github.com/Ableton/link/blob/master/TEST-PLAN.md)
cases where the plan uses LinkHut.

## Live tests on onPC

Prerequisites:

- grandMA3 onPC on the same machine, with a disposable show loaded;
- gma3-mcp's bridge plugin listening on 127.0.0.1:9800 with Lua enabled. It is the development path for running
  test code inside the console; the plugin itself does not need it;
- the console lock (`~/Development/gma3/.console-lock`) held by this session when the console is shared;
- `scripts/check.sh peer`.

```sh
node test/live/follow_test_peer.mjs --scenario steady         # also: tempo-change, stopped
node test/live/plugin_live.mjs timing --minutes 5             # also: beattime, startstop, leave, peer-tempo, peer-startstop
```

`plugin_live.mjs` tests the plugin itself: it must be imported, and `--sequence` (default 950) must be a chase whose
cues all have trigger Go. The test sets `BeatSync.*` variables and `--master` (default 12), and restores the
master and deletes the variables afterwards. An independent observer (`test/live/observe_chunk.lua`, with its own
measurement of the session) places each cue change the plugin causes on the session's beat grid:

| Scenario | What it checks |
| --- | --- |
| `timing` | `OnBeat` `Go+ Sequence …` on every beat for `--minutes`: the lag of the cue changes behind the beats, their drift (less than 1.5 ms a minute), the speed master at the session tempo, no missed beats |
| `beattime` | Link BEATTIME-1: without a session, starting and stopping the plugin changes neither the speed master nor the chase. BEATTIME-2: a second peer joining the followed session changes neither its tempo nor the timing of the beat actions |
| `startstop` | Link STARTSTOPSTATE-1: no beat actions while stopped; after the peer plays, the first one is cue 1 on the start bar; none after it stops; `Playing` follows |
| `leave` | a peer that quits is gone within 1.5 s (ByeBye); rejoining picks up the new tempo and rewrites the speed master; a peer that vanishes is dropped after its 5 s ttl |
| `peer-tempo` | BS-03, `Mode` `peer`: TEMPO-5 (alone, the console founds a session at its master's 100 BPM; the master is unchanged); a test peer that joins takes the console's tempo; TEMPO-2 (started into a test peer's session at 130 BPM with its master at 90, the console joins and the master goes to 130); TEMPO-1 (the master moved to 140 reaches the test peer, the test peer's 125 reaches the master); TEMPO-4 (20 and 999 BPM reach the master) |
| `peer-startstop` | BS-03, STARTSTOPSTATE-2: joining a playing test peer's session, the console is not playing while the test peer plays on; `pause` stops the test peer; `play` starts it on a bar of the session |

The peer scenarios need a network with no other Link app (stop any relay such as LinkMaster): the console's
session and tempo changes would reach it. They need no chase: run them with `--sequence 0`. `peer-tempo` also
measures the clock error of a test peer that measured the console through the plugin's replies (it must be within
1 ms).

`--external 1` runs `timing`, `beattime` (BEATTIME-2) and `startstop` against a session already on the network,
such as Ableton Live's, instead of a test peer; for `startstop` an operator presses Play, then Stop, in the app
within `--wait-s` seconds. See the [Ableton Live record](probes/bs-02-live-ableton-2026-10-16.md).

`follow_test_peer.mjs` starts a test peer, runs `test/live/follow_chunk.lua` (with the protocol module) inside the console for about
two seconds, and compares the console's phase at each frame with the test peer's phase at the same wall-clock
instant. It passes when every judged sample is within the tolerance (default 1 ms, `--tolerance-ms`), the tempo
and the start/stop state match, and at least 60 samples were judged. Results are in the
[BS-04 record](probes/bs-04-protocol-and-test-peer-2026-10-15.md#first-console-follow-live-test).
