-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- BS-01 probe plugin (not part of the product). Answers: can a second plugin run its own frame loop beside
-- gma3-mcp's bridge (or use Timer() instead), and what does writing status to a shared Lua global and to console
-- global variables cost? Start it asynchronously so the caller is not blocked, e.g. from the bridge:
--   CmdIndirect('Plugin "gbs_probe" "loop 600"')     frame loop, 600 frames
--   CmdIndirect('Plugin "gbs_probe" "timer 0.02 300"') Timer() every 0.02 s, 300 calls
--   CmdIndirect('Plugin "gbs_probe" "responder 20900 600"') answer pings once per frame for 600 frames
--   CmdIndirect('Plugin "gbs_probe" "stop"')          ends a running loop
-- Results: the shared Lua global _G.gbs_probe and the console global variable "gbs_probe" (a short summary).

local socket = require("socket")

-- Packets read per frame in each mode; the rest wait for the next frame, so a flooded socket cannot keep the
-- plugin thread from yielding (or from seeing a stop). The BS-01 measurements were taken before this bound was added;
-- they saw at most a couple of packets per frame, far below it.
local MAX_PACKETS = 32

local function now() return socket.gettime() end

local function summarize(ds)
  table.sort(ds)
  local n = #ds
  if n == 0 then return { n = 0 } end
  local function q(f) return ds[math.max(1, math.min(n, math.floor(n * f + 0.5)))] end
  return { n = n, min = ds[1], median = q(0.5), p90 = q(0.9), p99 = q(0.99), max = ds[n],
    over25 = (function() local c = 0 for _, d in ipairs(ds) do if d > 25 then c = c + 1 end end return c end)() }
end

local function publish(st)
  -- A short summary in a console global variable, readable by the command line and by other plugins.
  SetVar(GlobalVars(), "gbs_probe", string.format("%s frames=%d running=%s", st.mode, st.frames, tostring(st.running)))
end

local function loop(frames)
  local st = { mode = "loop", frames = 0, running = true, started = now(), deltas = {}, setvar_ms = {} }
  _G.gbs_probe = st
  local u = socket.udp4()
  u:setoption("reuseaddr", true)
  u:setoption("reuseport", true)
  u:setsockname("0.0.0.0", 20808)
  u:setoption("ip-add-membership", { multiaddr = "224.76.78.75", interface = "127.0.0.1" })
  u:settimeout(0)
  st.packets = 0
  local last = now()
  for i = 1, frames do
    if st.stop then break end
    local n = 0
    while n < MAX_PACKETS and u:receivefrom() do n = n + 1 end
    st.packets = st.packets + n
    if n == MAX_PACKETS then st.capped = (st.capped or 0) + 1 end
    local t = now()
    st.deltas[#st.deltas + 1] = (t - last) * 1000
    last = t
    st.frames = i
    if i % 15 == 0 then -- status at 4 Hz
      local t0 = now()
      publish(st)
      st.setvar_ms[#st.setvar_ms + 1] = (now() - t0) * 1000
    end
    coroutine.yield()
  end
  u:close()
  st.running = false
  st.frame_ms = summarize(st.deltas)
  st.setvar = summarize(st.setvar_ms)
  st.deltas, st.setvar_ms = nil, nil
  publish(st)
end

local function timer(interval, count)
  local st = { mode = "timer", frames = 0, running = true, started = now(), deltas = {}, interval = interval }
  _G.gbs_probe = st
  local last = now()
  local function tick()
    local t = now()
    st.deltas[#st.deltas + 1] = (t - last) * 1000
    last = t
    st.frames = st.frames + 1
  end
  local function done()
    st.running = false
    st.frame_ms = summarize(st.deltas)
    st.deltas = nil
    publish(st)
  end
  Timer(tick, interval, count, done)
end

-- Answers measurement pings once per frame, as a full peer in a plugin would: each frame it drains the socket on
-- 127.0.0.1:<port> and replies to each ping at once with a pong (session id, ghost time = host time, the ping's
-- payload), as link/PingResponder.hpp does. The pinger's round trips show how late the replies are.
local function responder(port, frames)
  local st = { mode = "responder", frames = 0, running = true, started = now(), answered = 0, per_frame = {} }
  _G.gbs_probe = st
  local u = socket.udp4()
  u:setsockname("127.0.0.1", port)
  u:settimeout(0)
  local function entry(key, value) return key .. string.pack(">I4", #value) .. value end
  for i = 1, frames do
    if st.stop then break end
    local n, reads = 0, 0
    while reads < MAX_PACKETS do
      local d, ip, p = u:receivefrom()
      if not d then break end
      reads = reads + 1
      if #d >= 9 and d:sub(1, 9) == "_link_v\1\1" then
        local ghost = math.floor(now() * 1e6 + 0.5)
        u:sendto("_link_v\1\2" .. entry("sess", "gbsprobe") .. entry("__gt", string.pack(">i8", ghost)) .. d:sub(10), ip, p)
        n = n + 1
      end
    end
    st.answered = st.answered + n
    if reads == MAX_PACKETS then st.capped = (st.capped or 0) + 1 end
    if n > 0 then st.per_frame[#st.per_frame + 1] = n end
    st.frames = i
    coroutine.yield()
  end
  u:close()
  st.running = false
  st.per_frame = summarize(st.per_frame)
  publish(st)
end

local function Main(_, argument)
  local words = {}
  for w in tostring(argument or ""):gmatch("%S+") do words[#words + 1] = w end
  if words[1] == "loop" then
    loop(tonumber(words[2]) or 600)
  elseif words[1] == "timer" then
    timer(tonumber(words[2]) or 0.02, tonumber(words[3]) or 300)
  elseif words[1] == "responder" then
    responder(tonumber(words[2]) or 20900, tonumber(words[3]) or 600)
  elseif words[1] == "stop" then
    if _G.gbs_probe then _G.gbs_probe.stop = true end
  else
    Printf("gbs_probe: loop <frames> | timer <seconds> <count> | stop")
  end
end

return Main
