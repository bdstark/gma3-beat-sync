// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// BS-01 probe (not part of the product): how a chase linked to a speed master stays on the session's beats.
//
//   node docs/probes/bs-01/drift.mjs <sequence> <master> [--tempo BPM] [--minutes M] [--every S] [--action A]
//
// It starts a test peer at the tempo (playing), then runs window_chunk.lua through the bridge: the first window sets
// the speed master to the session's tempo and starts the chase on a beat; later windows (every S seconds, for M
// minutes) only record when the chase changes cue. --action applies in every later window: setbpm-bar (write the
// tempo again every bar), resync-bar (ReSync the sequence every bar), go-beat (a Go on every beat).
// Each cue change is placed on the session's beat grid: its offset from the nearest beat, in ms. The drift is how
// that offset moves over time. Changes are seen at the start of the first frame after them, so each offset is late
// by up to one frame (about 16.7 ms); the mean over a window is late by about half a frame, the same in every
// window.
//
// The sequence must be a chase (cues with trigger Time, one beat per cue at 60 BPM) whose RateMaster is the
// master. Needs the console lock and scripts/check.sh peer.

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { lua } from "./bridge.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = process.env.GBS_ROOT ?? join(here, "..", "..", "..");
const [seqArg, masterArg, ...rest] = process.argv.slice(2);
const opts = { tempo: 128, minutes: 5, every: 60, action: "" };
for (let i = 0; i < rest.length; i += 2) opts[rest[i].replace(/^--/, "")] = rest[i + 1];
const seq = Number(seqArg), master = Number(masterArg);
if (!seq || !master) {
  console.error("usage: drift.mjs <sequence> <master> [--tempo BPM] [--minutes M] [--every S] [--action A]");
  process.exit(2);
}

const protocol = readFileSync(join(root, "plugin", "beat_sync_protocol.lua"), "utf8");
const chunk = readFileSync(join(here, "window_chunk.lua"), "utf8");
const code = (action, frames) =>
  `local P = (function()\n${protocol}\nend)()\nlocal SEQ, MASTER, ACTION, FRAMES = ${seq}, ${master}, ${action ? `"${action}"` : "nil"}, ${frames}\n${chunk}`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const peer = spawn(join(root, "build", "tools", "bin", "gbs-test-peer"),
  ["--tempo", String(opts.tempo), "--play", "--interval-ms", "0"], { stdio: ["pipe", "ignore", "inherit"] });

function offsets(w) {
  const [mpb, bo, to] = w.timeline.split(",").map(Number);
  return (w.changes ? w.changes.split(",") : []).map((c) => {
    const [h, cue] = c.split(":").map(Number);
    const beat = bo + ((h + w.intercept - to) / mpb) * 1e6; // micro-beats on the session timeline
    let frac = (beat % 1e6) / 1e6;
    if (frac >= 0.5) frac -= 1;
    return { t: h, cue, offsetMs: (frac * mpb) / 1000 };
  });
}

const windows = [];
try {
  await sleep(1500);
  const start = Date.now();
  let first = true;
  for (let k = 0; ; k++) {
    const due = start + k * opts.every * 1000;
    if (due > start + opts.minutes * 60000 + 1000) break;
    while (Date.now() < due) await sleep(200);
    if (first) {
      const [w0] = await lua(code("setbpm", 2)); // the tempo first, applied a frame later
      if (w0.error) throw new Error(w0.error);
    }
    const [w] = await lua(code(first ? "go" : opts.action, 220));
    if (w.error) throw new Error(w.error);
    first = false;
    const os = offsets(w);
    const ms = os.map((o) => o.offsetMs);
    const mean = ms.reduce((a, b) => a + b, 0) / (ms.length || 1);
    const sd = Math.sqrt(ms.reduce((a, b) => a + (b - mean) ** 2, 0) / (ms.length || 1));
    const steps = os.slice(1).map((o, i) => (o.t - os[i].t) / 1000);
    windows.push({ atS: Math.round((Date.now() - start) / 1000), changes: os.length, meanOffsetMs: +mean.toFixed(2),
      sdMs: +sd.toFixed(2), stepMs: steps.map((s) => +s.toFixed(1)), acts: w.acts || undefined, bpm: w.bpm });
    console.error(JSON.stringify(windows.at(-1)));
  }
} finally {
  peer.stdin.write("quit\n");
  await sleep(300);
  peer.kill();
  await lua(`Cmd("Off Sequence ${seq}")`);
}

const valid = windows.filter((w) => w.changes > 0);
const driftMs = valid.length > 1 ? valid.at(-1).meanOffsetMs - valid[0].meanOffsetMs : null;
const spanS = valid.length > 1 ? valid.at(-1).atS - valid[0].atS : 0;
console.log(JSON.stringify({ sequence: seq, master, tempo: Number(opts.tempo), action: opts.action || "none",
  windows, driftMs: driftMs && +driftMs.toFixed(2), overS: spanS }, null, 2));
process.exit(0);
