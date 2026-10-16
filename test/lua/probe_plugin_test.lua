-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Offline harness for the BS-01 probe plugin (docs/probes/bs-01/gbs_probe.lua) under stock Lua 5.5: with a socket
-- that is always readable, its frame loop and its ping responder must still yield every frame (within an
-- instruction limit), read at most 32 packets per frame, see a stop, and close their socket.
-- Usage: lua test/lua/probe_plugin_test.lua

local root = (arg and arg[0] or ""):match("^(.*)test/lua/[^/]*$") or "./"
local f = assert(io.open(root .. "docs/probes/bs-01/gbs_probe.lua"))
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

local PING = "_link_v\1\1" .. "__ht" .. string.pack(">I4i8", 8, 1000)

local function run(mode, packet)
  local clock, sockets, reads, sends = 1000, {}, 0, 0
  local function udp()
    local s = { closed = false }
    function s:setoption() return 1 end
    function s:setsockname() return 1 end
    function s:settimeout() end
    function s:close() self.closed = true end
    function s:receivefrom() reads = reads + 1 clock = clock + 1e-6 return packet, "127.0.0.1", 40000 end
    function s:sendto() sends = sends + 1 return 1 end
    sockets[#sockets + 1] = s
    return s
  end
  local vars = {}
  local env = setmetatable({
    require = function() return { udp4 = udp, gettime = function() clock = clock + 1e-6 return clock end } end,
    GlobalVars = function() return vars end,
    SetVar = function(g, k, v) g[k] = v end,
    Printf = function() end,
    Timer = function() end,
  }, { __index = _G })
  env._G = env
  local Main = assert(load(source, "=gbs_probe.lua", "t", env))()
  local co = coroutine.create(function() Main(nil, mode .. " 600") end)
  local LIMIT = 200000
  local resumes, worst_reads, worst_sends = 0, 0, 0
  while coroutine.status(co) ~= "dead" and resumes < 700 do
    if resumes == 10 then Main(nil, "stop") end
    debug.sethook(co, function() error("no yield within " .. LIMIT .. " instructions", 0) end, "", LIMIT)
    local r0, s0 = reads, sends
    local ok, err = coroutine.resume(co)
    resumes = resumes + 1
    if not check(ok, mode .. ": " .. tostring(err)) then break end
    worst_reads = math.max(worst_reads, reads - r0)
    worst_sends = math.max(worst_sends, sends - s0)
    clock = clock + 0.016667
  end
  check(coroutine.status(co) == "dead", mode .. ": did not end")
  check(resumes <= 12, mode .. ": the stop was seen at the next frame (" .. resumes .. " resumes)")
  check(worst_reads <= 33, mode .. ": at most 32 packets read per frame (" .. worst_reads .. ")")
  for i, s in ipairs(sockets) do check(s.closed, mode .. ": socket " .. i .. " closed") end
  check(env.gbs_probe and env.gbs_probe.running == false, mode .. ": state not running at the end")
  check(env.gbs_probe and (env.gbs_probe.capped or 0) >= 1, mode .. ": the cap is reported")
  return worst_sends
end

run("loop", "not a ping")
local sends = run("responder", PING)
check(sends <= 32, "responder: at most 32 pongs per frame (" .. sends .. ")")

print(string.format("probe_plugin_test: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
