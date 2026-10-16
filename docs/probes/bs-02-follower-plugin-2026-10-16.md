# Record: the follower plugin on the console (BS-02, 2026-10-16)

grandMA3 onPC 2.5.1 on macOS, the disposable show `NewShow_2026.10.15_23.16.24UTC`, with the console lock held.
The plugin (`plugin/gma3_beat_sync.xml`, version 0.1.0) was imported at Plugin 2. Sequence 950 was a four-cue chase
on fixture 101 with every cue on trigger Go, and Speed master 12 was the tempo target; both were checked empty or
unused first. Test peers (`gbs-test-peer`, BS-04) ran on the same machine. Afterwards Plugin 2 and Sequence 950 were
deleted, the master was back at 60 BPM with scale One, every `BeatSync.*` variable was deleted, and the plugin's
files were removed from the user library.

The tests are `test/live/plugin_live.mjs` (scenarios below) and the offline harnesses `test/lua/follower_test.lua`
and `test/lua/plugin_test.lua`. Raw output is in [bs-02/](bs-02/).

## Results

| Scenario | Result |
| --- | --- |
| `timing`, 5 min, `LeadMs` 0 | pass: cue changes 23.3 ms after the beat on average (11 windows, 16.9–28.2 ms), drift −0.59 ms/min, speed master at 127.9997 BPM for a 128 BPM session, no missed beats |
| `timing`, 2 min, `LeadMs` 17 | lag 8.0 ms on average (5 windows, 3.1–13.5 ms); drift not judged on 2 minutes (see below) |
| `beattime` (BEATTIME-1 and -2) | pass |
| `startstop` (STARTSTOPSTATE-1) | pass, 3 runs out of 3 |
| `leave` | pass: ByeBye seen in 429 ms; rejoined at the new session's 140 BPM and rewrote the master; a peer killed without a ByeBye was dropped after 5.0 s |
| show load | the loop ends and must be started again; reported as `not running` (see [Show load](#show-load-with-the-maintainer-at-the-console)) |

### Timing

- The observer sees a cue change at the start of the first frame after it, so its offsets are late by up to a frame
  (about 8 ms on average). The 23 ms lag is therefore about 15 ms of the console's own: a command's effect shows a
  frame after it runs (BS-01 found the same with Go). `BeatSync.LeadMs` 17 moved the average lag to 8 ms, that is
  to about the beat once the observer's half frame is taken off.
- No drift: −0.59 ms/min over 5 minutes, within the noise of the window means. A chase on a rate master drifted
  −2.45 ms/min in BS-01; driving it with `OnBeat` removes that.
- Within a window the offsets spread by 4–13 ms (standard deviation): the frame on which each action runs (±8 ms,
  the frame nearest the beat) plus the observer's frame.
- The 2-minute run's drift estimate (2.55 ms/min) is noise: five window means with about 10 ms of spread cannot
  resolve 1.5 ms/min in 2 minutes. The live test now judges drift only on runs of 5 minutes or more.
- Dropped frames: about 1.3 % of frames were longer than 1.5 times the median (398 in 5.3 minutes) while the
  observer and the status reads ran through the bridge. Without them, the plugin's own frame periods showed single
  29–36 ms frames at about 1 % (the same rate an independent chunk measured with the plugin running or stopped):
  they are the console's, and the plugin reports them in `BeatSync.DroppedFrames`. No beat was missed.

### Link test plan

- **BEATTIME-1** (no session): with no peer on the network, starting the plugin left Speed master 12's fader and
  scale unchanged and ran no beat action (the chase stayed on its cue); `BeatSync.State` was `no session`.
  Stopping it left the master unchanged.
- **BEATTIME-2** (another participant joins): with the plugin following peer A at 120 BPM, peer B (started at
  90 BPM) joined A's session. The session kept 120 BPM, the beat actions' average lag stayed within 1.6 ms
  (19.3 → 17.7 ms), and neither the plugin's timeline-change count nor its missed beats changed.
- **STARTSTOPSTATE-1** (listening to start/stop): with the peer stopped, no beat action ran. After `play` the first
  one was cue 1 on the start bar; after `stop` none ran, and `BeatSync.Playing` went `yes` then `no`.
  - The test peer was alone in its session (the plugin does not announce itself), and Link starts a lone peer at
    once, moving its beat grid so that a bar starts at the moment play is pressed. The plugin learns of the start
    from the next announcement. In the three runs the first beat action came 87.0, 37.8 and 29.6 ms after the start
    bar: the plugin runs a start's first beat as soon as it knows of it, up to 100 ms late
    (`START_GRACE_US` in `plugin/beat_sync_follower.lua`). A peer that starts quantized on a future bar (when other
    announcing peers are in its session) is followed on that bar, as the offline tests show.
- **Not yet done:** these cases against Ableton Live, once, as the ticket asks. No Link compatibility is claimed.

## Found and fixed during the live tests

Each has an offline regression test that fails without the fix:

- **A start already past was skipped.** The first live run of `startstop` began on the beat after the start bar.
  The follower now restarts its beat count a frame back and runs a start's first beat up to 100 ms late
  (`follower_test.lua`: starts heard 5 ms, 70 ms and 150 ms late).
- **A timeline change counted beats as missed.** A start that moves the grid made the follower count the beats in
  between as missed (2 at start-up in the first console run). A new timeline now restarts the count
  (`follower_test.lua`: a 2.5-beat jump).
- **`Playing` was written empty when stopped.** `pos and pos.playing or nil` turns `false` into `nil`
  (`plugin_test.lua`: `Playing` is `no` after a stop).
- **The speed master's SpeedScale reads as an enum index** (0 = One, 1 = Mul2), not its name, so comparing it with
  "Mul2" rewrote it on every tempo write. The name comes from `master:Get("SpeedScale", Enums.Roles.Display)`
  (`plugin_test.lua`: the scale is written once). `master:Set("SpeedScale", "Mul2")` works, and `At BPM 300` then
  gave a base of 150 BPM ("300 *B").
- On stop, the final status write replaced `stopped` with the follower's state (`plugin_test.lua`: State `stopped`).

## Console facts

- **Components:** the plugin's three `ComponentLua` chunks run at import with a shared signal table; the protocol and
  follower modules register there and the main chunk looks them up when it starts.
- **`CmdIndirect('Plugin "gma3_beat_sync"')`** starts the loop without blocking the caller; `Plugin "gma3_beat_sync"
  "stop"` reaches the running loop, which ends at its next frame.
- **Global variables:**
  - `GetVar` costs about 0.09 ms, `SetVar` about 0.0005 ms. Reading the whole configuration (28 variables) takes
    about 2.6 ms, twice a second; the status (17 variables) four times a second is negligible.
  - A variable set to an empty string reads back as `nil`.
  - "no", "off" and "false" stay strings.

## Show load (with the maintainer at the console)

The maintainer saved the throwaway show's state under a new name, `beat-sync-showload` (so the throwaway show's file
was not touched), with the plugin imported at Plugin 2, configured (Master 12) and following a test peer. They then
loaded it with `LoadShow "beat-sync-showload"` and restarted gma3-mcp's bridge.

- **The plugin's loop ends at a show load.** Its last status update was the moment of the load (03:13:52Z); its
  configuration and the variables saved with the show came back, so `BeatSync.State` still read `following`, stale.
  Starting it with `Plugin "gma3_beat_sync"` worked at once: following again, one loop (no interleaved frames).
- **The plugin cannot restart itself.** The console runs the plugin's chunks again at a show load (and at import),
  and the chunk saw the loaded show's variables at import. But a `CmdIndirect('Plugin "gma3_beat_sync" "resume"')`
  issued from the chunk never reached the plugin, and a `Timer()` started there was accepted but never called back
  (checked at import, and the first for a show load too). gma3-mcp's bridge needs the same manual restart after a
  show load.
- **So the plugin reports it:** the chunk now marks the shared status, and a saved `BeatSync.State` other than
  `stopped`, as `not running` (seen at import on the console; covered by `plugin_test.lua` for a show load). The
  docs say to start the plugin after loading a show, and to treat a `BeatSync.Updated` older than 2 s as not
  running.
- Loading the throwaway show back from its file brought back the bridge version saved in it (0.30.0); the
  bridge must be reinstalled after such a load.

## Not tested here

- **Ableton Live.** Not installed on this machine.
- **A session on another machine or interface.**
- **Whether writing status variables marks the show as changed** or adds undo steps.
