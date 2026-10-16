// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// Offline test of pinger.mjs: against a port where nothing answers, it reports every ping as a timeout with null
// (unavailable) statistics; against a local responder, real round trips; a count that is not a positive integer is
// refused. Usage: node docs/probes/bs-01/pinger_test.mjs

import { spawnSync, spawn } from "node:child_process";
import dgram from "node:dgram";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pinger = join(dirname(fileURLToPath(import.meta.url)), "pinger.mjs");
let failures = 0;
const check = (ok, what) => { if (!ok) { failures++; console.error("FAIL: " + what); } };

// a free UDP port with nothing listening
const probe = dgram.createSocket("udp4");
await new Promise((r) => probe.bind(0, "127.0.0.1", r));
const freePort = probe.address().port;
probe.close();

const silent = spawnSync(process.execPath, [pinger, String(freePort), "3"], { encoding: "utf8" });
check(silent.status === 0, "no replies: exits 0 (" + silent.status + " " + silent.stderr + ")");
let r = {};
try { r = JSON.parse(silent.stdout); } catch { check(false, "no replies: prints JSON: " + silent.stdout); }
check(r.pings === 3 && r.pongs === 0 && r.timeouts + r.errors === 3, "no replies: 3 pings, 0 pongs, 3 timeouts or errors");
check(r.rttMs && Object.values(r.rttMs).every((v) => v === null), "no replies: round trips are null, not 0");
check(r.impliedErrorMs && r.impliedErrorMs.median === null && r.impliedErrorMs.max === null, "no replies: implied error null");

for (const bad of ["0", "-1", "2.5", "x"]) {
  const out = spawnSync(process.execPath, [pinger, String(freePort), bad], { encoding: "utf8" });
  check(out.status === 2, `count ${bad} is refused (${out.status})`);
}

// a responder that echoes the payload as a pong
const resp = dgram.createSocket("udp4");
resp.on("message", (msg, from) => {
  const pong = Buffer.concat([Buffer.from("_link_v\x01\x02", "latin1"), msg.subarray(9)]);
  resp.send(pong, from.port, from.address);
});
await new Promise((res) => resp.bind(0, "127.0.0.1", res));
const child = spawn(process.execPath, [pinger, String(resp.address().port), "5"], { encoding: "utf8" });
let out = "";
child.stdout.on("data", (d) => (out += d));
await new Promise((res) => child.on("exit", res));
resp.close();
const ok = JSON.parse(out);
check(ok.pongs === 5 && ok.timeouts === 0 && ok.rttMs.median > 0, "a responder: 5 pongs with round trips");

console.log(`pinger_test: ${failures} failure(s)`);
process.exit(failures ? 1 : 0);
