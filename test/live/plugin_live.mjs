// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// Live tests of the plugin (BS-02) on grandMA3 onPC against test peers on the same machine.
//
//   node test/live/plugin_live.mjs <scenario> [--sequence 950] [--master 12] [--lead-ms 0] [--minutes 2]
//
// Scenarios:
//   timing     the plugin follows a peer at 128 BPM and runs "Go+ Sequence <sequence>" on every beat; the speed
//              master gets the session tempo. An independent observer (observe_chunk.lua, its own measurement)
//              places every cue change on the session's beat grid, every 30 s for --minutes: the lag and the
//              drift of the plugin's beat actions (drift is judged with --minutes 5 or more).
//   beattime   Link TEST-PLAN BEATTIME-1 (no session: starting and stopping the plugin changes neither the speed
//              master nor the chase) and BEATTIME-2 (a second peer joins the followed session: no jump in the
//              plugin's beats).
//   startstop  Link TEST-PLAN STARTSTOPSTATE-1: beat actions start on the session's quantized start (the next bar)
//              and stop with it.
//   leave      a peer that quits (ByeBye) or vanishes (no ByeBye, ttl), then comes back.
//
// --external 1 follows a session that is already on the network (an app such as Ableton Live) instead of starting
// a test peer: timing checks the speed master against the session's own tempo; beattime runs BEATTIME-2 only (a test
// peer joins the external session; BEATTIME-1 needs no session at all); startstop waits up to --wait-s seconds
// (default 120) for the session to start, then for it to stop, while an operator presses Play and Stop in the app;
// leave is not available.
//
// Prerequisites: onPC with a disposable show, gma3-mcp's bridge on 127.0.0.1:9800 with Lua enabled (the
// development path for the observer and for reading status), the console lock, scripts/check.sh peer, the plugin
// imported (scripts/install-plugin.sh, then Import Plugin Library "gma3_beat_sync.xml" At Plugin <empty slot>), and
// a chase on --sequence whose cues all have trigger Go. The test sets BeatSync.* variables and the speed master and
// restores the master's tempo and scale afterwards; it deletes the BeatSync.* configuration it set.

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { lua, checkLock } from "./bridge.mjs";
import { judgeStartStop, checkExternalTempo } from "./plugin_live_checks.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const [scenario, ...rest] = process.argv.slice(2);
const opts = { sequence: 950, master: 12, "lead-ms": 0, minutes: 2, external: 0, "wait-s": 120 };
for (let i = 0; i < rest.length; i += 2) opts[rest[i].replace(/^--/, "")] = Number(rest[i + 1]);
if (!["timing", "beattime", "startstop", "leave"].includes(scenario)) {
  console.error("usage: plugin_live.mjs timing|beattime|startstop|leave [--sequence N] [--master N] [--lead-ms MS] [--minutes M]");
  process.exit(2);
}
checkLock();

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const protocol = readFileSync(join(root, "plugin", "beat_sync_protocol.lua"), "utf8");
const observer = readFileSync(join(here, "observe_chunk.lua"), "utf8");
const peerBin = join(root, process.env.BUILD_DIR ?? "build", "tools", "bin", "gbs-test-peer");
const SEQ = opts.sequence, MASTER = opts.master;
const CONFIG_KEYS = ["Master", "OnBeat", "OnBar", "OnStart", "OnStop", "OnJoin", "OnLeave", "LeadMs", "StartStop", "Resync", "Quantum"];

const results = { scenario, checks: [], ok: true };
function check(ok, what, detail) {
  results.checks.push({ ok: !!ok, what, ...(detail === undefined ? {} : { detail }) });
  if (!ok) results.ok = false;
}

const luaStr = (s) => JSON.stringify(String(s)); // a Lua string literal for ASCII text

