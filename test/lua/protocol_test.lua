-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Harness for plugin/beat_sync_protocol.lua under stock Lua 5.5 (the console's version):
--   1. timeline arithmetic against Link's own results (test/fixtures/vectors.txt, from gbs-vectors);
--   2. message parsing against Link's own parser, packet by packet (test/fixtures/*.txt "packet"/"expect" pairs,
--      captured from test peers or hand-made, labelled by gbs-capture);
--   3. ping encoding, byte for byte against the pings Link's code encoded in the captures;
--   4. measurement data points from the captured ping/pong exchanges;
--   5. robustness: mutated packets never raise.
-- Usage: lua test/lua/protocol_test.lua

local root = (arg and arg[0] or ""):match("^(.*)test/lua/[^/]*$") or "./"
local P = dofile(root .. "plugin/beat_sync_protocol.lua")

local failures, checks = 0, 0
local function check(ok, what)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    if failures <= 25 then io.stderr:write("FAIL: ", what, "\n") end
  end
  return ok
end

local function lines(path)
  local f = assert(io.open(path, "r"))
  local t = {}
  for l in f:lines() do t[#t + 1] = l end
  f:close()
  return t
end

local function int(tok) return math.tointeger(tonumber(tok)) end
local function num(tok) return tonumber(tok) end

------------------------------------------------------------------------------------------------------------------
-- 1. Arithmetic vectors

local function tl(mpb, bo, to) return { micros_per_beat = int(mpb), beat_origin = int(bo), time_origin = int(to) } end

local vector_cases = {
  tempo = function(a, r)
    return P.bpm(int(a[1])) == num(r[1]) and P.effective_micros_per_beat(tl(a[1], 0, 0)) == int(r[2])
  end,
  bpm = function(a, r)
    return P.micros_per_beat(num(a[1])) == int(r[1]) and P.clamp_bpm(num(a[1])) == num(r[2])
  end,
  toBeats = function(a, r) return P.to_beats(tl(a[1], a[2], a[3]), int(a[4])) == int(r[1]) end,
  fromBeats = function(a, r) return P.from_beats(tl(a[1], a[2], a[3]), int(a[4])) == int(r[1]) end,
  toPhaseEncodedBeats = function(a, r)
    return P.to_phase_encoded_beats(tl(a[1], a[2], a[3]), int(a[4]), int(a[5])) == int(r[1])
  end,
  fromPhaseEncodedBeats = function(a, r)
    return P.from_phase_encoded_beats(tl(a[1], a[2], a[3]), int(a[4]), int(a[5])) == int(r[1])
  end,
  phase = function(a, r) return P.phase(int(a[1]), int(a[2])) == int(r[1]) end,
  nextPhaseMatch = function(a, r) return P.next_phase_match(int(a[1]), int(a[2]), int(a[3])) == int(r[1]) end,
  closestPhaseMatch = function(a, r)
    return P.closest_phase_match(int(a[1]), int(a[2]), int(a[3])) == int(r[1])
  end,
  hostToGhost = function(a, r)
    return P.host_to_ghost({ slope = num(a[1]), intercept = int(a[2]) }, int(a[3])) == int(r[1])
  end,
  ghostToHost = function(a, r)
    return P.ghost_to_host({ slope = num(a[1]), intercept = int(a[2]) }, int(a[3])) == int(r[1])
  end,
  median = function(a, r)
    local v = {}
    for i, x in ipairs(a) do v[i] = num(x) end
    return P.median(v) == num(r[1])
  end,
  updateClientTimelineFromSession = function(a, r)
    local out = P.update_client_timeline(tl(a[1], a[2], a[3]), tl(a[4], a[5], a[6]), int(a[7]),
      { slope = 1.0, intercept = int(a[8]) })
    return out.micros_per_beat == int(r[1]) and out.beat_origin == int(r[2]) and out.time_origin == int(r[3])
  end,
}

local seen = {}
for _, l in ipairs(lines(root .. "test/fixtures/vectors.txt")) do
  if not l:match("^#") and l:match("%S") then
    local lhs, rhs = l:match("^(.-) = (.*)$")
    local a, r = {}, {}
    for t in lhs:gmatch("%S+") do a[#a + 1] = t end
    for t in rhs:gmatch("%S+") do r[#r + 1] = t end
    local fn = table.remove(a, 1)
    local case = vector_cases[fn]
    if check(case ~= nil, "unknown vector function " .. tostring(fn)) then
      seen[fn] = (seen[fn] or 0) + 1
      local ok, res = pcall(case, a, r)
      check(ok and res, "vector: " .. l .. (ok and "" or (" (error: " .. tostring(res) .. ")")))
    end
  end
end
for fn in pairs(vector_cases) do check(seen[fn], "no vectors for " .. fn) end

------------------------------------------------------------------------------------------------------------------
-- 2. Parsing against Link's parser: rebuild gbs-capture's "expect" description from the Lua decode.

-- inet_ntop-style IPv6 text (RFC 5952: longest run of two or more zero groups becomes "::")
local function format_v6(b)
  local g = {}
  for i = 1, 16, 2 do g[#g + 1] = string.unpack(">I2", b, i) end
  local best, bestlen, i = nil, 1, 1
  while i <= 8 do
    if g[i] == 0 then
      local j = i
      while j <= 8 and g[j] == 0 do j = j + 1 end
      if j - i > bestlen then best, bestlen = i, j - i end
      i = j
    else
      i = i + 1
    end
  end
  local parts = {}
  for k = 1, 8 do parts[k] = string.format("%x", g[k]) end
  if not best then return table.concat(parts, ":") end
  return table.concat(parts, ":", 1, best - 1) .. "::" .. table.concat(parts, ":", best + bestlen, 8)
end

local function ep(e)
  if not e then return "absent" end
  if e.v6 then return "[" .. format_v6(e.address) .. "]:" .. e.port end
  return e.address .. ":" .. e.port
end

local function describe_discovery(data)
  local m, reason, partial = P.decode_discovery(data)
  local h = m or partial
  if not h then return "type=0 rejected=header" end
  local s = string.format("type=%d ttl=%d group=%d node=%s", h.type, h.ttl, h.group, P.hex(h.node_id))
  if reason == "group" then return s .. " ignored=group" end
  if reason then return s .. " rejected=" .. reason end
  if h.type == P.BYEBYE then return s end
  local t = m.timeline
  s = s .. " tmln=" .. (t and string.format("%d,%d,%d", P.effective_micros_per_beat(t), t.beat_origin,
    t.time_origin) or "absent")
  s = s .. " sess=" .. (m.session_id and P.hex(m.session_id) or "absent")
  local ss = m.start_stop
  s = s .. " stst=" .. (ss and string.format("%d,%d,%d", ss.playing and 1 or 0, ss.beats, ss.timestamp) or "absent")
  return s .. " mep4=" .. ep(m.mep4) .. " mep6=" .. ep(m.mep6) .. " aep4=" .. ep(m.aep4) .. " aep6=" .. ep(m.aep6)
end

local function describe_measurement(data)
  local m, reason, partial = P.decode_measurement(data)
  local h = m or partial
  if not h then return "type=0 rejected=header" end
  if reason then return "type=" .. h.type .. " rejected=" .. reason end
  if m.type == P.PING then
    return string.format("type=1 payload=%d answered=%d", m.payload_size, m.answered and 1 or 0)
  end
  local function opt(v) return v and tostring(v) or "absent" end
  return string.format("type=2 sess=%s ghost=%s prev_ghost=%s host=%s",
    m.session_id and P.hex(m.session_id) or "absent", opt(m.ghost), opt(m.prev_ghost), opt(m.host))
end

local fixture_files = {}
do
  local p = io.popen('ls "' .. root .. 'test/fixtures/"*.txt')
  for f in p:lines() do
    if not f:match("vectors%.txt$") then fixture_files[#fixture_files + 1] = f end
  end
  p:close()
end
check(#fixture_files >= 4, "expected at least 4 packet fixture files, found " .. #fixture_files)

local packets = {} -- { file, kind, data, expect, note }
for _, f in ipairs(fixture_files) do
  local note
  local ls = lines(f)
  for i, l in ipairs(ls) do
    if l:match("^# ") then note = l:sub(3) end
    local kind, h = l:match("^packet (%S+) (%x*)$")
    if kind then
      local exp = ls[i + 1] and ls[i + 1]:match("^expect (.*)$")
      check(exp, f .. ":" .. i .. ": packet without an expect line")
      packets[#packets + 1] = { file = f, line = i, kind = kind, data = P.unhex(h), expect = exp, note = note }
    end
  end
end

local by_kind = {}
for _, pk in ipairs(packets) do
  by_kind[pk.kind] = (by_kind[pk.kind] or 0) + 1
  local got = pk.kind == "discovery" and describe_discovery(pk.data) or describe_measurement(pk.data)
  check(got == pk.expect, string.format("%s:%d (%s)\n  link: %s\n  lua:  %s", pk.file, pk.line, pk.note or "",
    pk.expect, got))
end
check((by_kind.discovery or 0) >= 50 and (by_kind.ping or 0) >= 8 and (by_kind.pong or 0) >= 8,
  "too few fixture packets of some kind")

------------------------------------------------------------------------------------------------------------------
-- 3. Ping encoding, byte for byte against Link's encoder (the pings gbs-capture sent were encoded by Link's code)

local pings = 0
for _, pk in ipairs(packets) do
  if pk.kind == "ping" and pk.file:match("peer%-") then
    local d = pk.data
    local host = string.unpack(">i8", d, 18)
    local prev = #d >= 41 and string.unpack(">i8", d, 34) or nil
    check(P.encode_ping(host, prev) == d, "encode_ping differs from Link's ping at " .. pk.file .. ":" .. pk.line)
    pings = pings + 1
  end
end
check(pings >= 8, "too few captured pings: " .. pings)

------------------------------------------------------------------------------------------------------------------
-- 4. Measurement data points from the captured exchanges. A pong's points estimate ghost minus host time; within
-- one exchange they agree to within the round trip, which the capture's comment line records.

local exchanges = 0
for i, pk in ipairs(packets) do
  if pk.kind == "pong" and pk.file:match("peer%-") then
    local rtt, recv = pk.note:match("round trip (%d+) us, received at host (%d+)")
    local pong = P.decode_measurement(pk.data)
    if check(pong and rtt, "pong without a decode or a note at " .. pk.file .. ":" .. pk.line) then
      local points = P.measurement_points(pong, int(recv))
      check(#points == (pong.prev_ghost and 2 or 1), "point count at " .. pk.file .. ":" .. pk.line)
      for _, p in ipairs(points) do
        check(math.abs(p - points[1]) <= int(rtt) + 1, "points disagree beyond the round trip at "
          .. pk.file .. ":" .. pk.line)
      end
      -- the pong echoes the ping that preceded it
      local ping = packets[i - 1]
      check(ping.kind == "ping" and pong.host == string.unpack(">i8", ping.data, 18), "pong does not echo its ping")
      exchanges = exchanges + 1
    end
  end
end
check(exchanges >= 8, "too few captured exchanges: " .. exchanges)
check(#P.measurement_points({ ghost = 0, host = 5 }, 10) == 0, "a zero ghost time is absent, as in Link")
check(#P.measurement_points({ ghost = 5 }, 10) == 0, "a pong without a host time gives no points")
check(#P.measurement_points({ ghost = 5, host = 0, prev_ghost = 3 }, 10) == 0, "a zero host time is absent")
check(P.median({ 1, 2 }) == nil, "median needs more than 2 values")
local x = P.ghost_xform({ 10.4, 3, 7.6, 1000, -1000 })
check(x.slope == 1.0 and x.intercept == 8, "ghost_xform rounds the median")

------------------------------------------------------------------------------------------------------------------
-- 5. Robustness: truncations and byte flips of every fixture packet never raise.

math.randomseed(20261015)
local mutations = 0
for _, pk in ipairs(packets) do
  local d = pk.data
  for cut = 0, #d do
    local s = d:sub(1, cut)
    check(pcall(P.decode_discovery, s) and pcall(P.decode_measurement, s), "truncation raised")
    mutations = mutations + 1
  end
  for _ = 1, 20 do
    if #d > 0 then
      local pos = math.random(1, #d)
      local s = d:sub(1, pos - 1) .. string.char(math.random(0, 255)) .. d:sub(pos + 1)
      check(pcall(P.decode_discovery, s) and pcall(P.decode_measurement, s), "byte flip raised")
      mutations = mutations + 1
    end
  end
end
check(P.decode_discovery(nil) == nil and P.decode_measurement(42) == nil, "non-string input")

print(string.format("protocol_test: %d checks, %d failures (%d packets, %d pings, %d exchanges, %d mutations)",
  checks, failures, #packets, pings, exchanges, mutations))
if failures > 0 then os.exit(1) end
