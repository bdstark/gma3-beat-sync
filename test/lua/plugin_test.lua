-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Offline harness for the console plugin (plugin/gma3_beat_sync.lua with its two components) under stock Lua 5.5.
-- The console API (global variables, speed masters, sequences, Cmd, Printf) and LuaSocket are mocked; a simulated
-- peer announces a session and answers pings. The plugin's Main runs as a coroutine, one resume per 16.667 ms
-- frame, with an instruction limit per resume.
-- Usage: lua test/lua/plugin_test.lua

local root = (arg and arg[0] or ""):match("^(.*)test/lua/[^/]*$") or "./"

local failures, checks = 0, 0
local function check(ok, what)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    io.stderr:write("FAIL: ", what, "\n")
  end
  return ok
end

local function read(path)
  local f = assert(io.open(root .. path))
  local s = f:read("a")
  f:close()
  return s
end

local pack = string.pack
local function entry(key, value) return key .. pack(">I4", #value) .. value end
local FRAME = 16667

-- A fresh console: returns the console table and the plugin's Main.
local function console(vars)
  local c = { us = 1000000, cmds = {}, printed = {}, vars = {}, mc_queue = {}, uc_queue = {}, sockets = {},
    peer = { node = "PEERNODE", mpb = 500000, offset = 7000000, playing = true, ss_beats = 0, ss_time = 1,
      present = true },
    sequences = { [1] = {}, [5] = {} }, show = "Show A", cmd_error = nil }
  for k, v in pairs(vars or {}) do c.vars["BeatSync." .. k] = v end
  c.masters = {}
  c.scale_sets = 0
  for n = 1, 16 do
    -- like the console: SpeedScale reads as an enum index; Get with the Display role gives its name
    c.masters[n] = { no = n, scale = "One",
      Set = function(self, k, v) assert(k == "SpeedScale") self.scale = v c.scale_sets = c.scale_sets + 1 end,
      Get = function(self, k, role) assert(k == "SpeedScale" and role == "Display") return self.scale end }
    setmetatable(c.masters[n], { __index = function(self, k) if k == "SpeedScale" then
      return ({ One = 0, Mul2 = 1, Mul4 = 2, Mul8 = 3 })[self.scale] end end })
  end

  local function alive()
    local p = c.peer
    return "_asdp_v\1" .. pack(">I1I1I2", 1, 5, 0) .. p.node
      .. entry("tmln", pack(">i8i8i8", p.mpb, p.beat_origin or 0, p.time_origin or 0)) .. entry("sess", p.node)
      .. entry("stst", pack(">I1i8i8", p.playing and 1 or 0, p.ss_beats, p.ss_time))
      .. entry("mep4", pack(">I1I1I1I1I2", 127, 0, 0, 1, 50000))
  end
  c.alive = alive
  c.byebye = function() return "_asdp_v\1" .. pack(">I1I1I2", 3, 0, 0) .. c.peer.node end

  local function udp()
    local s = { closed = false, memberships = {} }
    function s:setoption(k, v) if k == "ip-add-membership" then self.memberships[#self.memberships + 1] = v.interface end return 1 end
    function s:setsockname(a, port) self.port = port return 1 end
    function s:settimeout(t) self.timeout = t end
    function s:close() self.closed = true end
    function s:receivefrom()
      c.us = c.us + 2
      if self.port == 20808 then return table.remove(c.mc_queue, 1) end
    end
    function s:sendto(data)
      c.us = c.us + 2
      -- the peer answers at once: session, its ghost time, then the ping's payload (link/PingResponder.hpp)
      if c.peer.present and not c.peer.mute then
        c.uc_queue[#c.uc_queue + 1] = "_link_v\1\2" .. entry("sess", c.peer.node)
          .. entry("__gt", pack(">i8", c.us + 50 + c.peer.offset)) .. data:sub(10)
      end
      return #data
    end
    function s:receive()
      local d = table.remove(c.uc_queue, 1)
      if d then c.us = c.us + 100 elseif (self.timeout or 0) > 0 then c.us = c.us + math.floor(self.timeout * 1e6) end
      return d
    end
    c.sockets[#c.sockets + 1] = s
    return s
  end
  local socket = { udp4 = udp, gettime = function() c.us = c.us + 1 return c.us / 1e6 end }

  local globals = {}
  local env = setmetatable({
    require = function(name) assert(name == "socket") return socket end,
    GlobalVars = function() return globals end,
    GetVar = function(_, name) local v = c.vars[name] if v == nil then return end return v end,
    SetVar = function(_, name, v) c.vars[name] = v end,
    ShowData = function() return { Masters = { Speed = c.masters } } end,
    DataPool = function() return { Sequences = c.sequences } end,
    Root = function() return { ManetSocket = { Showfile = c.show } } end,
    Cmd = function(cmd)
      if c.cmd_error then error(c.cmd_error) end
      c.cmds[#c.cmds + 1] = { t = c.us, cmd = cmd }
      return "Ok"
    end,
    Enums = { Roles = { Display = "Display" } },
    Printf = function(f, ...) c.printed[#c.printed + 1] = string.format(f, ...) end,
    ErrPrintf = function(f, ...) c.printed[#c.printed + 1] = "ERROR " .. string.format(f, ...) end,
  }, { __index = _G })
  env._G = env
  local sig = {}
  assert(load(read("plugin/beat_sync_protocol.lua"), "=protocol", "t", env))("gma3_beat_sync", "beat_sync_protocol", sig)
  assert(load(read("plugin/beat_sync_follower.lua"), "=follower", "t", env))("gma3_beat_sync", "beat_sync_follower", sig)
  local Main = assert(load(read("plugin/gma3_beat_sync.lua"), "=plugin", "t", env))("gma3_beat_sync", "gma3_beat_sync", sig)
  c.Main, c.env, c.sig = Main, env, sig

  local co = coroutine.create(function() Main(nil, "") end)
  c.co = co
  local frame_no = 0
  function c.run(seconds, on_frame)
    local n = math.floor(seconds * 1e6 / FRAME)
    for _ = 1, n do
      if coroutine.status(co) == "dead" then return end
      frame_no = frame_no + 1
      if c.peer.present and frame_no % 15 == 0 then c.mc_queue[#c.mc_queue + 1] = alive() end -- every 250 ms
      if on_frame then on_frame(frame_no) end
      debug.sethook(co, function() error("no yield within 300000 instructions", 0) end, "", 300000)
      local start = c.us
      local ok, e = coroutine.resume(co)
      check(ok, "resume: " .. tostring(e))
      check(c.us - start < 8000, "a frame blocked " .. (c.us - start) .. " us")
      c.us = start + FRAME
    end
  end
  return c
end

-- Session beat (micro-beats) at host time t for the simulated peer's timeline.
local function beat_at(c, t)
  local p = c.peer
  return (p.beat_origin or 0) + (t + p.offset - (p.time_origin or 0)) * 1000000 // p.mpb
end

-- A tempo change as a Link peer makes it: the new timeline starts at the current beat with a larger beat origin,
-- so other peers adopt it (link/ClientSessionTimelines.hpp, updateSessionTimelineFromClient; link/Sessions.hpp).
local function set_tempo(c, mpb)
  local p = c.peer
  local b = beat_at(c, c.us) + 1
  p.time_origin = (p.time_origin or 0) + ((b - (p.beat_origin or 0)) * p.mpb) // 1000000
  p.beat_origin, p.mpb = b, mpb
end
local function cmds_matching(c, pattern)
  local r = {}
  for _, x in ipairs(c.cmds) do if x.cmd:find(pattern) then r[#r + 1] = x end end
  return r
end

------------------------------------------------------------------------------------------------------------------
-- Following: tempo, ReSync on bars, OnBar, numbered actions, status

do
  local c = console({ Master = "3", Resync = "1, 5", OnBar = "Go+ Macro 1", Action1 = "8 2 Go+ Macro 2",
    OnJoin = "Go+ Macro 3", OnStart = "Go+ Macro 4" })
  c.run(6)
  check(c.vars["BeatSync.State"] == "following", "State following: " .. tostring(c.vars["BeatSync.State"]))
  check(c.vars["BeatSync.Peers"] == "1", "Peers 1")
  check(c.vars["BeatSync.Tempo"] == "120.000", "Tempo 120.000: " .. tostring(c.vars["BeatSync.Tempo"]))
  check(c.vars["BeatSync.Playing"] == "yes", "Playing yes")
  check(c.vars["BeatSync.Version"] == "0.1.0", "Version")
  check(c.vars["BeatSync.Problems"] == "", "no problems")
  check(c.vars["BeatSync.MissedBeats"] == "0", "no missed beats: " .. tostring(c.vars["BeatSync.MissedBeats"]))
  local tempo = cmds_matching(c, "^Master 3%.3 At BPM")
  check(#tempo == 1 and tempo[1].cmd == "Master 3.3 At BPM 120.0000", "tempo written once")
  check(#cmds_matching(c, "^Go%+ Macro 3$") == 1, "OnJoin once")
  check(#cmds_matching(c, "^Go%+ Macro 4$") == 1, "OnStart once")
  -- bars: ReSync of 1 and 5 and OnBar, each on the frame nearest the bar
  local bars = cmds_matching(c, "^Go%+ Macro 1$")
  check(#bars >= 2, "OnBar ran on the bars (" .. #bars .. ")")
  for _, b in ipairs(bars) do
    local beat = beat_at(c, b.t)
    local off = math.min(beat % 4000000, 4000000 - beat % 4000000) * c.peer.mpb // 1000000
    check(off <= FRAME // 2 + 200, "OnBar within half a frame of the bar (" .. off .. " us)")
  end
  check(#cmds_matching(c, "^ReSync Sequence 1$") == #bars and #cmds_matching(c, "^ReSync Sequence 5$") == #bars,
    "ReSync of each configured sequence on every bar")
  -- Action1 every 8 beats at phase 2
  for _, a in ipairs(cmds_matching(c, "^Go%+ Macro 2$")) do
    local k = (beat_at(c, a.t) + 500000) // 1000000
    check((k - 2) % 8 == 0, "Action1 on beat 8n+2, got " .. k)
  end
  check(#cmds_matching(c, "^Go%+ Macro 2$") >= 1, "Action1 ran")
  check(c.vars["BeatSync.LastAction"]:find("at beat"), "LastAction names the beat")

  -- tempo changes: 133.5 rewrites, a change below the threshold does not, 300 raises the SpeedScale
  set_tempo(c, 449438) -- 133.5 bpm
  c.run(1)
  check(cmds_matching(c, "^Master 3%.3")[2].cmd == "Master 3.3 At BPM 133.5001", "tempo 133.5 written: "
    .. tostring(cmds_matching(c, "^Master 3%.3")[2] and cmds_matching(c, "^Master 3%.3")[2].cmd))
  set_tempo(c, 449436) -- +0.0006 bpm, below the 0.01 threshold
  c.run(1)
  check(#cmds_matching(c, "^Master 3%.3") == 2, "a change below the threshold is not written")
  set_tempo(c, 200000) -- 300 bpm
  c.run(1)
  check(c.masters[3].scale == "Mul2", "SpeedScale Mul2 for 300 bpm: " .. tostring(c.masters[3].scale))
  check(cmds_matching(c, "^Master 3%.3")[3].cmd == "Master 3.3 At BPM 300.0000", "tempo 300 written")
  set_tempo(c, 193548) -- 310 bpm: the scale is already Mul2, so it is not written again
  c.run(1)
  check(c.scale_sets == 1, "SpeedScale written once, not on every tempo write (" .. c.scale_sets .. ")")

  -- stop
  c.Main(nil, "stop")
  c.run(0.1)
  check(coroutine.status(c.co) == "dead", "stopped")
  check(c.vars["BeatSync.State"] == "stopped", "State stopped")
  for i, s in ipairs(c.sockets) do check(s.closed, "socket " .. i .. " closed") end
  check(c.sockets[1].memberships[1] == "127.0.0.1" and c.sockets[1].memberships[2] == "0.0.0.0",
    "joined on loopback and the default interface")
end

------------------------------------------------------------------------------------------------------------------
-- Problems are reported: missing master and sequences, bad actions; no session

do
  local c = console({ Master = "17", Resync = "1, 99", Action2 = "4 7 Go+ Macro 9", Quantum = "x" })
  c.peer.present = false
  c.run(1)
  local p = c.vars["BeatSync.Problems"] or ""
  check(p:find("Speed master '17' does not exist"), "missing speed master reported: " .. p)
  check(p:find("Sequence '99' in Resync does not exist"), "missing sequence reported")
  check(p:find("Action2 must be"), "bad action reported")
  check(p:find("Quantum must be"), "bad quantum reported")
  check(c.vars["BeatSync.State"]:find("^no session"), "no session: " .. tostring(c.vars["BeatSync.State"]))
  check(#c.cmds == 0, "nothing sent without a session")
  -- fixing the configuration while running clears the problems
  c.vars["BeatSync.Master"], c.vars["BeatSync.Resync"], c.vars["BeatSync.Action2"], c.vars["BeatSync.Quantum"] =
    "2", "5", "", "4"
  c.run(1)
  check(c.vars["BeatSync.Problems"] == "", "problems cleared after the fix: " .. tostring(c.vars["BeatSync.Problems"]))
end

------------------------------------------------------------------------------------------------------------------
-- Leaving: ByeBye runs OnLeave and reports no session; rejoining runs OnJoin again and rewrites the tempo

do
  local c = console({ Master = "4", OnLeave = "Go+ Macro 7", OnJoin = "Go+ Macro 8" })
  c.run(2)
  c.peer.present = false
  c.mc_queue[#c.mc_queue + 1] = c.byebye()
  c.run(1)
  check(#cmds_matching(c, "^Go%+ Macro 7$") == 1, "OnLeave after ByeBye")
  check(c.vars["BeatSync.State"] == "no session", "no session after the peer left")
  c.peer.present = true
  c.run(2)
  check(#cmds_matching(c, "^Go%+ Macro 8$") == 2, "OnJoin again after rejoining")
  check(#cmds_matching(c, "^Master 3%.4") == 2, "tempo written again after rejoining")
  -- a peer that stops announcing is dropped after its ttl
  c.peer.present = false
  c.run(6)
  check(#cmds_matching(c, "^Go%+ Macro 7$") == 2, "OnLeave after the ttl")
end

------------------------------------------------------------------------------------------------------------------
-- StartStop: beat actions wait for a quantized start and stop with the session; StartStop off runs them anyway

do
  local c = console({ OnBeat = "Go+ Macro 5", OnStart = "Go+ Macro 4", OnStop = "Go+ Macro 6" })
  c.peer.playing = false
  c.run(2)
  check(#cmds_matching(c, "^Go%+ Macro 5$") == 0, "no beat actions while stopped")
  -- start requested now for the next bar
  local nowbeat = beat_at(c, c.us)
  c.peer.playing, c.peer.ss_beats, c.peer.ss_time = true, (nowbeat // 4000000 + 1) * 4000000, c.us + c.peer.offset
  local start_beat = c.peer.ss_beats
  c.run(4)
  local starts = cmds_matching(c, "^Go%+ Macro 4$")
  check(#starts == 1, "OnStart once")
  local beats = cmds_matching(c, "^Go%+ Macro 5$")
  check(#beats >= 4, "beat actions while playing")
  check(beats[1] and (beat_at(c, beats[1].t) + 500000) // 1000000 == start_beat // 1000000,
    "the first beat action on the start beat")
  check(starts[1] and math.abs(starts[1].t - beats[1].t) <= FRAME, "OnStart on the start beat's frame")
  c.peer.playing, c.peer.ss_beats, c.peer.ss_time = false, beat_at(c, c.us), c.us + c.peer.offset + 1
  c.run(1)
  local n = #cmds_matching(c, "^Go%+ Macro 5$")
  c.run(2)
  check(#cmds_matching(c, "^Go%+ Macro 5$") == n, "no beat actions after stop")
  check(#cmds_matching(c, "^Go%+ Macro 6$") == 1, "OnStop once")
  check(c.vars["BeatSync.Playing"] == "no", "Playing no after the stop: " .. tostring(c.vars["BeatSync.Playing"]))
  c.vars["BeatSync.StartStop"] = "off"
  c.run(2)
  check(#cmds_matching(c, "^Go%+ Macro 5$") > n, "StartStop off: beat actions while stopped")
end

------------------------------------------------------------------------------------------------------------------
-- Failures inside a frame are reported and the plugin keeps running; a show load is reported

do
  local c = console({ OnBeat = "Go+ Macro 5" })
  c.run(1)
  c.cmd_error = "command refused"
  c.run(1)
  check((c.vars["BeatSync.LastAction"] or ""):find("failed: .*command refused"), "a failing command is reported: "
    .. tostring(c.vars["BeatSync.LastAction"]))
  check(coroutine.status(c.co) ~= "dead", "still running after failing commands")
  c.cmd_error = nil
  c.show = "Show B"
  c.run(1)
  check(c.env.BeatSync.status.last_warning == "show loaded: Show B", "show load reported: "
    .. tostring(c.env.BeatSync.status.last_warning))
  check(c.vars["BeatSync.State"] == "following", "still following after the show load")
  -- the shared Lua table carries the full status
  check(c.env.BeatSync.status.peers == 1 and c.env.BeatSync.status.frame_ms, "shared status table")
end

------------------------------------------------------------------------------------------------------------------
-- A second start while running is refused; unknown arguments are reported

do
  local c = console({})
  c.run(0.5)
  c.Main(nil, "")
  check(c.printed[#c.printed] == "gma3_beat_sync: already running", "a second start is refused")
  c.Main(nil, "bogus")
  check(c.printed[#c.printed]:find("unknown argument"), "unknown argument reported")
  c.Main(nil, "status")
  check(c.printed[#c.printed - 0]:find("gma3_beat_sync") ~= nil, "status printed")
end

print(string.format("plugin_test: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