async function setConfig(cfg) {
  const lines = Object.entries(cfg).map(([k, v]) => `SetVar(GlobalVars(), ${luaStr("BeatSync." + k)}, ${luaStr(v)})`);
  await lua(lines.join("\n") + "\nreturn 1");
}
async function clearConfig() {
  await lua(CONFIG_KEYS.map((k) => `DelVar(GlobalVars(), ${luaStr("BeatSync." + k)})`).join("\n") + "\nreturn 1");
}
async function status() {
  const keys = ["State", "Peers", "Tempo", "Beat", "Playing", "LastAction", "MissedBeats", "DroppedFrames", "Problems", "Error"];
  const [v, counters] = await lua(`local g = GlobalVars() local r = {}
for _, k in ipairs(${JSON.stringify(keys).replace("[", "{").replace("]", "}")}) do r[k] = (GetVar(g, "BeatSync." .. k)) end
return r, BeatSync and BeatSync.status and BeatSync.status.counters`);
  return { ...v, counters };
}
async function startPlugin() { await lua(`CmdIndirect('Plugin "gma3_beat_sync"') return 1`); await sleep(500); }
async function stopPlugin() {
  await lua(`CmdIndirect('Plugin "gma3_beat_sync" "stop"') return 1`);
  for (let i = 0; i < 20; i++) {
    await sleep(250);
    if ((await status()).State === "stopped") return;
  }
  throw new Error("the plugin did not stop");
}
async function masterState() {
  const [f, scale] = await lua(`local m = ShowData().Masters.Speed[${MASTER}] return m:GetFader({}), m:Get("SpeedScale", Enums.Roles.Display)`);
  return { fader: f, scale, bpm: 225 * Math.pow(f / 100, Math.log2(3.75)) };
}
async function cueNow() {
  const [c] = await lua(`local s = DataPool().Sequences[${SEQ}] local c = s and s.CurrentCue return c and c.no or -1`);
  return c;
}

function startPeer(args) {
  const p = spawn(peerBin, [...args, "--interval-ms", "0"], { stdio: ["pipe", "pipe", "inherit"] });
  p.events = [];
  let buf = "";
  p.stdout.setEncoding("utf8");
  p.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) { p.events.push(JSON.parse(buf.slice(0, i))); buf = buf.slice(i + 1); }
  });
  p.send = (line) => p.stdin.write(line + "\n");
  return p;
}
async function quitPeer(p) {
  if (!p || p.exitCode !== null) return;
  p.send("quit");
  for (let i = 0; i < 20 && p.exitCode === null; i++) await sleep(100);
  if (p.exitCode === null) p.kill("SIGKILL");
}

// Runs the observer for `frames` frames; returns each cue change with its offset from the nearest session beat
// and its position in the bar (quantum 4).
async function observe(frames) {
  const code = `local P = (function(...)\n${protocol}\nend)()\nlocal SEQ, FRAMES = ${SEQ}, ${frames}\n${observer}`;
  const [w] = await lua(code);
  if (w.error) throw new Error("observer: " + w.error);
  const [mpb, bo, to] = w.timeline.split(",").map(Number);
  const changes = (w.changes ? w.changes.split(",") : []).map((c) => {
    const [t, cue] = c.split(":").map(Number);
    const beat = bo + ((t + w.intercept - to) / mpb) * 1e6;
    let frac = (beat % 1e6) / 1e6;
    if (frac >= 0.5) frac -= 1;
    return { t, cue, beat: Math.round(beat / 1e6), offsetMs: (frac * mpb) / 1000, barPos: ((Math.round(beat / 1e6) % 4) + 4) % 4 };
  });
  const ss = w.start_stop ? w.start_stop.split(",").map(Number) : null;
  return { changes, mpb, first: w.first, last: w.last,
    startStop: ss && { playing: ss[0] === 1, beats: ss[1] / 1e6, timestamp: ss[2] } };
}
const mean = (a) => a.reduce((x, y) => x + y, 0) / (a.length || 1);
const sd = (a) => { const m = mean(a); return Math.sqrt(mean(a.map((x) => (x - m) ** 2))); };

