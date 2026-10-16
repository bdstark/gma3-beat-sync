// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// BS-03 probe (not part of the product): how far off a Link peer is when it measures the session through a console
// that takes part as a full peer from a plugin (answering pings only once per frame).
//
//   node docs/probes/bs-03/peer_probe.mjs [--seconds 4.5] [--runs 3] [--compensate 1]
//
// Each run starts gbs-test-peer (in its own session at 100 BPM, printing its phase with the wall clock every 5 ms),
// then runs peer_chunk.lua in the console: the console founds a session at 120 BPM whose timeline is exact by
// construction (beat 0 at wall-clock time 0) and answers pings once per frame. The test peer sees it, measures it,
// and joins it (Link prefers the session whose ghost time is ahead, link/Sessions.hpp). After the join the test
// peer's phase is compared with the console's exact phase at the same wall-clock instant; the difference is the
// error the console's slow replies cause. Needs the console lock, an otherwise quiet network (no other Link apps:
// an announcing console could take over their session) and scripts/check.sh peer.

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { lua, checkLock } from "../../../test/live/bridge.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const opts = { seconds: 4.5, runs: 3, compensate: 0 };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 2) opts[argv[i].replace(/^--/, "")] = Number(argv[i + 1]);
checkLock();

const protocol = readFileSync(join(root, "plugin", "beat_sync_protocol.lua"), "utf8");
const chunk = readFileSync(join(here, "peer_chunk.lua"), "utf8");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const luaBytes = (buf) => '"' + [...buf].map((b) => "\\" + String(b).padStart(3, "0")).join("") + '"';

async function run() {
  const node = randomBytes(8);
  const peer = spawn(join(root, "build", "tools", "bin", "gbs-test-peer"), ["--tempo", "100", "--interval-ms", "5"],
    { stdio: ["pipe", "pipe", "inherit"] });
  const samples = [], events = [];
  let buf = "";
  peer.stdout.setEncoding("utf8");
  peer.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const e = JSON.parse(buf.slice(0, i));
      buf = buf.slice(i + 1);
      (e.ev === "sample" ? samples : events).push(e);
    }
  });
  await sleep(1500);
  const code = `local P = (function(...)\n${protocol}\nend)()\nlocal DURATION_US, NODE, COMPENSATE = ${Math.round(opts.seconds * 1e6)}, ${luaBytes(node)}, ${opts.compensate ? "true" : "false"}\n${chunk}`;
  let console_;
  try {
    [console_] = await lua(code);
  } finally {
    peer.stdin.write("quit\n");
    await sleep(400);
    peer.kill();
  }
  if (console_.error) throw new Error(console_.error);
  // samples after the peer joined the console's session (its tempo became 120) and the console still ran
  const joinedEv = events.find((e) => e.ev === "tempo" && Math.abs(e.bpm - 120) < 0.01);
  const judged = samples.filter((s) => Math.abs(s.bpm - 120) < 0.01 && s.wall_us < console_.finish && (!joinedEv || s.wall_us > joinedEv.wall_us));
  const errs = judged.map((s) => {
    const ours = (s.wall_us / 500000) % 4; // beats into the bar on the console's exact timeline
    let d = s.phase - ours;
    d -= 4 * Math.round(d / 4);
    return d * 500; // ms at 120 BPM
  });
  const sorted = [...errs].sort((a, b) => a - b);
  const q = (f) => (sorted.length ? +sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * f))].toFixed(3) : null);
  const mean = errs.length ? +(errs.reduce((a, b) => a + b, 0) / errs.length).toFixed(3) : null;
  return {
    console: console_,
    joined: !!joinedEv,
    joinedAfterMs: joinedEv ? Math.round((joinedEv.wall_us - console_.start) / 1000) : null,
    judgedSamples: errs.length,
    errorMs: { mean, min: q(0), median: q(0.5), max: q(1) },
  };
}

const runs = [];
for (let i = 0; i < opts.runs; i++) {
  const r = await run();
  runs.push(r);
  console.error(JSON.stringify({ run: i + 1, joined: r.joined, joinedAfterMs: r.joinedAfterMs, errorMs: r.errorMs,
    pings: r.console.pings, answered: r.console.answered }));
  await sleep(1000);
}
console.log(JSON.stringify({ runs }, null, 2));
process.exit(0);
