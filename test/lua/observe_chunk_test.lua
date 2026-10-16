-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Offline harness for test/live/observe_chunk.lua (the live tests' independent observer) under stock Lua 5.5, with
-- mocked sockets, a mocked sequence and a simulated clock, one resume per frame under an instruction limit:
--   - a slow responder whose pongs arrive behind later pings (as LinkMaster's did) still gives a measurement;
--   - the chunk reports the session's newest start/stop state and the cue changes;
--   - it ends and closes its sockets.
-- Usage: lua test/lua/observe_chunk_test.lua

local root = (arg and arg[0] or ""):match("^(.*)test/lua/[^/]*$") or "./"
local P = dofile(root .. "plugin/beat_sync_protocol.lua")
local f = assert(io.open(root .. "test/live/observe_chunk.lua"))
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
local function alive(playing, beats, ts)
  return "_asdp_v\1" .. pack(">I1I1I2", 1, 5, 0) .. SESSION
    .. entry("tmln", pack(">i8i8i8", 500000, 0, 0)) .. entry("sess", SESSION)
    .. entry("stst", pack(">I1i8i8", playing and 1 or 0, beats, ts))
    .. entry("mep4", pack(">I1I1I1I1I2", 127, 0, 0, 1, 50000))
end

-- slow_every: every Nth pong comes late, after the next ping was sent and ahead of that ping's own pong (as
-- LinkMaster's sometimes did); 0 = every pong at once
local function run(slow_every)
  local clock = { us = 1000000 }
  local sockets, pending, mc_packets = {}, {}, { alive(false, 0, 1), alive(true, 4000000, 2) }
  local cue = 1000
  local function udp()
    local s = { closed = false }
    function s:setoption() return 1 end
    function s:setsockname() return 1 end
    function s:settimeout(t) self.timeout = t end
    function s:close() self.closed = true end
    function s:receivefrom() clock.us = clock.us + 2 return table.remove(mc_packets, 1) end
    local sent = 0
    function s:sendto(data)
      clock.us = clock.us + 2
      sent = sent + 1
      local pong = "_link_v\1\2" .. entry("sess", SESSION) .. entry("__gt", pack(">i8", clock.us + 7000000)) .. data:sub(10)
      if slow_every > 0 and sent % slow_every == 0 then
        self.held = pong -- this one comes after the next ping
      else
        if self.released then pending[#pending + 1] = self.released self.released = nil end
        pending[#pending + 1] = pong
      end
      if self.held and sent % slow_every ~= 0 then self.released, self.held = self.held, nil end
      return #data
    end
    function s:receive()
      if self.released then local r = self.released self.released = nil clock.us = clock.us + 100 return r end
      if #pending > 0 then clock.us = clock.us + 100 return table.remove(pending, 1) end
      clock.us = clock.us + math.floor((self.timeout or 0) * 1e6)
      return nil
    end
    sockets[#sockets + 1] = s
    return s
  end
  local seq = setmetatable({}, { __index = function(_, k) if k == "CurrentCue" then return { no = cue } end end })
  local mock = { udp4 = udp, gettime = function() clock.us = clock.us + 1 return clock.us / 1e6 end }
  local env = setmetatable({ P = P, SEQ = 950, FRAMES = 60, require = function() return mock end,
    DataPool = function() return { Sequences = { [950] = seq } } end }, { __index = _G })
  local co = coroutine.create(assert(load(source, "=observe_chunk.lua", "t", env)))
  local result, frames = nil, 0
  while coroutine.status(co) ~= "dead" and frames < 600 do
    debug.sethook(co, function() error("no yield within 200000 instructions", 0) end, "", 200000)
    local ok, value = coroutine.resume(co)
    if not check(ok, "slow_every " .. slow_every .. ": " .. tostring(value)) then break end
    if coroutine.status(co) == "dead" then result = value end
    frames = frames + 1
    clock.us = clock.us + 16667
    if frames % 20 == 0 then cue = cue + 1000 end
  end
  for i, s in ipairs(sockets) do check(s.closed, "slow_every " .. slow_every .. ": socket " .. i .. " closed") end
  return result or {}
end

local r0 = run(0)
check(not r0.error, "a prompt responder: " .. tostring(r0.error))
check(r0.intercept and math.abs(r0.intercept - 7000000) <= 200, "intercept near the offset: " .. tostring(r0.intercept))
local r1 = run(3)
check(not r1.error, "every third pong late: still measured: " .. tostring(r1.error))
check(r1.start_stop == "1,4000000,2", "the newest start/stop state is reported: " .. tostring(r1.start_stop))
check(r1.changes and r1.changes:find(":2000"), "cue changes are recorded: " .. tostring(r1.changes))

print(string.format("observe_chunk_test: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
