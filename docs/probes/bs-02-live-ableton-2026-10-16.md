# Record: the plugin against Ableton Live (BS-02, 2026-10-16)

BS-02 asks for the follower cases of Link's [TEST-PLAN.md](https://github.com/Ableton/link/blob/master/TEST-PLAN.md)
once against Ableton Live. They ran on grandMA3 onPC 2.5.1 (macOS), on the disposable show
`NewShow_2026.10.15_23.16.24UTC`, with the plugin from main (after PR #4) at Plugin 2 and the console lock held.
Sequence 950 was a four-cue chase on fixture 101 with every cue on trigger Go, and Speed master 12 was the tempo
target. Everything was cleaned up afterwards: Plugin 2 and Sequence 950 deleted, the `BeatSync.*` variables
deleted, the master back at 60 BPM with scale One. No show was loaded or saved.

## Setup

- **Ableton Live ran on another computer.** The maintainer pressed Play and Stop in Live, with Start Stop Sync on.
- **Its session reached this Mac through LinkMaster**, the maintainer's relay app. Two or three LinkMaster
  instances ran on this Mac and took part in Live's session on the loopback interfaces. No Link traffic from the
  network reached this Mac directly: neither a capture in a shell (joined on every interface) nor a socket in onPC
  (joined on the default interface) received a packet from another computer.
- So the plugin followed Live's session, and measured its clock through LinkMaster's peers, not through Live itself.
- LinkMaster answered measurement pings more slowly than a Link peer: round trips of 0.9–2.0 ms median, p90
  6.3–9.0 ms, up to 31 ms (`pinger.mjs`, 40 pings to each instance), against 0.30 ms for `gbs-test-peer`. The
  plugin pairs late pongs with their pings across frames, so it measured normally. The test's observer
  (`test/live/observe_chunk.lua`) did not at first; see [Test changes](#test-changes).

## Results

Raw output: [bs-02-live/](bs-02-live/).

| Case | How | Result |
| --- | --- | --- |
| Timing | `plugin_live.mjs timing --external 1 --minutes 2`: `OnBeat` `Go+ Sequence 950` on every beat of Live's session, StartStop off | pass: master 164.4995 BPM for Live's 164.5; cue changes 23.1 ms after the beat on average (as observed; against the test peer 23.3 ms); 10 or 11 per 3.7 s window, no missed beats |
| BEATTIME-1 | — | not repeated: it needs no session at all (starting and stopping the plugin with no session changes neither the speed master nor the chase), and passed against the test peer |
| BEATTIME-2 | `beattime --external 1`: a test peer joins Live's session while the plugin follows it | pass, 2 of 3 runs; the third differed by 9 ms in the observer's lag (below) |
| STARTSTOPSTATE-1 | `startstop --external 1`: the maintainer pressed Play, then Stop, in Live | pass on the final run: the session started on beat 128 (a bar), the first beat action was cue 1 on beat 128, none ran after the stop |

### BEATTIME-2

- In all three runs the joining peer was seen (peers 3 → 4) and took the session's tempo (164.499838 BPM, Link's
  rounding of 164.5).
- The session kept its tempo, its timeline did not change (the plugin's timeline-change count stayed the same),
  and no beat was missed.
- The average lag of the beat actions before and after the join moved by +9.0, +5.0 and −3.6 ms. The test passes
  under 6 ms, so the first run failed.
- These are differences between two independent measurements by the observer. Each window measures the session
  again, through LinkMaster's slow and variable replies, and the actions spread by about 10 ms within a window.
  Nothing in the plugin changed at the join: no re-measurement and no new timeline. So the plugin's beat time did
  not jump; the 9 ms is the observer's noise with this relay.

### STARTSTOPSTATE-1

Four attempts:

1. **No start reached the session.** For 2 minutes the session's start/stop state stayed all zeros, then the relay
   stopped (two of the three LinkMaster processes exited). The maintainer restarted LinkMaster with start/stop
   relaying.
2. **Start and stop followed; the first beat action was on beat 270, the third beat of a bar.** The check then
   expected a bar.
3. **The same, on beat 437.** A capture of this run showed the session's start beat as 436.53: not a bar, not even
   a whole beat. Link plays from the start beat (`link/StartStopState.hpp`), so the first whole beat after it, 437,
   is where the plugin's first beat action belongs, and that is where it ran.
   - The start beat was most likely stamped by the relay when it passed the start on.
   - The check was wrong to expect a bar. It now expects the first whole beat at or after the session's start beat,
     which the observer reads from the announcements.
4. **Final run, pass.** The session started on beat 128.000000 and stopped on 152.000000, both bars, as the capture
   shows.
   - The first beat action was cue 1 on beat 128, 20.7 ms after the beat as observed.
   - The beat actions ran through four 3.25 s windows while playing.
   - After the stop none ran, and `BeatSync.Playing` went from `yes` to `no`.

## Test changes

All in `test/live/`; the plugin did not change.

- **`plugin_live.mjs --external 1`** follows a session already on the network instead of starting a test peer:
  - `timing` checks the speed master against the session's own tempo (with StartStop off, since the session may be
    stopped);
  - `beattime` runs BEATTIME-2 by starting a test peer that joins the session;
  - `startstop` waits up to `--wait-s` for an operator to press Play, then Stop, and checks the first beat action
    against the session's start beat.
- **`observe_chunk.lua`** now copes with a slow responder:
  - after a late pong it reads on, within the 3 ms window, until this ping's own pong, so one slow reply no longer
    makes every later exchange read the previous ping's pong;
  - its limits are 60 timeouts, 120 unusable replies, 400 pings and 1.2 s, still within the bridge's 5 s budget;
  - it reports the session's newest start/stop state.

## Not covered

- **Live's own clock replies.** Only LinkMaster's peers were measured, because Live's packets did not reach this
  Mac directly.
- **A session on another interface or computer heard directly** by the plugin.
- **TEMPO-1 to TEMPO-5 and STARTSTOPSTATE-2.** These are for a full peer, and BS-03 is not built.
