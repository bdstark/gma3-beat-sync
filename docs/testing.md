# Testing

gma3-beat-sync is tested at three levels: the Lua harness with stock Lua 5.5, the test tools built from the Link
library in `modules/link`, and live tests on grandMA3 onPC.

## Checks (no console)

```sh
scripts/check.sh            # everything below
scripts/check.sh spdx       # every source file carries SPDX-License-Identifier: GPL-2.0-or-later
scripts/check.sh lua        # every .lua file parses with Lua 5.5
scripts/check.sh harness    # test/lua/*_test.lua
scripts/check.sh peer       # builds tools/test-peer into build/tools/bin
scripts/check.sh fixtures   # every fixture's expect lines are what Link's parser reads (needs peer)
scripts/check.sh vectors    # test/fixtures/vectors.txt is what Link's arithmetic gives (needs peer)
```

CI runs the same steps on Ubuntu with Lua 5.5.1 built from lua.org.

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
```

It starts a test peer, runs `test/live/follow_chunk.lua` (with the protocol module) inside the console for about
two seconds, and compares the console's phase at each frame with the test peer's phase at the same wall-clock
instant. It passes when every judged sample is within the tolerance (default 1 ms, `--tolerance-ms`), the tempo
and the start/stop state match, and at least 60 samples were judged. Results are in the
[BS-04 record](probes/bs-04-protocol-and-test-peer-2026-10-15.md#first-console-follow-live-test).
