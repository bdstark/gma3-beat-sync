// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// The judgements of test/live/plugin_live.mjs that do not need a console, as pure functions, so that
// test/live/plugin_live_checks_test.mjs can test them offline.

// The session tempo in BPM from a timeline's micros per beat, as Link computes it (link/Tempo.hpp).
export function bpmFromMpb(mpb) {
  return 60e6 / mpb;
}

// Checks the speed master and the plugin's reported tempo against the session's tempo decoded independently (by the
// observer, from the announcements). Returns { expected, masterOk, reportOk }.
export function checkExternalTempo({ observerMpb, masterBpm, reportedTempo, tolerance = 0.01 }) {
  const expected = bpmFromMpb(observerMpb);
  return {
    expected: +expected.toFixed(4),
    masterOk: Math.abs(masterBpm - expected) < tolerance,
    reportOk: Math.abs(parseFloat(reportedTempo) - expected) < tolerance,
  };
}

// Judges STARTSTOPSTATE-1 from the observer windows, in order. Each window is { changes: [{ cue, beat, ... }],
// playing: "yes" | "no" (the plugin's status at the end of the window), startStop: { playing, beats } | null (the
// session's newest start/stop state, decoded by the observer) }.
// The start is when the session (or the plugin) first says it plays; the first beat action is the first cue change
// in that window or any later one, so a start near a window's end still finds its first action in the next window.
// Returns { started, startState, firstChange, expectedFirstBeat, firstOk, stopped, afterStop, noneAfterStop }.
export function judgeStartStop(windows) {
  let startIdx = -1, startState = null;
  for (let i = 0; i < windows.length; i++) {
    const w = windows[i];
    if (w.playing === "yes" || (w.startStop && w.startStop.playing) || w.changes.length > 0) {
      startIdx = i;
      break;
    }
  }
  if (startIdx < 0) return { started: false };
  // the session's start state: the first playing state seen from the start on
  for (let i = startIdx; i < windows.length && !startState; i++) {
    if (windows[i].startStop && windows[i].startStop.playing) startState = windows[i].startStop;
  }
  let firstChange = null;
  for (let i = startIdx; i < windows.length && !firstChange; i++) {
    if (windows[i].changes.length > 0) firstChange = windows[i].changes[0];
  }
  const expectedFirstBeat = startState ? Math.ceil(startState.beats - 1e-6) : null;
  let stopIdx = -1;
  for (let i = startIdx + 1; i < windows.length; i++) {
    if (windows[i].playing === "no") { stopIdx = i; break; }
  }
  const afterStop = stopIdx >= 0 && stopIdx + 1 < windows.length ? windows[stopIdx + 1] : null;
  return {
    started: true,
    startState,
    firstChange,
    expectedFirstBeat,
    firstOk: !!firstChange && firstChange.cue === 1000 && expectedFirstBeat !== null && firstChange.beat === expectedFirstBeat,
    stopped: stopIdx >= 0,
    afterStop,
    noneAfterStop: !!afterStop && afterStop.changes.length === 0,
  };
}