const savedMaster = await masterState();
let peers = [];
try {
  await clearConfig();
  if ((await status()).State && (await status()).State !== "stopped") await stopPlugin().catch(() => {});

  if (opts.external && scenario === "leave") throw new Error("leave needs its own test peers; it has no --external form");

  if (scenario === "timing") {
    if (!opts.external) {
      const A = startPeer(["--tempo", "128", "--play"]);
      peers.push(A);
      await sleep(1500);
    }
    // an external session may be stopped: run the beat actions anyway (StartStop off)
    await setConfig({ Master: MASTER, OnBeat: `Go+ Sequence ${SEQ}`, LeadMs: opts["lead-ms"],
      StartStop: opts.external ? "off" : "on" });
    await startPlugin();
    await sleep(1500);
    const st = await status();
    check(st.State === "following", "the plugin follows the peer", st.State);
    const m = await masterState();
    if (opts.external) {
      // the session's tempo from the observer's own decoding of the announcements, not from the plugin under test
      const w0 = await observe(10);
      const t = checkExternalTempo({ observerMpb: w0.mpb, masterBpm: m.bpm, reportedTempo: st.Tempo });
      results.sessionBpm = t.expected;
      check(t.masterOk, "the speed master has the session tempo (decoded independently)", { master: +m.bpm.toFixed(4), session: t.expected });
      check(t.reportOk, "the plugin reports the session tempo (decoded independently)", { reported: st.Tempo, session: t.expected });
    } else {
      results.sessionBpm = 128;
      check(Math.abs(m.bpm - 128) < 0.01, "the speed master has the session tempo", { master: +m.bpm.toFixed(4), session: 128 });
    }
    const windows = [];
    const start = Date.now();
    for (let k = 0; ; k++) {
      const due = start + k * 30000;
      if (due > start + opts.minutes * 60000 + 1000) break;
      while (Date.now() < due) await sleep(200);
      const w = await observe(220);
      const offs = w.changes.map((c) => c.offsetMs);
      windows.push({ atS: Math.round((Date.now() - start) / 1000), changes: offs.length, meanMs: +mean(offs).toFixed(2), sdMs: +sd(offs).toFixed(2) });
      console.error(JSON.stringify(windows.at(-1)));
    }
    const all = windows.filter((w) => w.changes > 0);
    const xs = all.map((w) => w.atS), ys = all.map((w) => w.meanMs);
    const mx = mean(xs), my = mean(ys);
    const slope = xs.reduce((a, x, i) => a + (x - mx) * (ys[i] - my), 0) / xs.reduce((a, x) => a + (x - mx) ** 2, 0);
    results.windows = windows;
    results.lagMs = +my.toFixed(2);
    results.driftMsPerMin = +(slope * 60).toFixed(2);
    check(all.every((w) => w.changes >= 6), "a Go on every beat in every window (7 or 8 per 3.7 s)");
    // Drift is judged on runs of 5 minutes or more: with windows 30 s apart and about 10 ms of spread within a
    // window, a shorter run cannot tell 1.5 ms/min from noise (it is reported anyway).
    if (opts.minutes >= 5) check(Math.abs(results.driftMsPerMin) < 1.5, "no drift of the beat actions (< 1.5 ms/min over 5 min)", results.driftMsPerMin);
    const st2 = await status();
    results.status = st2;
    check(st2.MissedBeats === "0", "no missed beats", st2.MissedBeats);
  }

  if (scenario === "beattime" && !opts.external) {
    // BEATTIME-1: no session
    const before = await masterState();
    const cue0 = await cueNow();
    await setConfig({ Master: MASTER, OnBeat: `Go+ Sequence ${SEQ}` });
    await startPlugin();
    await sleep(3000);
    const st = await status();
    check(st.State === "no session", "BEATTIME-1: no session", st.State);
    const during = await masterState();
    check(during.fader === before.fader && during.scale === before.scale, "BEATTIME-1: starting without a session leaves the speed master", during);
    check((await cueNow()) === cue0, "BEATTIME-1: and runs no beat action");
    await stopPlugin();
    const after = await masterState();
    check(after.fader === before.fader, "BEATTIME-1: stopping leaves the speed master", after);

    // BEATTIME-2: a second peer joins the session the plugin follows
    const A = startPeer(["--tempo", "120", "--play"]);
    peers.push(A);
    await sleep(1500);
    await startPlugin();
    await sleep(2000);
    const w1 = await observe(180);
    const s1 = await status();
    const B = startPeer(["--tempo", "90"]);
    peers.push(B);
    await sleep(1500);
    const w2 = await observe(180);
    const s2 = await status();
    check(s2.Peers === "2", "BEATTIME-2: the second peer is seen", s2.Peers);
    check(Math.abs(parseFloat(s2.Tempo) - 120) < 0.001, "BEATTIME-2: the session keeps its tempo (120)", s2.Tempo);
    const m1 = mean(w1.changes.map((c) => c.offsetMs)), m2 = mean(w2.changes.map((c) => c.offsetMs));
    results.beattime2 = { before: { changes: w1.changes.length, meanMs: +m1.toFixed(2) }, after: { changes: w2.changes.length, meanMs: +m2.toFixed(2) } };
    check(w1.changes.length >= 5 && w2.changes.length >= 5, "BEATTIME-2: beat actions before and after the join");
    check(Math.abs(m2 - m1) < 6, "BEATTIME-2: no jump in the beat actions' lag when the peer joins (< 6 ms)", +(m2 - m1).toFixed(2));
    check((s2.counters?.timeline_changes ?? 0) === (s1.counters?.timeline_changes ?? 0), "BEATTIME-2: the join does not change the session timeline");
    check(s2.MissedBeats === s1.MissedBeats, "BEATTIME-2: no beats missed across the join");
  }

  if (scenario === "beattime" && opts.external) {
    // BEATTIME-2 against an external session: a test peer joins the session the plugin follows
    await setConfig({ Master: MASTER, OnBeat: `Go+ Sequence ${SEQ}`, StartStop: "off" });
    await startPlugin();
    await sleep(2500);
    const s0 = await status();
    check(s0.State === "following", "following the external session", s0.State);
    const w1 = await observe(180);
    const s1 = await status();
    const B = startPeer(["--tempo", "90"]);
    peers.push(B);
    await sleep(2000);
    const w2 = await observe(180);
    const s2 = await status();
    check(Number(s2.Peers) === Number(s1.Peers) + 1, "BEATTIME-2: the joining peer is seen", { before: s1.Peers, after: s2.Peers });
    check(s2.Tempo === s1.Tempo, "BEATTIME-2: the session keeps its tempo", { before: s1.Tempo, after: s2.Tempo });
    const m1 = mean(w1.changes.map((c) => c.offsetMs)), m2 = mean(w2.changes.map((c) => c.offsetMs));
    results.beattime2 = { tempo: s2.Tempo, before: { changes: w1.changes.length, meanMs: +m1.toFixed(2) }, after: { changes: w2.changes.length, meanMs: +m2.toFixed(2) } };
    check(w1.changes.length >= 5 && w2.changes.length >= 5, "BEATTIME-2: beat actions before and after the join");
    check(Math.abs(m2 - m1) < 6, "BEATTIME-2: no jump in the beat actions' lag when the peer joins (< 6 ms)", +(m2 - m1).toFixed(2));
    check((s2.counters?.timeline_changes ?? 0) === (s1.counters?.timeline_changes ?? 0), "BEATTIME-2: the join does not change the session timeline");
    check(s2.MissedBeats === s1.MissedBeats, "BEATTIME-2: no beats missed across the join");
    // the joining test peer adopts the session's tempo, as Link peers do (TEMPO-2 from the other side)
    const bTempo = B.events.filter((e) => e.ev === "tempo").at(-1);
    results.beattime2.joiningPeerTempo = bTempo ? bTempo.bpm : null;
  }

  if (scenario === "startstop" && opts.external) {
    // STARTSTOPSTATE-1 against an external session: an operator presses Play, then Stop, in the app
    await setConfig({ OnBeat: `Go+ Sequence ${SEQ}`, StartStop: "on" });
    await lua(`Cmd("Goto Sequence ${SEQ} Cue 4") coroutine.yield() Cmd("Off Sequence ${SEQ}") return 1`);
    await startPlugin();
    await sleep(2500);
    const s0 = await status();
    check(s0.State === "following", "following the external session", s0.State);
    check(s0.Playing === "no", "the session is stopped at the start (press Play only when asked)", s0.Playing);
    console.error("READY: press Play in the app now");
    const deadline = Date.now() + opts["wait-s"] * 1000;
    const windows = [];
    let phase = "waiting for play"; // only paces the operator's prompts; the judgement is judgeStartStop's
    while (Date.now() < deadline && phase !== "done") {
      const w = await observe(180);
      const st = await status();
      windows.push({ at: new Date().toISOString(), changes: w.changes, playing: st.Playing, startStop: w.startStop });
      console.error(JSON.stringify({ at: windows.at(-1).at, changes: w.changes.length, playing: st.Playing, first: w.changes[0] }));
      if (phase === "waiting for play" && (w.changes.length > 0 || st.Playing === "yes")) {
        phase = "playing";
        console.error("PLAYING: press Stop in the app after a few bars");
      } else if (phase === "playing" && w.startStop && !w.startStop.playing) {
        phase = "after stop"; // the session's own stop, decoded by the observer, not the plugin's status
      } else if (phase === "after stop") {
        phase = "done";
      }
    }
    results.windows = windows.map((w) => ({ at: w.at, changes: w.changes.length, playing: w.playing, first: w.changes[0], startStop: w.startStop }));
    // The session plays from its start beat (link/StartStopState.hpp beats); the first beat action is the first whole
    // beat at or after it. That is a bar when the app started quantized; a relay may stamp another beat.
    const j = judgeStartStop(windows);
    check(j.started, "STARTSTOPSTATE-1: the session's start was seen");
    check(j.firstOk, "STARTSTOPSTATE-1: the first beat action is cue 1 on the first whole beat of the session's start",
      { firstChange: j.firstChange, startBeat: j.startState && j.startState.beats, expected: j.expectedFirstBeat });
    check(j.stopped, "STARTSTOPSTATE-1: the session's own stop was seen (decoded independently)", { stopEvidence: j.stopEvidence, stopState: j.stopState });
    check(j.pluginStoppedOk, "STARTSTOPSTATE-1: the plugin reports the stop");
    check(j.noneAfterStop, "STARTSTOPSTATE-1: no beat actions after the stop", j.afterStop && { changes: j.afterStop.changes.length });
    results.startBeat = j.startState ? j.startState.beats : null;
    results.startOnBar = results.startBeat !== null && Math.abs(results.startBeat / 4 - Math.round(results.startBeat / 4)) < 1e-6;
    results.startstop = { firstChange: j.firstChange };
  }

  if (scenario === "startstop" && !opts.external) {
    const A = startPeer(["--tempo", "120"]); // stopped
    peers.push(A);
    await sleep(1500);
    await setConfig({ OnBeat: `Go+ Sequence ${SEQ}`, StartStop: "on" });
    await startPlugin();
    await sleep(2000);
    const w0 = await observe(90);
    check(w0.changes.length === 0, "STARTSTOPSTATE-1: no beat actions while the session is stopped", w0.changes.length);
    // Park the chase on its last cue, off: CurrentCue keeps the last cue after Off, so the first Go (to cue 1) is a
    // visible change.
    await lua(`Cmd("Goto Sequence ${SEQ} Cue 4") coroutine.yield() Cmd("Off Sequence ${SEQ}") return 1`);
    const run = observe(240);
    await sleep(600);
    A.send("play"); // the peer starts (alone in its session, at once, on a new bar)
    const w1 = await run;
    check(w1.changes.length >= 4, "STARTSTOPSTATE-1: beat actions after the peer plays", w1.changes.length);
    const firstChange = w1.changes[0];
    check(firstChange && firstChange.cue === 1000 && firstChange.barPos === 0,
      "STARTSTOPSTATE-1: the first beat action is on the start bar (cue 1 on a bar)", firstChange);
    const st = await status();
    check(st.Playing === "yes", "STARTSTOPSTATE-1: status Playing yes", st.Playing);
    const run2 = observe(180);
    await sleep(600);
    A.send("stop");
    const w2 = await run2;
    const stopEv = A.events.find((e) => e.ev === "startstop" && e.playing === false);
    const late = stopEv ? w2.changes.filter((c) => c.t > stopEv.wall_us + 50000) : [];
    check(stopEv && late.length === 0, "STARTSTOPSTATE-1: no beat actions after the peer stops", late.length);
    const stStop = await status();
    check(stStop.Playing === "no", "STARTSTOPSTATE-1: status Playing no", stStop);
    results.startstop = { firstChange, changesAfterPlay: w1.changes.length, changesAfterStop: late.length };
  }

  if (scenario === "leave") {
    await setConfig({ Master: MASTER });
    const A = startPeer(["--tempo", "120", "--play"]);
    peers.push(A);
    await sleep(1500);
    await startPlugin();
    await sleep(1500);
    check((await status()).State === "following", "following the peer");
    const t0 = Date.now();
    await quitPeer(A); // ByeBye
    let st;
    for (let i = 0; i < 40; i++) { st = await status(); if (st.State === "no session") break; await sleep(100); }
    results.byebyeMs = Date.now() - t0;
    check(st.State === "no session" && results.byebyeMs < 1500, "a peer that quits is gone at once (ByeBye)", results.byebyeMs);
    const B = startPeer(["--tempo", "140", "--play"]);
    peers.push(B);
    for (let i = 0; i < 40; i++) { st = await status(); if (st.State === "following") break; await sleep(250); }
    check(st.State === "following" && Math.abs(parseFloat(st.Tempo) - 140) < 0.001, "rejoined, with the new session's tempo", st.Tempo);
    await sleep(1000);
    const m = await masterState();
    check(Math.abs(m.bpm - 140) < 0.01, "the speed master is rewritten after rejoining", +m.bpm.toFixed(4));
    const t1 = Date.now();
    B.kill("SIGKILL"); // vanishes without a ByeBye
    for (let i = 0; i < 80; i++) { st = await status(); if (st.State === "no session") break; await sleep(250); }
    results.ttlMs = Date.now() - t1;
    check(st.State === "no session" && results.ttlMs > 4000 && results.ttlMs < 7000, "a vanished peer is dropped after its 5 s ttl", results.ttlMs);
  }
} catch (e) {
  check(false, "error", e.message);
} finally {
  for (const p of peers) await quitPeer(p);
  await stopPlugin().catch(() => {});
  await lua(`Cmd("Off Sequence ${SEQ}") return 1`).catch(() => {});
  await lua(`local m = ShowData().Masters.Speed[${MASTER}] m:Set("SpeedScale", "${savedMaster.scale}") m:SetFader({ value = ${savedMaster.fader} }) return 1`).catch(() => {});
  await clearConfig().catch(() => {});
  await sleep(300);
  const m = await masterState().catch(() => null);
  results.masterRestored = m && Math.abs(m.fader - savedMaster.fader) < 1e-4 && m.scale === savedMaster.scale;
}
console.log(JSON.stringify(results, null, 2));
process.exit(results.ok ? 0 : 1);
