// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// BS-01 probe (not part of the product): pings a responder the way link/Measurement.hpp does (a ping with __ht,
// waiting up to 50 ms for the pong) at random moments, and reports the round trips. Against gbs_probe's
// "responder" mode this shows how late a plugin answers pings; against a Link peer, how prompt Link is.
//
//   node docs/probes/bs-01/pinger.mjs <port> [count] [address]

import dgram from "node:dgram";

const [port, count = "200", address = "127.0.0.1"] = process.argv.slice(2);
const sock = dgram.createSocket("udp4");
const micros = () => Number(process.hrtime.bigint() / 1000n);
const ping = (t) => {
  const b = Buffer.alloc(9 + 16);
  b.write("_link_v\x01\x01", 0, "latin1");
  b.write("__ht", 9, "latin1");
  b.writeUInt32BE(8, 13);
  b.writeBigInt64BE(BigInt(t), 17);
  return b;
};

const rtts = [];
let timeouts = 0;
let pending = null;
sock.on("message", (msg) => {
  if (!pending || msg.length < 9 || msg[8] !== 2) return;
  const now = micros();
  // the pong ends with our ping's payload: __ht, size 8, our host time
  const ht = Number(msg.readBigInt64BE(msg.length - 8));
  if (ht !== pending.t) return;
  rtts.push((now - pending.t) / 1000);
  clearTimeout(pending.timer);
  pending.done();
});

await new Promise((r) => sock.bind(0, "127.0.0.1", r));
for (let i = 0; i < Number(count); i++) {
  await new Promise((r) => setTimeout(r, 5 + Math.random() * 35));
  await new Promise((done) => {
    const t = micros();
    pending = { t, done, timer: setTimeout(() => { timeouts++; done(); }, 50) };
    sock.send(ping(t), Number(port), address);
  });
  pending = null;
}
sock.close();
const s = [...rtts].sort((a, b) => a - b);
const q = (f) => +s[Math.min(s.length - 1, Math.floor(s.length * f))].toFixed(3);
const mean = s.reduce((a, b) => a + b, 0) / s.length;
console.log(JSON.stringify({ port: Number(port), pings: Number(count), pongs: s.length, timeouts,
  rttMs: { min: q(0), median: q(0.5), mean: +mean.toFixed(3), p90: q(0.9), max: q(1) },
  // a measuring peer assumes the pong's ghost time was taken half way through the round trip
  impliedErrorMs: { median: +(q(0.5) / 2).toFixed(3), max: +(q(1) / 2).toFixed(3) } }));
