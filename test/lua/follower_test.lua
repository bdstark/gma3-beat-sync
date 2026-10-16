-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Harness for plugin/beat_sync_follower.lua under stock Lua 5.5: simulated peers (Alive, ByeBye and pong packets
-- encoded here in the layouts of the Link source, see plugin/beat_sync_protocol.lua) on a simulated clock.
-- Usage: lua test/lua/follower_test.lua

local root = (arg and arg[0] or ""):match("^(.*)test/lua/[^/]*$") or "./"
local P = dofile(root .. "plugin/beat_sync_protocol.lua")
local F = dofile(root .. "plugin/beat_sync_follower.lua")

local failures, checks = 0, 0
local function check(ok, what)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    io.stderr:write("FAIL: ", what, "\n")
  end
  return ok
end

local pack = string.pack
local function entry(key, value) return key .. pack(">I4", #value) .. value end

-- A simulated peer: its ghost clock is host + offset; its session timeline is in ghost time.
local function peer(node, opts)
  return {
    node = node, session = opts.session or node, offset = opts.offset or 0, ttl = opts.ttl or 5,
    mpb = opts.mpb or 500000, beat_origin = opts.beat_origin or 0, time_origin = opts.time_origin or 0,
    playing = opts.playing or false, ss_beats = 0, ss_time = opts.ss_time or 1,
    address = opts.address or "127.0.0.1", port = opts.port or 50000,
  }
end

local function alive(p, mtype)
  local a, b, c, d = p.address:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
  return "_asdp_v\1" .. pack(">I1I1I2", mtype or 1, p.ttl, 0) .. p.node
    .. entry("tmln", pack(">i8i8i8", p.mpb, p.beat_origin, p.time_origin))
    .. entry("sess", p.session)
    .. entry("stst", pack(">I1i8i8", p.playing and 1 or 0, p.ss_beats, p.ss_time))
    .. entry("mep4", pack(">I1I1I1I1I2", tonumber(a), tonumber(b), tonumber(c), tonumber(d), p.port))
end

local function byebye(p) return "_asdp_v\1" .. pack(">I1I1I2", 3, 0, 0) .. p.node end

-- The pong a peer sends for a ping: link/PingResponder.hpp (session, ghost time now, then the ping's payload).
local function pong_for(p, ping, at_host)
  return "_link_v\1\2" .. entry("sess", p.session) .. entry("__gt", pack(">i8", at_host + p.offset)) .. ping:sub(10)
end

-- Runs measurement exchanges with a 100 us round trip until the follower stops pinging.
local function measure(f, peers_by_port, t)
  for _ = 1, 200 do
    local ping = f:next_ping(t)
    if not ping then return t end
    local p = peers_by_port[ping.port]
    f:pong(pong_for(p, ping.data, t + 50), t + 100)
    t = t + 150
  end
  return t
end

------------------------------------------------------------------------------------------------------------------
-- One peer at 120 bpm, playing

do
  local A = peer("AAAAAAAA", { offset = 7000000, playing = true, port = 50001 })
  local f = F.new(P, { quantum = 4 })
  local t = 1000000
  f:discovery(alive(A), t)
  check(f:status(t).state == "measuring", "measuring after the first Alive")
  t = measure(f, { [50001] = A }, t)
  local s = f.sessions[A.session]
  check(s.xform and math.abs(s.xform.intercept - A.offset) <= 1, "intercept is the peer's offset: "
    .. tostring(s and s.xform and s.xform.intercept))
  check(f.current == A.session, "follows the measured session")

  local ev = f:frame(t, 16667)
  local kinds = {}
  for _, e in ipairs(ev) do kinds[e.kind] = (kinds[e.kind] or 0) + 1 end
  check(kinds.joined == 1 and kinds.tempo == 1 and kinds.start == 1, "joined, tempo and start on the first frame")

  -- Frames for 4 s: every beat once, on the frame nearest it, bars every 4 beats.
  local beats, bars, worst = 0, 0, 0
  local seen = {}
  for _ = 1, 240 do
    t = t + 16667
    for _, e in ipairs(f:frame(t, 16667)) do
      if e.kind == "beat" then
        check(not seen[e.beat], "beat reported twice")
        seen[e.beat] = true
        beats = beats + 1
        if e.bar then bars = bars + 1 end
        worst = math.max(worst, math.abs(e.at_us - t))
        -- at_us is the beat's host time: ghost = host + offset, beat = (ghost - time_origin) / mpb
        check((e.at_us + A.offset) % 500000 == 0, "beat time on the peer's grid")
        check(e.bar == ((e.at_us + A.offset) % 2000000 == 0), "bar flag on quantum boundaries")
      end
    end
  end
  check(beats == 8, "8 beats in 4 s at 120 bpm, got " .. beats)
  check(bars == 2, "2 bars in 4 s, got " .. bars)
  check(worst <= 16667 // 2, "each beat on the frame nearest it (worst " .. worst .. " us)")

  -- Stop, then the peer leaves.
  A.playing, A.ss_time = false, 2
  f:discovery(alive(A), t)
  local ev2 = f:frame(t + 16667, 16667)
  check(#ev2 >= 1 and ev2[1].kind == "stop", "stop event")
  f:discovery(byebye(A), t + 20000)
  local ev3 = f:frame(t + 33334, 16667)
  check(ev3[1] and ev3[1].kind == "left", "left after ByeBye")
  check(f:status(t + 33334).state == "no session", "no session after the last peer left")
end

------------------------------------------------------------------------------------------------------------------
-- Peers time out after their ttl

do
  local A = peer("AAAAAAAA", { offset = 0, port = 50001 })
  local f = F.new(P)
  f:discovery(alive(A), 0)
  measure(f, { [50001] = A }, 0)
  f:frame(100000, 16667)
  check(f:status(4900000).peers == 1, "peer alive before its ttl")
  local ev = f:frame(5200000, 16667)
  check(ev[1] and ev[1].kind == "left" and f:status(5200000).peers == 0, "peer dropped after its 5 s ttl")
end

------------------------------------------------------------------------------------------------------------------
-- Pongs must match the ping in flight

do
  local A = peer("AAAAAAAA", { offset = 1000, port = 50001 })
  local f = F.new(P)
  f:discovery(alive(A), 0)
  local ping = f:next_ping(10)
  f:pong(pong_for(A, P.encode_ping(5), 20), 30) -- a late pong of an earlier ping
  check(f.counters.unpaired_pongs == 1 and #f.measuring.points == 0, "an unpaired pong is ignored")
  local other = peer("BBBBBBBB", { port = 50002 })
  f:pong(pong_for(other, ping.data, 20), 30) -- right echo, other session
  check(f.counters.unpaired_pongs == 2, "a pong of another session is ignored")
  f:pong(pong_for(A, ping.data, 20), 30)
  check(#f.measuring.points == 1, "the paired pong counts")
end

------------------------------------------------------------------------------------------------------------------
-- Timeouts fail a measurement after 5 tries

do
  local A = peer("AAAAAAAA", { port = 50001 })
  local f = F.new(P)
  f:discovery(alive(A), 0)
  local t, pings = 0, 0
  for _ = 1, 20 do
    if f:next_ping(t) then pings = pings + 1 end
    t = t + 60000
  end
  check(f.counters.failed == 1, "one failed measurement after 5 timeouts")
  check(pings == 5, "5 pings before failing, got " .. pings)
  check(f:status(t).state == "measuring", "no session followed after a failed measurement")
end

------------------------------------------------------------------------------------------------------------------
-- Two sessions: link/Sessions.hpp prefers a session whose ghost time is ahead by more than 500 ms

do
  local A = peer("AAAAAAAA", { offset = 1000000, port = 50001 })
  local B = peer("BBBBBBBB", { offset = 9000000, port = 50002 })
  local f = F.new(P)
  f:discovery(alive(A), 0)
  local t = measure(f, { [50001] = A, [50002] = B }, 0)
  check(f.current == A.session, "first measured session followed")
  f:discovery(alive(B), t)
  t = measure(f, { [50001] = A, [50002] = B }, t)
  check(f.current == B.session, "switched to the session 8 s ahead")
  local ev = f:frame(t, 16667)
  check(ev[1] and ev[1].kind == "joined" and ev[1].session_id == B.session, "joined event for the new session")

  -- Within 500 ms, the smaller session id wins.
  local C = peer("CCCCCCCC", { offset = 1100000, port = 50003 })
  local D = peer("DDDDDDDD", { offset = 1000000, port = 50004 })
  local g = F.new(P)
  g:discovery(alive(D), 0)
  local u = measure(g, { [50003] = C, [50004] = D }, 0)
  g:discovery(alive(C), u)
  measure(g, { [50003] = C, [50004] = D }, u)
  check(g.current == C.session, "within 500 ms the smaller session id wins")
end

------------------------------------------------------------------------------------------------------------------
-- Within a session the timeline with the larger beat origin wins (link/Sessions.hpp, updateTimeline)

do
  local A = peer("AAAAAAAA", { port = 50001, beat_origin = 100 })
  local f = F.new(P)
  f:discovery(alive(A), 0)
  local A2 = peer("EEEEEEEE", { session = "AAAAAAAA", port = 50005, beat_origin = 50, mpb = 461538 })
  f:discovery(alive(A2), 10)
  check(f.sessions[A.session].timeline.micros_per_beat == 500000, "a smaller beat origin is not adopted")
  A2.beat_origin = 200
  f:discovery(alive(A2), 20)
  check(f.sessions[A.session].timeline.micros_per_beat == 461538, "a larger beat origin is adopted")
  check(f:measurement_peer(A.session).node_id == "AAAAAAAA", "the founder is measured")
end

------------------------------------------------------------------------------------------------------------------
-- Quantized start: a start with stst.beats on the next bar takes effect at that beat (link/StartStopState.hpp)

do
  local A = peer("AAAAAAAA", { offset = 0, port = 50001 }) -- beat b at ghost = host = b * 0.5 s
  local f = F.new(P, { quantum = 4 })
  local t = 10000000 -- beat 20
  f:discovery(alive(A), t)
  t = measure(f, { [50001] = A }, t)
  f:frame(t, 16667)
  A.playing, A.ss_beats, A.ss_time = true, 24000000, t -- requested at beat ~20, starts on the bar at beat 24
  f:discovery(alive(A), t)
  local started_at, first_beat
  for _ = 1, 200 do
    t = t + 16667
    for _, e in ipairs(f:frame(t, 16667)) do
      if e.kind == "start" then started_at = t end
      if e.kind == "beat" and not first_beat then first_beat = e end
    end
  end
  check(started_at and math.abs(started_at - 12000000) <= 8334, "start on the frame nearest beat 24 (12 s), got "
    .. tostring(started_at))
  check(first_beat and first_beat.beat == 24000000 and first_beat.bar, "the first beat is the start beat, a bar")
end

------------------------------------------------------------------------------------------------------------------
-- Lead, missed beats, quantum, drift

do
  local A = peer("AAAAAAAA", { offset = 0, playing = true, port = 50001 })
  local f = F.new(P, { quantum = 4 })
  local t = 1000000
  f:discovery(alive(A), t)
  t = measure(f, { [50001] = A }, t)
  f:frame(t, 16667)
  -- with a 20 ms lead, each beat comes on the frame nearest 20 ms before it
  local worst = 0
  for _ = 1, 120 do
    t = t + 16667
    for _, e in ipairs(f:frame(t, 16667, { lead_us = 20000 })) do
      if e.kind == "beat" then worst = math.max(worst, math.abs((e.at_us - 20000) - t)) end
    end
  end
  check(worst <= 8334, "a lead moves beats a lead earlier (worst " .. worst .. " us)")
  -- a frame 2 s late misses 3 beats by more than a frame: counted, not reported
  local before = f.counters.missed_beats or 0
  t = t + 2000000
  local late = 0
  for _, e in ipairs(f:frame(t, 16667)) do if e.kind == "beat" then late = late + 1 end end
  check((f.counters.missed_beats or 0) - before >= 3, "missed beats counted")
  check(late <= 1, "missed beats are not reported late")
  -- quantum 3: bars every 3 beats
  f:set_quantum(3)
  local bars, beats = 0, 0
  f:discovery(alive(A), t) -- the peer keeps announcing (its ttl is 5 s)
  for i = 1, 360 do
    t = t + 16667
    if i % 60 == 0 then f:discovery(alive(A), t) end
    for _, e in ipairs(f:frame(t, 16667)) do
      if e.kind == "beat" then
        beats = beats + 1
        if e.bar then bars = bars + 1; check((e.beat // 1000000) % 3 == 0, "bar on a multiple of 3") end
      end
    end
  end
  check(beats == 12 and bars == 4, "quantum 3: 12 beats, 4 bars in 6 s; got " .. beats .. ", " .. bars)
  -- drift: the peer's clock runs 60 us/min ahead; re-measured after 30 s
  local first_measured = f.sessions[A.session].measured_us
  A.offset = A.offset + 30
  for _ = 1, 30 do -- announcing every second for 30 s
    t = t + 1000000
    f:discovery(alive(A), t)
  end
  t = measure(f, { [50001] = A }, t)
  local d = f:status(t).drift_us_per_min
  local want = 30 / ((f.sessions[A.session].measured_us - first_measured) / 60e6)
  check(f.counters.measurements == 2, "re-measured after 30 s")
  check(d and math.abs(d - want) < 3, "drift from re-measurement: " .. tostring(d) .. " us/min, want " .. want)
end

------------------------------------------------------------------------------------------------------------------
-- A new timeline that moves the beat grid (a quantized start) is not counted as missed beats, and no beat is
-- reported twice

do
  local A = peer("AAAAAAAA", { offset = 0, playing = true, port = 50001 })
  local f = F.new(P)
  local t = 1000000
  f:discovery(alive(A), t)
  t = measure(f, { [50001] = A }, t)
  f:frame(t, 16667)
  local seen, dup = {}, false
  local function frames(n)
    for _ = 1, n do
      t = t + 16667
      for _, e in ipairs(f:frame(t, 16667)) do
        if e.kind == "beat" then
          for _, prev in ipairs(seen) do if math.abs(prev - e.at_us) < 8334 then dup = true end end
          seen[#seen + 1] = e.at_us
        end
      end
    end
  end
  frames(60)
  -- the peer's grid jumps 2.5 beats ahead: beat origin up, same tempo
  A.beat_origin, A.time_origin = 10000000, ((t + 10000) - 2500000 // 2) -- ghost = host here
  A.beat_origin = A.beat_origin + 1
  f:discovery(alive(A), t)
  frames(120)
  check((f.counters.missed_beats or 0) == 0, "a timeline jump is not counted as missed beats: "
    .. tostring(f.counters.missed_beats))
  check(f.counters.timeline_changes == 1, "the timeline change is counted")
  check(not dup, "no beat reported twice across the change")
  -- the beats after the change are on the new grid
  local last_at = seen[#seen]
  check(P.to_beats(f.sessions[A.session].timeline, last_at) % 1000000 <= 2, "beats on the new grid")
end

------------------------------------------------------------------------------------------------------------------
-- A peer alone in its session starts at once: its new timeline puts the start beat at the moment play was pressed,
-- before the follower hears of it. The start beat is still reported, late: after 5 ms, and after 70 ms (a delayed
-- announcement), but not after 150 ms.

do
  local A = peer("AAAAAAAA", { offset = 0, port = 50001 })
  local f = F.new(P, { quantum = 4 })
  local t = 1000000
  f:discovery(alive(A), t)
  t = measure(f, { [50001] = A }, t)
  for _ = 1, 30 do t = t + 16667 f:frame(t, 16667) end
  -- play pressed 5 ms ago: beat 12 (a bar) is at that moment on the new timeline
  local pressed = t - 5000
  A.beat_origin, A.time_origin = 12000000, pressed -- ghost = host here
  A.playing, A.ss_beats, A.ss_time = true, 12000000, pressed
  f:discovery(alive(A), t)
  local first, start
  for _ = 1, 60 do
    t = t + 16667
    for _, e in ipairs(f:frame(t, 16667)) do
      if e.kind == "start" then start = t end
      if e.kind == "beat" and not first then first = { e = e, t = t } end
    end
  end
  check(start and start - pressed <= 16667 + 5000, "start reported on the first frame after it was heard")
  check(first and first.e.beat == 12000000 and first.e.bar, "the start beat (a bar) is reported: "
    .. tostring(first and first.e.beat))
  check(first and first.t - first.e.at_us <= 16667 * 3 // 2, "late by less than a frame and a half")
end

for _, case in ipairs({ { late = 70000, reported = true }, { late = 150000, reported = false } }) do
  local A = peer("AAAAAAAA", { offset = 0, port = 50001 })
  local f = F.new(P, { quantum = 4 })
  local t = 1000000
  f:discovery(alive(A), t)
  t = measure(f, { [50001] = A }, t)
  for _ = 1, 30 do t = t + 16667 f:frame(t, 16667) end
  local pressed = t - case.late
  A.beat_origin, A.time_origin = 12000000, pressed
  A.playing, A.ss_beats, A.ss_time = true, 12000000, pressed
  f:discovery(alive(A), t)
  local beats = {}
  for _ = 1, 40 do
    t = t + 16667
    for _, e in ipairs(f:frame(t, 16667)) do if e.kind == "beat" then beats[#beats + 1] = e.beat end end
  end
  check((beats[1] == 12000000) == case.reported, string.format("start beat %s when heard %d ms late (first %s)",
    case.reported and "reported" or "skipped", case.late // 1000, tostring(beats[1])))
  check(beats[1] == 12000000 or beats[1] == 13000000, "the next beat follows")
  check((f.counters.missed_beats or 0) == 0, "not counted as missed")
end

print(string.format("follower_test: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
