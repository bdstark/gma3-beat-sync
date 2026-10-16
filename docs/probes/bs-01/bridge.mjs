// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// BS-01 probe helper (not part of the product): one request to gma3-mcp's bridge plugin on 127.0.0.1:9800, the
// development path onto the console. Refuses to run unless this session holds the console lock.

import { readFileSync, existsSync } from "node:fs";
import net from "node:net";
import { join } from "node:path";

const lockPath = join(process.env.HOME, "Development", "gma3", ".console-lock");
if (!existsSync(lockPath) || !/beat-sync/.test(readFileSync(lockPath, "utf8"))) {
  console.error(`refusing: take the console lock first (${lockPath})`);
  process.exit(2);
}

export function bridge(op, args, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const t0 = process.hrtime.bigint();
    const sock = net.connect(9800, "127.0.0.1", () =>
      sock.write(JSON.stringify({ id: "bs-01-probe", op, args }) + "\n"));
    let buf = "";
    sock.setEncoding("utf8");
    sock.on("data", (d) => {
      buf += d;
      const i = buf.indexOf("\n");
      if (i < 0) return;
      const m = JSON.parse(buf.slice(0, i));
      sock.end();
      const ms = Number(process.hrtime.bigint() - t0) / 1e6;
      if (!m.ok) reject(new Error(typeof m.error === "string" ? m.error : JSON.stringify(m.error)));
      else resolve({ result: m.result, ms });
    });
    sock.on("error", reject);
    setTimeout(() => reject(new Error(`bridge timeout (${op})`)), timeoutMs);
  });
}

export async function lua(code) {
  const { result } = await bridge("lua", { code });
  return result.values;
}

