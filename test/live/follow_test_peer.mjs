// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// Live test on grandMA3 onPC: the console follows a test peer on the same machine within a stated tolerance.
//
// It starts gbs-test-peer (which prints its own phase with the wall clock every few milliseconds), then runs a
// follower inside the console for about two seconds: test/live/follow_chunk.lua with plugin/beat_sync_protocol.lua.
// The follower finds the peer's announcements, measures its clock against the peer with ping/pong exchanges, and
// records the session's phase at the start of each console frame. This script compares each console sample with
// the peer's phase at the same wall-clock instant (both run on this machine, so they share the wall clock).
//
// The chunk reaches the console through gma3-mcp's bridge plugin (its "lua" request on 127.0.0.1:9800, with Lua
// enabled), which is only a development path for running code on the console; the follower itself needs no
// bridge. Until BS-02's plugin exists this tests the protocol module, not the plugin.
//
// Prerequisites: onPC running a disposable show, the bridge listening, the console lock held by this session
// (~/Development/gma3/.console-lock), and scripts/check.sh peer.
//
//   node test/live/follow_test_peer.mjs [--scenario steady|tempo-change|stopped] [--tempo BPM] [--tolerance-ms MS]

import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import net from "node:net";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const opts = { scenario: "steady", tempo: 133.5, toleranceMs: 1.0, quantum: 4 };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  const v = process.argv[++i];
  if (a === "--scenario") opts.scenario = v;
  else if (a === "--tempo") opts.tempo = Number(v);
  else if (a === "--tolerance-ms") opts.toleranceMs = Number(v);
  else {
    console.error("usage: follow_test_peer.mjs [--scenario steady|tempo-change|stopped] [--tempo BPM] [--tolerance-ms MS]");
    process.exit(2);
  }
}
if (!["steady", "tempo-change", "stopped"].includes(opts.scenario)) throw new Error(`unknown scenario ${opts.scenario}`);

const lockPath = join(process.env.HOME, "Development", "gma3", ".console-lock");
if (!existsSync(lockPath) || !/beat-sync/.test(readFileSync(lockPath, "utf8"))) {
  console.error(`refusing: take the console lock first (${lockPath} must name this beat-sync session)`);
  process.exit(2);
}

const peerBin = join(root, process.env.BUILD_DIR ?? "build", "tools", "bin", "gbs-test-peer");
const protocol = readFileSync(join(root, "plugin", "beat_sync_protocol.lua"), "utf8");
const chunk = readFileSync(join(root, "test", "live", "follow_chunk.lua"), "utf8");
// The module returns its table; the chunk receives it as P.
const code = `local P = (function(...)\n${protocol}\nend)()\nlocal QUANTUM = ${opts.quantum * 1e6}\n${chunk}`;

function bridgeLua(source) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(9800, "127.0.0.1", () =>
      sock.write(JSON.stringify({ id: "beat-sync-live", op: "lua", args: { code: source } }) + "\n"));
    let buf = "";
    sock.setEncoding("utf8");
    sock.on("data", (d) => {
      buf += d;
      const i = buf.indexOf("\n");
      if (i < 0) return;
      const m = JSON.parse(buf.slice(0, i));
      sock.end();
      if (!m.ok) reject(new Error(typeof m.error === "string" ? m.error : JSON.stringify(m.error)));
      else resolve(m.result);
    });
    sock.on("error", reject);
    setTimeout(() => reject(new Error("bridge timeout")), 15000);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const peerArgs = ["--tempo", String(opts.tempo), "--quantum", String(opts.quantum), "--interval-ms", "5"];
if (opts.scenario !== "stopped") peerArgs.push("--play");
const peer = spawn(peerBin, peerArgs, { stdio: ["pipe", "pipe", "inherit"] });
const peerSamples = [];
const peerEvents = [];
let pending = "";
peer.stdout.setEncoding("utf8");
peer.stdout.on("data", (d) => {
  pending += d;
  let i;
  while ((i = pending.indexOf("\n")) >= 0) {
    const line = pending.slice(0, i);
    pending = pending.slice(i + 1);
    const ev = JSON.parse(line);
    if (ev.ev === "sample") peerSamples.push(ev);
    else peerEvents.push(ev);
  }
});

let result;
let tempoChangeAt;
try {
  await sleep(1500); // the peer applies --play 1 s after enabling
  const run = bridgeLua(code);
  if (opts.scenario === "tempo-change") {
    await sleep(1500);
    tempoChangeAt = Date.now() * 1000;
    peer.stdin.write("tempo 140\n");
  }
  result = await run;
} finally {
  peer.stdin.write("quit\n");
  await sleep(500);
  peer.kill();
}

const value = result?.values?.[0];
if (!value || value.error) {
  console.log(JSON.stringify({ ok: false, scenario: opts.scenario, console: value ?? result }, null, 2));
  process.exit(1);
}

// Console samples: "<wall_us>:<phase micro-beats>:<micros per beat>:<playing 0|1>"
const consoleSamples = value.samples.split(",").map((s) => {
  const [t, phase, mpb, playing] = s.split(":").map(Number);
  return { t, phase: phase / 1e6, mpb, playing: playing === 1 };
});

// The peer's phase at wall time t, interpolated from its nearest earlier sample at its tempo.
function peerPhaseAt(t) {
  let lo = 0, hi = peerSamples.length - 1;
  if (hi < 0 || peerSamples[0].wall_us > t) return null;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (peerSamples[mid].wall_us <= t) lo = mid; else hi = mid - 1;
  }
  const s = peerSamples[lo];
  if (t - s.wall_us > 20000) return null;
  const phase = (s.phase + ((t - s.wall_us) / 1e6) * (s.bpm / 60)) % opts.quantum;
  return { phase, bpm: s.bpm, playing: s.playing };
}

const errorsMs = [];
let excluded = 0;
let tempoMismatch = 0;
let playingMismatch = 0;
for (const c of consoleSamples) {
  // A tempo change takes one announcement to arrive; samples in the 100 ms after it are reported but not judged.
  if (tempoChangeAt && c.t >= tempoChangeAt && c.t < tempoChangeAt + 100000) { excluded++; continue; }
  const p = peerPhaseAt(c.t);
  if (!p) { excluded++; continue; }
  let d = c.phase - p.phase;
  d -= opts.quantum * Math.round(d / opts.quantum);
  errorsMs.push((d * 60000) / p.bpm);
  if (Math.abs(60e6 / c.mpb - p.bpm) > 0.01) tempoMismatch++;
  if (c.playing !== p.playing) playingMismatch++;
}
const abs = errorsMs.map(Math.abs).sort((a, b) => a - b);
const q = (f) => abs[Math.min(abs.length - 1, Math.floor(abs.length * f))];
const mean = errorsMs.reduce((a, b) => a + b, 0) / errorsMs.length;
const summary = {
  scenario: opts.scenario,
  tempo: opts.tempo,
  toleranceMs: opts.toleranceMs,
  samples: consoleSamples.length,
  judged: errorsMs.length,
  excluded,
  phaseErrorMs: { mean: +mean.toFixed(3), median: +q(0.5).toFixed(3), p95: +q(0.95).toFixed(3), max: +abs.at(-1).toFixed(3) },
  tempoMismatch,
  playingMismatch,
  console: { ...value, samples: undefined },
  peerEvents: peerEvents.filter((e) => e.ev !== "ack"),
};
summary.ok = errorsMs.length >= 60 && abs.at(-1) <= opts.toleranceMs && tempoMismatch === 0 && playingMismatch === 0;
console.log(JSON.stringify(summary, null, 2));
process.exit(summary.ok ? 0 : 1);
