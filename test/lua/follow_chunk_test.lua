-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Offline harness for test/live/follow_chunk.lua (the follower the live test runs inside the console), under stock
-- Lua 5.5 with mocked sockets and a simulated clock. Each scenario runs the chunk as a coroutine, one resume per
-- simulated frame, and checks that:
--   - every resume yields within an instruction limit (the chunk never holds the console thread);
--   - the simulated time blocked in one resume stays within the measurement's per-frame budget;
--   - the chunk ends, closes both sockets and reports the failure or the samples.
-- Usage: lua test/lua/follow_chunk_test.lua

local root = (arg and arg[0] or ""):match("^(.*)test/lua/[^/]*$") or "./"
local P = dofile(root .. "plugin/beat_sync_protocol.lua")
local f = assert(io.open(root .. "test/live/follow_chunk.lua"))
local source = f:read("a")
f:close()

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
local SESSION = "SESSION1"
local ALIVE = "_asdp_v\1" .. pack(">I1I1I2", 1, 5, 0) .. SESSION
  .. entry("tmln", pack(">i8i8i8", 500000, 0, 0)) .. entry("sess", SESSION)
  .. entry("stst", pack(">I1i8i8", 1, 0, 1)) .. entry("mep4", pack(">I1I1I1I1I2", 127, 0, 0, 1, 50000))
local GARBAGE = "not a link packet"

-- A scenario: discovery(n) returns the n-th multicast packet or nil; reply(ping, clock) returns a pong or nil.
local function run(name, discovery, reply)
  local clock = { us = 1000000 }
  local sockets = {}
  local function new_socket()
    local s = { closed = false, received = 0 }
    function s:setoption() return 1 end
    function s:setsockname() return 1 end
    function s:settimeout(t) self.timeout = t end
    function s:close() self.closed = true end
    function s:receivefrom()
      clock.us = clock.us + 5
      self.received = self.received + 1
      return discovery(self.received)
    end
    function s:sendto(data) self.last_ping = data; clock.us = clock.us + 5; return #data end
    function s:receive()
      local pong = reply(self.last_ping, clock)
      if pong then clock.us = clock.us + 100 else clock.us = clock.us + 3000 end -- a timeout blocks 3 ms
      return pong
    end
    sockets[#sockets + 1] = s
    return s
  end
  local mock = { udp4 = new_socket, gettime = function() clock.us = clock.us + 1; return clock.us / 1e6 end }
  local env = setmetatable({ P = P, QUANTUM = 4000000, require = function() return mock end }, { __index = _G })
  local chunk = assert(load(source, "=follow_chunk.lua", "t", env))
  local co = coroutine.create(chunk)
  local LIMIT = 200000 -- VM instructions per resume
  local result, resumes, worst_block_us = nil, 0, 0
  while coroutine.status(co) ~= "dead" and resumes < 2000 do
    debug.sethook(co, function() error("no yield within " .. LIMIT .. " instructions", 0) end, "", LIMIT)
    local before = clock.us
    local ok, value = coroutine.resume(co)
    worst_block_us = math.max(worst_block_us, clock.us - before)
    resumes = resumes + 1
    if not check(ok, name .. ": " .. tostring(value)) then break end
    if coroutine.status(co) == "dead" then result = value end
    clock.us = clock.us + 16667 -- the rest of the frame
  end
  check(coroutine.status(co) == "dead", name .. ": chunk did not end within " .. resumes .. " frames")
  for i, s in ipairs(sockets) do check(s.closed, name .. ": socket " .. i .. " left open") end
  return result or {}, resumes, worst_block_us
end

local function pong(ping, clock, opts)
  opts = opts or {}
  local ghost = opts.no_ghost and "" or entry("__gt", pack(">i8", clock.us + 50 + 7000000))
  return "_link_v\1\2" .. entry("sess", opts.session or SESSION) .. ghost .. ping:sub(10)
end

-- 1. Discovery flooded with packets that are not announcements: the 1.5 s deadline still ends the search.
do
  local r, frames, block = run("flooded discovery", function() return GARBAGE end, function() return nil end)
  check(r.error and r.error:find("no peer"), "flooded discovery reports no peer: " .. tostring(r.error))
  check(frames < 200, "flooded discovery ends near its deadline (" .. frames .. " frames)")
  check(r.packets and r.packets <= frames * 32, "at most 32 packets read per frame")
  check(block < 4000, "flooded discovery blocks < 4 ms per frame (" .. block .. " us)")
end

-- 2. Same-session pongs that bring no data points (no ghost time): the measurement fails and ends.
do
  local r, _, block = run("pongs without points", function(n) return n == 1 and ALIVE or nil end,
    function(ping, clock) return pong(ping, clock, { no_ghost = true }) end)
  check(r.error == "measurement failed" and r.unusable >= 20, "unusable pongs fail the measurement: "
    .. tostring(r.error) .. " unusable=" .. tostring(r.unusable))
  check(block < 8000, "no-point pongs block < 8 ms per frame (" .. block .. " us)")
end

-- 3. Pongs of another session or of an earlier ping are not counted.
do
  local r = run("unpaired pongs", function(n) return n == 1 and ALIVE or nil end,
    function(ping, clock) return pong(P.encode_ping(1), clock) end)
  check(r.error == "measurement failed" and (r.points or 0) == 0, "pongs of another ping are not counted")
  local r2 = run("other session", function(n) return n == 1 and ALIVE or nil end,
    function(ping, clock) return pong(ping, clock, { session = "OTHERSES" }) end)
  check(r2.error == "measurement failed" and (r2.points or 0) == 0, "pongs of another session are not counted")
end

-- 4. No replies at all: 5 timeouts fail the measurement, each frame blocking at most the budget plus one receive.
do
  local r, _, block = run("timeouts", function(n) return n == 1 and ALIVE or nil end, function() return nil end)
  check(r.error == "measurement failed" and r.timeouts == 5, "5 timeouts fail the measurement")
  check(block <= 7100, "timeouts block at most 4 ms + one 3 ms receive per frame (" .. block .. " us)")
end

-- 5. The normal path: one announcement, prompt pongs, then 120 samples.
do
  local r, _, block = run("normal", function(n) return n == 1 and ALIVE or nil end,
    function(ping, clock) return pong(ping, clock) end)
  check(r.samples and select(2, r.samples:gsub(",", "")) == 119, "120 samples")
  check(r.measurement and r.measurement.points > 100, "measurement completed")
  check(r.measurement and math.abs(r.measurement.intercept - 7000000) <= 200, "intercept close to the offset: "
    .. tostring(r.measurement and r.measurement.intercept))
  check(block < 8000, "normal path blocks < 8 ms per frame (" .. block .. " us)")
end

-- 6. Flooded while following: every frame still samples and yields.
do
  local r = run("flooded while following", function(n) return n == 1 and ALIVE or ALIVE end,
    function(ping, clock) return pong(ping, clock) end)
  check(r.samples and select(2, r.samples:gsub(",", "")) == 119, "120 samples while flooded")
end

print(string.format("follow_chunk_test: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
