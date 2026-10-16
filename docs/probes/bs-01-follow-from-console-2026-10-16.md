# Probe: following a Link session from the console (BS-01, 2026-10-16)

grandMA3 onPC 2.5.1 on macOS, the disposable show `NewShow_2026.10.15_23.16.24UTC`, with the console lock held.
The test peer (`gbs-test-peer`, BS-04) ran on the same machine. Probe code ran in the console through gma3-mcp's
bridge plugin (its `lua` and `cmd` requests), the development path onto the console, and in a probe plugin. The
probe used and then removed Plugin 2 (`gbs_probe`), Sequence 950 (a four-step chase on fixture 101), Speed
master 12 (back to 60 BPM, scale One) and a few global variables. Each slot was checked empty first. Scripts are in
[bs-01/](bs-01/).

Protocol facts are in the [BS-04 record](bs-04-protocol-and-test-peer-2026-10-15.md), with their Link source
files.

## Decision

- **A follower only.** A plugin answers measurement pings only once per frame, which would add about 5 ms of
  error to every peer that measures the session through the console (see [Measurement](#measurement)).
  BS-03 (a full peer) is not built. The follower never announces itself and never changes the session.
- **Its loop is a plugin frame loop** (a `Main` that yields once per frame), beside other plugins' loops.
  `Timer(fn, 0, count)` is the fallback: it also calls back every frame.
- **Configuration and status live in console global variables**, named `BeatSync.<Key>`:
  - configuration is set with `SetGlobalVariable "BeatSync.<Key>" "<value>"` from the command line, a macro or
    another tool, and is saved with the show;
  - status is written by the plugin a few times a second, readable with `GetGlobalVariable` or `GetVar`;
  - the plugin also keeps its full status in a shared Lua table for Lua readers.

  BS-02 fixes the names and formats; gma3-mcp's SU-17 builds on them.

## Discovery

- **Received inside the console:** a plugin socket bound to 0.0.0.0:20808 that joined 224.76.78.75 on 127.0.0.1
  received the test peer's announcements (124 packets in 10 s in the probe plugin). Messages were parsed by
  `plugin/beat_sync_protocol.lua` (BS-04's harness checks it against Link's parser). The message format, header
  and entries are in the BS-04 record.
- **Same machine needs loopback:** joining on `0.0.0.0` alone (the default interface) hears nothing from a peer on
  the same Mac (BS-04). The plugin must join on 127.0.0.1 as well as on the network interface. LuaSocket cannot
  list the interfaces, so the interface addresses come from configuration.
- **Peers leaving, in Link:** a ByeBye (message type 3) removes a peer at once
  (`discovery/UdpMessenger.hpp`, `receiveByeBye`); a peer that stops announcing is dropped when its ttl passes
  (5 s, `discovery/PeerGateway.hpp`, the prune timer). This probe established only that ByeBye messages are
  decoded (BS-04's captured fixtures). **Removing peers from the follower's state, on a ByeBye and after the ttl, is
  not tested here; it is BS-02's to implement and verify.**

## Measurement

- **A peer answers a follower that never announced itself** (`link/PingResponder.hpp` replies to any ping; seen
  live in BS-04).
- **Accuracy inside one frame:** 51 exchanges, 101 points, done in 82–98 ms over 5 frames (at most 10 exchanges
  per frame, each receive bounded to 3 ms). The followed phase matched the test peer's own phase within 0.022 ms
  (BS-04 live test).
- **Answering pings from a plugin is too slow for a full peer.** `gbs_probe` in responder mode answered pings once
  per frame; `pinger.mjs` pinged it 300 times at random moments:

  | Responder | Round trip median | p90 | max |
  | --- | --- | --- | --- |
  | Link test peer (`gbs-test-peer`) | 0.30 ms | 0.50 ms | 2.96 ms |
  | Plugin, once per frame | 9.34 ms | 15.95 ms | 35.9 ms |

  A measuring peer takes the pong's ghost time as being half way through the round trip
  (`link/Measurement.hpp`), so a reply delayed by d adds d/2 of error. The median of 100 points would be about
  4.7 ms off, more than the 3 ms tolerance of Link's AUDIOENGINE-1 case. A plugin cannot answer sooner: Lua runs
  only on the console's frames, and waiting longer inside a frame would stall the console.

## Two plugins

- **Two frame loops run together.** `gbs_probe loop 600`, started with `CmdIndirect`, ran 600 frames beside the
  bridge's loop: frame median 16.5 ms, p90 18.2 ms, p99 23.0 ms, max 30.5 ms (4 frames over 25 ms). The bridge kept
  answering: round trip median 15.9 ms during the loop, 17.3 ms before.
- **A second invocation reaches a running loop:** `Plugin "gbs_probe" "stop"` ended the loop at the next frame.
- **`Timer()` works as well:** `Timer(fn, 0, 120)` called back every frame (median 16.6 ms, max 28.5 ms);
  `Timer(fn, 0.02, 150)` rounded to every one or two frames (median 16.8 ms, p90 32.8 ms). The interval may be
  fractional, despite the manual's "integer".
- `CmdIndirect` starts a plugin without blocking the caller (the manual: "executed asynchronously in the Main
  task").

## Shared state

| Where | Readable by | Written by | Notes |
| --- | --- | --- | --- |
| Console global variables (`GlobalVars()`) | command line (`GetGlobalVariable`), macros, every plugin (`GetVar`) | command line (`SetGlobalVariable`), plugins (`SetVar`) | saved with the show; `SetVar` took 0.02 ms (median, 40 writes at 4 Hz) |
| A shared Lua global (`_G`) | other plugins' Lua (the bridge read `_G.gbs_probe`) | the plugin | not saved; Lua only |
| Show objects | everything | everything | heavier; not needed |

- Names with dots and spaces work (`BeatSync.Tempo`, `BeatSync Tempo`).
- `SetGlobalVariable "BeatSync.Master" "3"` from the command line reads back in Lua as the string `"3"`; a number
  set with `SetVar` reads back as a number.
- **`GetVar` of a missing variable returns no value at all**, not `nil`: `tostring(GetVar(g, "missing"))` raises
  "bad argument #1 to 'tostring' (value expected)". Wrap it: `(GetVar(g, name))`.
- `GetGlobalVariable` prints the value to the command line history; its command feedback is just "OK".
- Not checked: whether writing variables marks the show as changed or adds undo steps. BS-02 checks it before
  writing status regularly.

## Console actions

Speed master 12 drove the chase on Sequence 950 (four cues, trigger Time 1 s, Wrap Around, RateMaster Speed12, so
one cue per beat). The test peer played at 128 BPM (468.75 ms a beat). `drift.mjs` set the master to the session
tempo, started the chase with a Go on a beat, then every 30 s ran a 220-frame window that re-measured the peer and
recorded each cue change with the wall clock. Each change's offset from the nearest session beat is late by up to
one frame, because it is seen at the next frame; a window's mean is late by about half a frame, the same in every
window, so changes in the mean are drift.

### Speed master writes

| Written with `Master 3.12 At BPM x` | Fader read back | BPM from the fader | Error |
| --- | --- | --- | --- |
| 120 | 71.917421 | 119.999881 | −0.00012 |
| 133.5 | 76.052701 | 133.499965 | −0.00004 |
| 87.654321 | 60.995793 | 87.654232 | −0.00009 |
| 20 | 28.103518 | 19.999976 | −0.00002 |
| 224.9 | 99.976605 | 224.899635 | −0.00037 |
| 226, 300 | 100 | 225 | clamped silently |

- The fader formula (BPM = 225 · (fader / 100)^log2(3.75)) and the clamp at 225 match gma3-mcp's SB-06 record.
  Above 225 BPM the plugin must raise the master's SpeedScale (Link's range is 20–999 BPM).
- The command took 0.05–0.12 ms on the plugin thread; the fader changed one or two frames later. `SetFader` on the
  master's handle also works (0.02–0.03 ms) but was not applied by the next frame in one case; `Cmd` is the path.
- **Writing the same tempo every bar causes no jump:** the chase's step lengths stayed the same (465–475 ms, the
  spread being the frame sampling) and no step was cut short or repeated.

### Drift

| Run | Window means (ms, every 30 s) | Drift |
| --- | --- | --- |
| tempo set once, 5 min | 47.7, 38.2, 38.2, 39.7, 35.1, 37.3, 35.0, 33.4, 33.4, 32.0, 31.1 | −2.45 ms/min (regression); −16.6 ms over 299 s |
| tempo rewritten every bar, 2 min | 52.8, 52.0, 48.7, 45.6, 45.7 | −7.2 ms over 120 s |
| `ReSync Sequence 950` every bar, 2 min | 42.8, 38.6, 36.0, 36.5, 32.4 | −10.4 ms over 119 s |
| a Go on every beat, 2 min | 47.4, 30.3, 31.6, 30.1, 29.6 | none after the first window (constant ~30 ms) |

- A chase that follows a rate master runs on the console's own clock and gains on the session by about 2.5 ms a
  minute (about 40 ppm), far more than the tempo's 0.0004 BPM error explains (under 1 ms in 5 minutes). Over a
  four-minute song that is about 10 ms; over an hour, 150 ms. So the plugin must realign, not only set the tempo.
- **`ReSync` does nothing measurable to a chase.** The manual: ReSync "is used to gradually synchronize phasers".
- **A Go on each beat holds a chase on the beat** with a constant lag of about 30 ms: the Go was sent on the first
  frame after the beat (0–17 ms late), the console applied it on a later frame, and the change was seen a frame
  after that. The constant part can be compensated by sending the Go a frame early. With the cues still on trigger
  Time, the Go and the time trigger sometimes both fired (two 33 ms steps in 2 minutes), so a beat-driven chase
  needs its cues on trigger Go.
- **Phasers could not be observed.** This onPC has no DMX output grant, so no output can be read, and no Lua
  function gives a phaser's running phase (gma3-mcp SB-06). The effect of `ReSync` on phasers and their drift
  remain open for a console with output, or by eye.

## Answers to the ticket

| Question | Answer |
| --- | --- |
| Discovery: receive, parse, peers leaving | received and parsed, with a loopback membership for same-machine peers; ByeBye decoded; removal on ByeBye and after the ttl pending BS-02 |
| Measurement from a silent follower | answered; 0.02 ms phase error against the test peer |
| Two plugin loops | yes; `Timer(fn, 0, n)` also works |
| Shared state | console global variables for configuration and status, plus a shared Lua table |
| `ReSync` | nothing measurable on chases; phasers not observable here |
| Speed master every bar | no visible jump in a chase |
| Drift over 5 minutes | about −2.5 ms/min for a rate-master chase; none with a Go per beat |
| Follower or full peer | follower only |

## Scripts

- [bs-01/gbs_probe.lua](bs-01/gbs_probe.lua), [bs-01/gbs_probe.xml](bs-01/gbs_probe.xml): the probe plugin (frame
  loop, `Timer()`, responder).
- [bs-01/probe.mjs](bs-01/probe.mjs): install, loop, timer and uninstall steps; [bs-01/bridge.mjs](bs-01/bridge.mjs)
  sends bridge requests and refuses without the console lock.
- [bs-01/pinger.mjs](bs-01/pinger.mjs): ping round trips.
- [bs-01/drift.mjs](bs-01/drift.mjs) and [bs-01/window_chunk.lua](bs-01/window_chunk.lua): the chase drift runs;
  their output is in [bs-01/results/](bs-01/results/).
- **The measurements above were taken with earlier versions of the scripts.** After the runs, review added bounds:
  - `window_chunk.lua`: at most 32 packets per frame; measurement bounded per frame, in total and in time; unpaired
    or pointless pongs fail it;
  - `gbs_probe.lua`: at most 32 packets per frame in its loop and responder modes;
  - `pinger.mjs`: null statistics when nothing answers, and a refused count that is not a positive integer.

  None of the recorded runs came near the bounds (at most a couple of packets per frame, every ping answered), so
  the revised scripts measure the same things; they were not re-run live. Offline tests:
  `test/lua/probe_plugin_test.lua` and `docs/probes/bs-01/pinger_test.mjs`.
