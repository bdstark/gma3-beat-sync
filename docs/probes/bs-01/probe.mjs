// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// BS-01 probe driver (not part of the product). Runs probe steps on grandMA3 onPC through gma3-mcp's bridge plugin
// (its "lua" and "cmd" requests on 127.0.0.1:9800), the development path onto the console. Needs the console lock.
//
//   node docs/probes/bs-01/probe.mjs install <slot>     copy gbs_probe into the user library, import at Plugin <slot>
//   node docs/probes/bs-01/probe.mjs loop [frames]      second plugin loop beside the bridge
//   node docs/probes/bs-01/probe.mjs timer [s] [count]  Timer() instead of a loop
//   node docs/probes/bs-01/probe.mjs uninstall <slot>   delete Plugin <slot> if it is gbs_probe
// The responder test starts gbs_probe directly and pings it with pinger.mjs:
//   probe.mjs lua "CmdIndirect('Plugin \"gbs_probe\" \"responder 20900 900\"')"; node pinger.mjs 20900 300
//   node docs/probes/bs-01/probe.mjs lua '<code>'       one chunk, printed as JSON

import { copyFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { bridge, lua } from "./bridge.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const libDir = join(process.env.HOME, "MALightingTechnology", "gma3_library", "datapools", "plugins");

async function slotInfo(slot) {
  const [v] = await lua(`local p = DataPool().Plugins[${slot}]; return p and { name = p.name, no = p.no } or "empty"`);
  return v;
}

async function install(slot) {
  const before = await slotInfo(slot);
  if (before !== "empty") throw new Error(`Plugin ${slot} is not empty: ${JSON.stringify(before)}`);
  for (const f of ["gbs_probe.xml", "gbs_probe.lua"]) copyFileSync(join(here, f), join(libDir, f));
  const { result } = await bridge("cmd", { command: `Import Plugin Library "gbs_probe.xml" At Plugin ${slot}` });
  await sleep(1000);
  console.log(JSON.stringify({ import: result, after: await slotInfo(slot) }, null, 2));
}

async function uninstall(slot) {
  const info = await slotInfo(slot);
  if (info === "empty" || info.name !== "gbs_probe") throw new Error(`Plugin ${slot} is not gbs_probe: ${JSON.stringify(info)}`);
  await lua(`CmdIndirect('Plugin "gbs_probe" "stop"')`);
  await sleep(500);
  const { result } = await bridge("cmd", { command: `Delete Plugin ${slot} /NoConfirmation` });
  await sleep(500);
  console.log(JSON.stringify({ delete: result, after: await slotInfo(slot) }, null, 2));
}

// Starts the probe plugin asynchronously, measures bridge round trips while it runs, then reads its results from
// the shared Lua global and the console global variable.
async function runProbe(argument, seconds) {
  const baseline = [];
  for (let i = 0; i < 20; i++) baseline.push((await bridge("ping", {})).ms);
  await lua(`_G.gbs_probe = nil; CmdIndirect('Plugin "gbs_probe" "${argument}"')`);
  const during = [];
  const reads = [];
  const t0 = Date.now();
  while (Date.now() - t0 < seconds * 1000) {
    during.push((await bridge("ping", {})).ms);
    if (during.length % 20 === 1) {
      const [v] = await lua(`local s = _G.gbs_probe; return s and { frames = s.frames, running = s.running } or "none"`);
      reads.push({ atMs: Date.now() - t0, ...((typeof v === "object" && v) || { value: v }) });
    }
    await sleep(50);
  }
  for (let i = 0; i < 40; i++) {
    const [v] = await lua(`local s = _G.gbs_probe; return s and s.running`);
    if (v === false) break;
    await sleep(250);
  }
  const [shared, globalVar] = await lua(
    `return _G.gbs_probe, GetVar(GlobalVars(), "gbs_probe")`);
  const stats = (a) => {
    const s = [...a].sort((x, y) => x - y);
    return { n: s.length, median: +s[s.length >> 1].toFixed(2), p95: +s[Math.floor(s.length * 0.95)].toFixed(2), max: +s.at(-1).toFixed(2) };
  };
  console.log(JSON.stringify({ argument, bridgePingMs: { baseline: stats(baseline), during: stats(during) }, reads, shared, globalVar }, null, 2));
}

const [cmd, a, b] = process.argv.slice(2);
if (cmd === "install") await install(Number(a));
else if (cmd === "uninstall") await uninstall(Number(a));
else if (cmd === "loop") await runProbe(`loop ${a ?? 600}`, (Number(a ?? 600) / 60) + 1);
else if (cmd === "timer") await runProbe(`timer ${a ?? 0.02} ${b ?? 300}`, Number(a ?? 0.02) * Number(b ?? 300) + 2);
else if (cmd === "lua") console.log(JSON.stringify(await lua(a), null, 2));
else {
  console.error("usage: probe.mjs install <slot> | loop [frames] | timer [s] [count] | uninstall <slot> | lua '<code>'");
  process.exit(2);
}
process.exit(0);
