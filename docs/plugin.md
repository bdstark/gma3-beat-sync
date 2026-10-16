# The plugin

`gma3_beat_sync` follows a tempo session on the local network and drives the show from it. It is meant to be
compatible with Link™; see [Compatibility](#compatibility) for what has been tested.

- A speed master follows the session's tempo.
- Chosen sequences are realigned (`ReSync`) on every bar.
- Commands run on beats, every N beats, on bars, and when the session starts, stops, is joined or is left. Each runs
  on the console frame nearest its beat.

The plugin follows without announcing itself: other apps in the session do not see it, and it never changes the
session's tempo or start/stop state. (A plugin cannot answer the other apps' clock measurements promptly enough to
take part as a full peer; see the [BS-01 record](probes/bs-01-follow-from-console-2026-10-16.md#measurement).)

## Install

The plugin is four files in `plugin/`: `gma3_beat_sync.xml`, `gma3_beat_sync.lua`, `beat_sync_protocol.lua` and
`beat_sync_follower.lua`.

1. Copy them into the grandMA3 user library: `scripts/install-plugin.sh` (onPC on macOS; set `GMA3_LIBRARY` for
   another library folder), or copy them by hand into `gma3_library/datapools/plugins`.
2. Check that a plugin slot is empty, then import into it:
   ```
   Import Plugin Library "gma3_beat_sync.xml" At Plugin 2
   ```
3. Start it:
   ```
   Plugin "gma3_beat_sync"
   ```

Commands:

| Command | What it does |
| --- | --- |
| `Plugin "gma3_beat_sync"` | start following; the plugin runs until stopped |
| `Plugin "gma3_beat_sync" "stop"` | stop at the next frame; the speed master keeps its last tempo |
| `Plugin "gma3_beat_sync" "status"` | print the state, peers, tempo, beat, problems and the last action |

The plugin runs beside other plugins (it was tested beside gma3-mcp's bridge). It does not depend on gma3-mcp.

**After loading a show, start the plugin again.** A show load ends the plugin's loop, and the plugin cannot start
itself again (BS-02 record). The plugin and its configuration are saved with the show; when the show is loaded,
`BeatSync.State` reads `not running` until `Plugin "gma3_beat_sync"` is given again.

## Configuration

Configuration is in console global variables named `BeatSync.<Key>`, so it is saved with the show. Set them from
the command line, a macro or another tool, before or while the plugin runs:

```
SetGlobalVariable "BeatSync.Master" "3"
SetGlobalVariable "BeatSync.Resync" "1, 5, 12"
SetGlobalVariable "BeatSync.Action1" "16 0 Go+ Macro 5"
```

The plugin reads them when it starts and every half second. A missing variable takes its default.

| Variable | Default | Meaning |
| --- | --- | --- |
| `BeatSync.Master` | (none) | Speed master 1–16 to set to the session's tempo (`Master 3.<n>`). It is written when the plugin joins a session, when this variable changes, after a show load and when the tempo moves by `TempoThreshold`; a refused write is tried again every second. Above 225 BPM, its SpeedScale is raised (Mul2, Mul4, Mul8); it is never lowered, and a scale the console does not take is reported (the tempo is then not written). |
| `BeatSync.Quantum` | `4` | Beats per bar, 1–64. |
| `BeatSync.StartStop` | `on` | `on`: beat and bar actions run only while the session plays; `off`: always. |
| `BeatSync.Resync` | (none) | Sequences to `ReSync` on every bar, separated by commas or spaces. |
| `BeatSync.OnBar` | (none) | A command on every bar. |
| `BeatSync.OnBeat` | (none) | A command on every beat. |
| `BeatSync.Action1` … `BeatSync.Action16` | (none) | `<N> <phase> <command>`: the command on every Nth beat, on the beats where (beat − phase) is a multiple of N. Phase 0..N−1. Beat 0 is the session's bar grid, shared by all apps in the session. |
| `BeatSync.OnStart`, `BeatSync.OnStop` | (none) | A command when the session starts or stops playing. |
| `BeatSync.OnJoin`, `BeatSync.OnLeave` | (none) | A command when the plugin joins a session, or the session's last peer leaves. |
| `BeatSync.TempoThreshold` | `0.01` | The tempo change, in BPM, that rewrites the speed master. |
| `BeatSync.LeadMs` | `0` | Run beat actions this many milliseconds early. The console shows the effect of a command about one frame (17 ms) after it runs; see [Timing](#timing). |
| `BeatSync.Interfaces` | `127.0.0.1 0.0.0.0` | Addresses to listen for the session on. `0.0.0.0` is the default network interface; `127.0.0.1` hears apps on the same computer. Add the address of another network interface to hear sessions there. Read when the plugin starts. |

Commands are console command lines, as typed. Problems in the configuration (a speed master or sequence that does
not exist, an action that is not `<N> <phase> <command>`, a bad quantum) are reported in `BeatSync.Problems`; the
rest of the configuration still works.

The console answers every command with text: `OK`, or a reason such as `Object not found`. An answer that says it
failed is reported (`failed: …` in `BeatSync.LastAction`, and `BeatSync.Error`); any other answer is reported as
`uncertain: …`. A command is never sent again because of its answer.

## Status

The plugin writes its status four times a second into console global variables. Read them with
`GetGlobalVariable "BeatSync.State"` on the command line, or `GetVar(GlobalVars(), "BeatSync.State")` in Lua.
The values are text. An empty value reads back as no value (`nil` in Lua). The variables are saved with the show,
so a reader should also check `BeatSync.Updated`: a time more than 2 s old means the plugin is not running, whatever
`BeatSync.State` says.

| Variable | Meaning |
| --- | --- |
| `BeatSync.State` | `following`, `measuring` (peers seen, clock not yet measured), `no session`, `no session (configuration problems)`, `stopped`, `not running` (after a show load or a re-import) or `error` |
| `BeatSync.Peers` | Number of apps seen in sessions on the network |
| `BeatSync.Session` | The followed session's id (16 hex digits) |
| `BeatSync.Tempo` | Session tempo in BPM, three decimals |
| `BeatSync.Beat`, `BeatSync.Phase` | Session beat, and the position in the bar (0 to Quantum), two decimals |
| `BeatSync.Playing` | `yes` or `no` (the session's start/stop state) |
| `BeatSync.LastAction` | The last command run: what, the command, the beat, and how far from its beat it ran (`+1.2 ms` = late); `failed: …` when the console refused it |
| `BeatSync.DriftMsPerMin` | Clock drift between the console and the session, from the clock measurements (every 30 s) |
| `BeatSync.FrameMs`, `BeatSync.FrameJitterMs` | Median console frame period, and how far the 90th percentile is above it, over the last 2 s |
| `BeatSync.DroppedFrames` | Frames longer than 1.5 times the median since the plugin started |
| `BeatSync.MissedBeats` | Beats not run because a frame was more than a frame late |
| `BeatSync.Problems` | Configuration problems, separated by `; ` |
| `BeatSync.Error` | The last error |
| `BeatSync.Version`, `BeatSync.Updated` | Plugin version, and the time of this status (UTC) |

The shared Lua table `BeatSync.status` (global `BeatSync`) has the same and more for Lua readers: `joined`
(interfaces and any that failed), `counters` (packets, rejected packets, pongs, measurements, failed measurements,
missed beats, timeline changes), `warnings` and `errors` (the last ten each, such as "joined session …", "left
session …", "show loaded: …"), `frame_periods_us` (the last 120 frame periods) and `show`.

## Timing

- **Actions** run on the frame nearest their beat: within half a frame (about ±8 ms at 60 frames a second). The
  console shows a command's effect about a frame (15–17 ms) after it runs. On onPC 2.5.1, a chase advanced by
  `OnBeat` `Go+ Sequence …` changed cue 23 ms after the beat on average as seen by a test observer (which itself
  sees a change up to a frame late), with no drift over 5 minutes. `BeatSync.LeadMs` 17 brought that to 8 ms, that
  is about on the beat. See the [BS-02 record](probes/bs-02-follower-plugin-2026-10-16.md#timing).
- **Chases on a speed master** follow its tempo, but on the console's own clock: they drift from the session by a
  few ms a minute (BS-01). For a chase that must stay on the beat, give its cues trigger Go and advance it with
  `BeatSync.OnBeat` or an `Action`.
- **Starting.** When the session starts on a bar in the future (an app that starts quantized while other apps are in
  its session), the first beat action runs on that bar. An app that is alone in its session (the plugin does not
  count, since it does not announce itself) starts at once; the plugin hears of it a few tens of ms later and runs
  the start's first beat action late, as soon as it knows (up to 100 ms late; later than that, it starts with the
  next beat).
- **Missed frames.** When the console misses frames, a beat whose frame is more than one frame late is skipped and
  counted in `BeatSync.MissedBeats`, rather than run late.

## What the plugin accepts from the network

- **Timelines:** a session's tempo must be within Link's range, 20 to 999 BPM (60 060 to 3 000 000 µs a beat), and
  its beats and times within ±2^53. Messages with values outside are ignored (`counters.invalid_timelines`); the
  last valid state stays, so a bad message can never set the speed master.
- **Capacity:** at most 64 peers and 16 sessions are kept, and a peer's announced lifetime is honoured up to 30 s.
  When a table is full, the entry seen longest ago is replaced, except the followed session and the one being
  measured and their peers (`counters.evicted_peers`, `evicted_sessions`, `dropped`).
- **Measurement:** a measurement fails after 5 unanswered pings, 20 answers that bring no timing, 300 pings or 2 s.
  A session whose first measurement failed is tried again after 1 s, then 2, 4 … up to 30 s, while it is
  announced (`counters.failed`, `retries`; `failed_sessions` in the status table). Only a session with a peer that
  announces an IPv4 measurement endpoint is measured; one without waits until such a peer appears and does not hold
  up the others. When the followed session leaves, the plugin moves at once to another measured session, if there
  is one.

## Network and security

The plugin listens on UDP port 20808 and joins the multicast group 224.76.78.75, and sends clock measurement
requests to the apps it finds. The protocol has no authentication: any device on the console's network can announce
a session and so drive the tempo and the configured commands. Run it only on a network you control. See
[SECURITY.md](../SECURITY.md).

## Compatibility

The applicable cases of Link's [TEST-PLAN.md](https://github.com/Ableton/link/blob/master/TEST-PLAN.md) for a
follower are BEATTIME-1, BEATTIME-2 and STARTSTOPSTATE-1. They pass against a test peer built from the Link library
(`gbs-test-peer`) on onPC 2.5.1. They have **not yet been run against Ableton Live**, so no compatibility with Link
is claimed yet.
