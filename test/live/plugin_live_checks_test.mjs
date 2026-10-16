// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// Offline test of the judgements in test/live/plugin_live_checks.mjs (run by scripts/check.sh scripts).
// Usage: node test/live/plugin_live_checks_test.mjs

import { judgeStartStop, checkExternalTempo, bpmFromMpb } from "./plugin_live_checks.mjs";

let failures = 0;
const check = (ok, what) => { if (!ok) { failures++; console.error("FAIL: " + what); } };

const cue = (c, beat) => ({ cue: c, beat, offsetMs: 20, barPos: ((beat % 4) + 4) % 4 });
const start128 = { playing: true, beats: 128 };

// The review's boundary case: the start is seen at the end of a window that has no cue change yet; cue 1 on beat 128
// is in the next window.
{
  const r = judgeStartStop([
    { changes: [], playing: "no", startStop: null },
    { changes: [], playing: "yes", startStop: start128 },
    { changes: [cue(1000, 128), cue(2000, 129)], playing: "yes", startStop: start128 },
    { changes: [cue(3000, 130)], playing: "no", startStop: { playing: false, beats: 131 } },
    { changes: [], playing: "no", startStop: { playing: false, beats: 131 } },
  ]);
  check(r.started && r.firstChange && r.firstChange.beat === 128, "boundary: the first cue is found in the next window");
  check(r.expectedFirstBeat === 128 && r.firstOk, "boundary: judged against the start beat 128");
  check(r.stopped && r.noneAfterStop, "boundary: stop seen, nothing after it");
}

// The start and the first cue in the same window; a start beat that is not a whole beat (a relay's stamp)
{
  const r = judgeStartStop([
    { changes: [cue(1000, 437), cue(2000, 438)], playing: "yes", startStop: { playing: true, beats: 436.527656 } },
    { changes: [], playing: "no", startStop: { playing: false, beats: 460 } },
    { changes: [], playing: "no", startStop: null },
  ]);
  check(r.firstOk && r.expectedFirstBeat === 437, "fractional start: first whole beat 437");
}

// Failures are failures: a first cue on the wrong beat, a beat action after the stop, no start at all
{
  const late = judgeStartStop([
    { changes: [cue(1000, 129)], playing: "yes", startStop: start128 },
    { changes: [], playing: "no", startStop: null },
    { changes: [], playing: "no", startStop: null },
  ]);
  check(!late.firstOk, "a first cue one beat late fails");
  const after = judgeStartStop([
    { changes: [cue(1000, 128)], playing: "yes", startStop: start128 },
    { changes: [], playing: "no", startStop: null },
    { changes: [cue(2000, 140)], playing: "no", startStop: null },
  ]);
  check(after.stopped && !after.noneAfterStop, "a beat action after the stop fails");
  check(!judgeStartStop([{ changes: [], playing: "no", startStop: null }]).started, "no start: not started");
  const noCue = judgeStartStop([
    { changes: [], playing: "yes", startStop: start128 },
    { changes: [], playing: "no", startStop: null },
  ]);
  check(noCue.started && !noCue.firstOk, "a start with no beat action fails");
}

// External tempo: judged against the session's own timeline, not the plugin's report
{
  check(Math.abs(bpmFromMpb(500000) - 120) < 1e-9 && Math.abs(bpmFromMpb(364742) - 164.5) < 0.001, "bpm from mpb");
  const wrong = checkExternalTempo({ observerMpb: 500000, masterBpm: 130, reportedTempo: "130.000" });
  check(!wrong.masterOk && !wrong.reportOk, "the review's case: plugin and master both 130 for a 120 BPM session fail");
  const right = checkExternalTempo({ observerMpb: 364742, masterBpm: 164.4995, reportedTempo: "164.500" });
  check(right.masterOk && right.reportOk, "164.5 BPM session, master 164.4995, report 164.500 pass");
  const reportOnly = checkExternalTempo({ observerMpb: 500000, masterBpm: 120.0001, reportedTempo: "121.000" });
  check(reportOnly.masterOk && !reportOnly.reportOk, "a wrong report alone fails");
}

console.log(`plugin_live_checks_test: ${failures} failure(s)`);
process.exit(failures ? 1 : 0);
