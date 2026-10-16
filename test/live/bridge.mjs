// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// Live-test helper: one request to gma3-mcp's bridge plugin on 127.0.0.1:9800 (JSON lines: {id, op, args}), the
// development path for running test code on the console. The plugin itself does not need the bridge. Refuses to
// run unless this session holds the console lock (~/Development/gma3/.console-lock naming a beat-sync session).
//
//   node test/live/bridge.mjs lua '<chunk>'      print the chunk's return values as JSON
//   node test/live/bridge.mjs cmd '<command>'    run one command line, print the feedback

import { readFileSync, existsSync } from "node:fs";
import net from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const lockPath = join(process.env.HOME, "Development", "gma3", ".console-lock");

export function checkLock() {
  if (!existsSync(lockPath) || !/beat-sync/.test(readFileSync(lockPath, "utf8"))) {
    throw new Error(`take the console lock first (${lockPath} must name this beat-sync session)`);
  }
}

export function bridge(op, args, timeoutMs = 15000) {
  checkLock();
  return new Promise((resolve, reject) => {
    const sock = net.connect(9800, "127.0.0.1", () =>
      sock.write(JSON.stringify({ id: "beat-sync-live", op, args }) + "\n"));
    let buf = "";
    const timer = setTimeout(() => { sock.destroy(); reject(new Error(`bridge timeout (${op})`)); }, timeoutMs);
    sock.setEncoding("utf8");
    sock.on("data", (d) => {
      buf += d;
      const i = buf.indexOf("\n");
      if (i < 0) return;
      clearTimeout(timer);
      const m = JSON.parse(buf.slice(0, i));
      sock.end();
      if (!m.ok) reject(new Error(typeof m.error === "string" ? m.error : JSON.stringify(m.error)));
      else resolve(m.result);
    });
    sock.on("error", (e) => { clearTimeout(timer); reject(e); });
  });
}

export async function lua(code) {
  return (await bridge("lua", { code })).values;
}

export async function cmd(command) {
  return (await bridge("cmd", { command })).feedback;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [op, arg] = process.argv.slice(2);
  try {
    if (op === "lua") console.log(JSON.stringify(await lua(arg), null, 2));
    else if (op === "cmd") console.log(await cmd(arg));
    else { console.error("usage: bridge.mjs lua '<chunk>' | cmd '<command>'"); process.exit(2); }
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
