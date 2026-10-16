-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- gma3_beat_sync: a grandMA3 plugin that follows a tempo session on the network (meant to be compatible with
-- Link™) and drives the show from it: a speed master at the session's tempo, ReSync of chosen sequences on the bar,
-- and commands on beats, bars, start, stop, joining and leaving.
--
-- It follows without announcing itself (BS-01: a plugin cannot answer other peers' measurements promptly enough to
-- be a full peer). All work is bounded per console frame: at most 32 packets per socket, measurement exchanges
-- within 4 ms (each receive bounded to 3 ms), and status written four times a second.
--
-- Commands:
--   Plugin "gma3_beat_sync"            start following (runs until stopped)
--   Plugin "gma3_beat_sync" "stop"     stop at the next frame
--   Plugin "gma3_beat_sync" "status"   print the status to the command line history
--   Plugin "gma3_beat_sync" "play"     peer mode: start the session (on its next bar)
--   Plugin "gma3_beat_sync" "pause"    peer mode: stop the session
--
-- A show load ends the plugin's loop, and the plugin cannot start itself again: start it after loading a show
-- (BS-02 record). When the console runs this chunk again at the load, it marks the status as not running.
--
-- Configuration and status are console global variables named BeatSync.<Key>; see docs/plugin.md. Configuration
-- is read when the plugin starts and every half second while it runs, so it can be changed with
--   SetGlobalVariable "BeatSync.Master" "3"
-- The full status is also in the shared Lua table BeatSync (_G.BeatSync.status).
--
-- Components (plugin/gma3_beat_sync.xml): beat_sync_protocol.lua and beat_sync_follower.lua register themselves in
-- the plugin's signal table; this one returns Main and Cleanup.

local pluginName, componentName, signalTable = select(1, ...)

local VERSION = "0.1.0"
local PREFIX = "BeatSync."

local MAX_PACKETS = 32            -- per socket per frame; the rest wait for the next frame
local MEASURE_BUDGET_US = 4000    -- measurement time per frame; a 3 ms receive may start before it ends
local MAX_EXCHANGES_PER_FRAME = 10
local CONFIG_EVERY = 30           -- frames between configuration reads (about 0.5 s)
local STATUS_EVERY = 15           -- frames between status writes (about 4 Hz)
local FRAME_WINDOW = 120          -- frames kept for the frame statistics
local MAX_ERRORS = 50             -- consecutive failing frames before the plugin stops

-- The shared table other plugins and Lua can read. It survives ReloadAllPlugins (_G is console-global).
_G.BeatSync = _G.BeatSync or {}
local shared = _G.BeatSync
shared.version = VERSION

------------------------------------------------------------------------------------------------------------------
-- Configuration

local DEFAULTS = {
  Master = "",              -- speed master 1..16 to set to the session tempo; empty: none
  Quantum = "4",            -- beats per bar
  StartStop = "off",        -- off: beat and bar actions run whenever there is a session (sources such as a DJ booth
                            -- relayed into Link may never send a start); on: only while the session plays
  Resync = "",              -- sequences to ReSync on each bar, e.g. "1, 5, 12"
  OnBar = "",               -- a command on each bar
  OnBeat = "",              -- a command on each beat
  OnStart = "", OnStop = "", OnJoin = "", OnLeave = "",
  TempoThreshold = "0.01",  -- BPM change that rewrites the speed master
  LeadMs = "0",             -- run beat actions this much early (the console applies a command a frame later)
  Interfaces = "127.0.0.1 0.0.0.0", -- addresses to join the session's multicast group on; 0.0.0.0 = default interface
  Mode = "follow",          -- follow: listen only; peer: also announce and answer measurements as a Link peer (BS-03)
}
local ACTIONS = 16 -- BeatSync.Action1 .. BeatSync.Action16: "<every N beats> <phase> <command>"

-- The status variables the plugin writes; none may share a name with the configuration (plugin_test checks).
local STATUS_VARS = { "State", "Peers", "Session", "Tempo", "Beat", "Phase", "Playing", "LastAction", "DriftMsPerMin",
  "FrameMs", "FrameJitterMs", "DroppedFrames", "MissedBeats", "Problems", "Error", "ActiveMode", "Node", "OwnSession",
  "Version", "Updated" }
shared.names = { config = DEFAULTS, status = STATUS_VARS, actions = ACTIONS }

local function getvar(name)
  local v = (GetVar(GlobalVars(), PREFIX .. name)) -- GetVar of a missing variable returns no value (BS-01)
  if v == nil then return nil end
  return tostring(v)
end

local function setvar(name, value)
  SetVar(GlobalVars(), PREFIX .. name, value == nil and "" or value)
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Reads and checks the configuration. Returns the configuration and a list of problems in words.
local function read_config()
  local c, problems = { raw = {} }, {}
  for k, d in pairs(DEFAULTS) do
    local v = getvar(k)
    c.raw[k] = v
    c[k] = trim(v ~= nil and v or d)
  end

  c.quantum = tonumber(c.Quantum)
  if not c.quantum or c.quantum <= 0 or c.quantum > 64 then
    problems[#problems + 1] = "Quantum must be a number of beats from 1 to 64, not '" .. c.Quantum .. "'"
    c.quantum = 4
  end
  c.start_stop = c.StartStop:lower() == "on"
  c.threshold = tonumber(c.TempoThreshold) or 0.01
  c.lead_us = math.floor((tonumber(c.LeadMs) or 0) * 1000 + 0.5)

  if c.Master ~= "" then
    local n = math.tointeger(tonumber(c.Master))
    local m = n and n >= 1 and n <= 16 and ShowData().Masters.Speed[n]
    if m then c.master, c.master_handle = n, m
    else problems[#problems + 1] = "Speed master '" .. c.Master .. "' does not exist (Master must be 1 to 16)" end
  end

  c.resync = {}
  for item in c.Resync:gmatch("[^,%s]+") do
    local n = math.tointeger(tonumber(item))
    if n and DataPool().Sequences[n] then c.resync[#c.resync + 1] = n
    else problems[#problems + 1] = "Sequence '" .. item .. "' in Resync does not exist" end
  end

  c.actions = {}
  for i = 1, ACTIONS do
    local v = getvar("Action" .. i)
    if v and trim(v) ~= "" then
      local every, phase, cmd = trim(v):match("^(%d+)%s+(%d+)%s+(.+)$")
      every, phase = tonumber(every), tonumber(phase)
      if every and every >= 1 and phase and phase < every then
        c.actions[#c.actions + 1] = { label = "Action" .. i, every = every, phase = phase, command = cmd }
      else
        problems[#problems + 1] = "Action" .. i .. " must be '<every N beats> <phase 0..N-1> <command>', not '" .. v .. "'"
      end
    end
  end

  c.interfaces = {}
  for a in c.Interfaces:gmatch("[^,%s]+") do c.interfaces[#c.interfaces + 1] = a end

  local mode = c.Mode:lower()
  if mode ~= "follow" and mode ~= "peer" then
    problems[#problems + 1] = "Mode must be follow or peer, not '" .. c.Mode .. "'"
    mode = "follow"
  end
  c.peer = mode == "peer"
  -- a peer announces itself on each interface address it knows (0.0.0.0 only listens: it has no address to announce)
  c.announce = {}
  for _, a in ipairs(c.interfaces) do
    local q = { a:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
    local ok = #q == 4
    for _, x in ipairs(q) do if tonumber(x) > 255 then ok = false end end
    if ok and a ~= "0.0.0.0" then c.announce[#c.announce + 1] = a end
  end
  if c.peer and #c.announce == 0 then
    problems[#problems + 1] = "Mode peer needs an interface address other than 0.0.0.0 in Interfaces"
  end
  return c, problems
end

------------------------------------------------------------------------------------------------------------------
-- Small helpers

local function median_and_p90(values)
  local v = table.move(values, 1, #values, 1, {})
  table.sort(v)
  if #v == 0 then return nil, nil end
  return v[(#v + 1) // 2], v[math.max(1, math.floor(#v * 0.9 + 0.5))]
end

local function fmt(x, digits)
  if x == nil then return "" end
  return string.format("%." .. (digits or 3) .. "f", x)
end

-- The effective tempo of a speed master: the fader's base tempo (BPM = 225 * (fader / 100) ^ log2(3.75), gma3-mcp
-- SB-06; BS-01) times its SpeedScale, read by name (the property itself reads as an enum index, BS-02).
local LOG2_375 = math.log(3.75, 2)
local function master_bpm(m)
  local okf, f = pcall(function() return m:GetFader({}) end)
  if not okf or type(f) ~= "number" then return nil end
  local oks, scale = pcall(function() return m:Get("SpeedScale", Enums.Roles.Display) end)
  scale = oks and tostring(scale) or "One"
  local factor = 1
  local n = tonumber(scale:match("^Mul(%d+)$"))
  local d = tonumber(scale:match("^Div(%d+)$"))
  if n then factor = n elseif d then factor = 1 / d end
  return 225 * (f / 100) ^ LOG2_375 * factor
end

------------------------------------------------------------------------------------------------------------------
-- The loop

local running = false

local function run()
  local P = type(signalTable) == "table" and signalTable.beat_sync_protocol
  local F = type(signalTable) == "table" and signalTable.beat_sync_follower
  if not (P and F) then
    ErrPrintf("gma3_beat_sync: the protocol or follower component is missing; reimport gma3_beat_sync.xml")
    return
  end
  local socket = require("socket")
  local function now_us() return P.llround(socket.gettime() * 1e6) end

  local status = { state = "starting", version = VERSION, errors = {}, warnings = {} }
  shared.status, shared.control = status, { stop = false }
  local control = shared.control

  local config, problems = read_config()
  status.problems = problems

  -- Sockets: the session's multicast group, and one unicast socket for measurement pings.
  local mc, uc = socket.udp4(), socket.udp4()
  local function close()
    if mc then mc:close() mc = nil end
    if uc then uc:close() uc = nil end
  end
  mc:setoption("reuseaddr", true)
  mc:setoption("reuseport", true)
  local ok, err = mc:setsockname("0.0.0.0", P.PORT)
  if not ok then
    close()
    status.state = "error"
    setvar("State", "error")
    setvar("Error", "cannot listen on UDP port " .. P.PORT .. ": " .. tostring(err))
    ErrPrintf("gma3_beat_sync: cannot listen on UDP port %d: %s", P.PORT, tostring(err))
    return
  end
  status.joined = {}
  for _, iface in ipairs(config.interfaces) do
    local jok, jerr = mc:setoption("ip-add-membership", { multiaddr = P.MULTICAST_ADDRESS, interface = iface })
    status.joined[#status.joined + 1] = iface .. (jok and "" or (" (failed: " .. tostring(jerr) .. ")"))
  end
  mc:settimeout(0)
  uc:setsockname("0.0.0.0", 0)
  local _, mep_port = uc:getsockname()
  mep_port = tonumber(mep_port)

  -- Peer mode (read when the plugin starts): a random node id, and a session founded at the speed master's current
  -- tempo, so joining nothing changes the console's tempo (TEMPO-5). Announcements go out on each interface address.
  local peer = config.peer and #config.announce > 0
  local senders, node_id = {}, nil
  if peer then
    math.randomseed(math.floor(socket.gettime() * 1e6) % 2 ^ 31)
    local bytes = {}
    for i = 1, 8 do bytes[i] = string.char(math.random(0, 255)) end
    node_id = table.concat(bytes)
    for _, a in ipairs(config.announce) do
      local sd = socket.udp4()
      if sd:setsockname(a, 0) then
        sd:setoption("ip-multicast-if", a)
        sd:setoption("ip-multicast-loop", true)
        senders[#senders + 1] = { address = a, sock = sd }
      else
        sd:close()
        problems[#problems + 1] = "cannot send from " .. a
      end
    end
    peer = #senders > 0
  end
  local close_listen = close
  close = function()
    close_listen()
    for _, sd in ipairs(senders) do sd.sock:close() end
    senders = {}
  end
  local start_bpm = 120
  if peer and config.master_handle then start_bpm = master_bpm(config.master_handle) or 120 end
  local follower = F.new(P, { quantum = config.quantum,
    peer = peer and { node_id = node_id, now_us = now_us(), bpm = start_bpm } or nil })
  status.mode = peer and "peer" or "follow"
  status.node = node_id and P.hex(node_id) or nil
  local frames, frame_periods, dropped = 0, {}, 0
  status.frame_periods_us = frame_periods -- the last FRAME_WINDOW frame periods, oldest first
  local last_frame_us = now_us()
  -- What the speed master was last set to ({ master, bpm }); nil when it must be set (after joining, a show load or
  -- a change of BeatSync.Master). Reconciled every frame against the session's current tempo.
  local tempo_written, tempo_retry_us, consecutive_errors = nil, 0, 0
  local tempo_settle_us, tempo_moves = 0, 0 -- peer mode: settle time after a write, and reads of an operator's change
  local showfile = Root().ManetSocket and Root().ManetSocket.Showfile
  status.show = showfile

  local function report(kind, text)
    local list = status[kind]
    list[#list + 1] = text
    if #list > 10 then table.remove(list, 1) end
    status["last_" .. kind:sub(1, -2)] = text
  end

  -- Runs a command line and classifies the console's answer. Cmd returns the command's feedback as text ("OK";
  -- "Object not found" for a missing object or keyword, BS-02 record) rather than raising, so the text decides:
  -- "ok", "failed" (an answer that says so), or "uncertain" (anything else). Nothing is retried.
  local FAILURE_WORDS = { "not found", "error", "illegal", "invalid", "unknown", "denied", "not allowed", "failed",
    "cannot", "can't", "refused" }
  local function run_cmd(cmd)
    local ok2, result = pcall(Cmd, cmd)
    if not ok2 then return "failed", tostring(result) end
    if result == true then return "ok", "OK" end
    if result == false then return "failed", "false" end
    if type(result) ~= "string" then return "uncertain", tostring(result) end
    local lower = result:lower()
    if lower == "ok" then return "ok", result end
    for _, w in ipairs(FAILURE_WORDS) do
      if lower:find(w, 1, true) then return "failed", result end
    end
    return "uncertain", result
  end

  local function command(label, cmd, beat, at_us, t_us)
    local outcome, feedback = run_cmd(cmd)
    local timing = at_us and string.format(" (%+.1f ms)", (t_us - at_us) / 1000) or ""
    status.last_action = string.format("%s: %s%s%s%s", label, cmd, beat and (" at beat " .. beat // 1000000) or "",
      timing, outcome == "ok" and "" or (" " .. outcome .. ": " .. feedback))
    if outcome == "failed" then
      report("errors", label .. " failed: " .. feedback)
      status.last_error = label .. " failed: " .. feedback
    elseif outcome == "uncertain" then
      report("warnings", label .. ": unexpected answer: " .. feedback)
    end
  end

  -- Sets the speed master to bpm. Returns true when the write was accepted (or answered with something unexpected,
  -- which is reported and not retried), false when the console refused it.
  local function write_tempo(bpm)
    local m = config.master_handle
    -- A speed master's base tempo stops at 225 BPM (BS-01); raise its SpeedScale for faster sessions.
    -- "At BPM" sets the effective tempo whatever the scale (gma3-mcp SB-06).
    local factor = 1
    while bpm / factor > 225 and factor < 8 do factor = factor * 2 end
    if factor > 1 then
      local scale = "Mul" .. factor
      -- the property reads as an enum index (0 = One, 1 = Mul2); its name comes from the Display role
      local function current() local okg, v = pcall(function() return m:Get("SpeedScale", Enums.Roles.Display) end)
        return okg and tostring(v) or nil end
      if current() ~= scale then
        local oks, e = pcall(function() m:Set("SpeedScale", scale) end)
        if not oks or current() ~= scale then
          local why = "SpeedScale of speed master " .. config.master .. " could not be set to " .. scale
            .. (oks and "" or (": " .. tostring(e)))
          report("errors", why)
          status.last_error = why
          return false
        end
      end
    end
    local cmd = string.format("Master 3.%d At BPM %.4f", config.master, bpm)
    local outcome, feedback = run_cmd(cmd)
    if outcome == "failed" then
      local why = "speed master write refused: " .. cmd .. ": " .. feedback
      report("errors", why)
      status.last_error = why
      return false
    elseif outcome == "uncertain" then
      report("warnings", "speed master write: unexpected answer: " .. feedback)
    end
    return true
  end

  -- Keeps the speed master on the session's tempo: written when it was never written for this master, when the
  -- tempo moved by the threshold, after a show load or a join. A refused write is tried again after 1 s.
  local function reconcile_tempo(now)
    if not config.master_handle then return end
    local pos = follower:position(now)
    if not pos or now < tempo_retry_us then return end
    local w = tempo_written
    if w and w.master == config.master and math.abs(pos.bpm - w.bpm) < config.threshold then return end
    if write_tempo(pos.bpm) then
      tempo_written = { master = config.master, bpm = pos.bpm }
      tempo_settle_us = now + 500000 -- the fader moves a frame or two later; ignore it until then
    else
      tempo_written, tempo_retry_us = nil, now + 1000000
    end
  end

  local function handle(ev, t_us)
    if ev.kind == "joined" then
      report("warnings", "joined session " .. P.hex(ev.session_id))
      tempo_written = nil
      if config.OnJoin ~= "" then command("OnJoin", config.OnJoin) end
    elseif ev.kind == "left" then
      report("warnings", "left session " .. P.hex(ev.session_id))
      if config.OnLeave ~= "" then command("OnLeave", config.OnLeave) end
    elseif ev.kind == "tempo" then
      -- the speed master is reconciled every frame (reconcile_tempo)
    elseif ev.kind == "start" then
      if config.OnStart ~= "" then command("OnStart", config.OnStart) end
    elseif ev.kind == "stop" then
      if config.OnStop ~= "" then command("OnStop", config.OnStop) end
    elseif ev.kind == "beat" then
      local k = ev.beat // 1000000
      if ev.bar then
        for _, n in ipairs(config.resync) do command("Resync", "ReSync Sequence " .. n, ev.beat, ev.at_us, t_us) end
        if config.OnBar ~= "" then command("OnBar", config.OnBar, ev.beat, ev.at_us, t_us) end
      end
      if config.OnBeat ~= "" then command("OnBeat", config.OnBeat, ev.beat, ev.at_us, t_us) end
      for _, a in ipairs(config.actions) do
        if (k - a.phase) % a.every == 0 then command(a.label, a.command, ev.beat, ev.at_us, t_us) end
      end
    end
  end

  -- Writes the status variables; final_state ("stopped", "error") replaces the follower's state on the way out.
  local function publish(now, final_state)
    local s = follower:status(now)
    status.state = final_state
      or (#status.problems > 0 and s.state == "no session" and "no session (configuration problems)" or s.state)
    status.peers, status.sessions, status.session = s.peers, s.sessions, s.session
    status.tempo, status.beat, status.phase, status.playing = s.bpm, s.beat, s.phase, s.playing
    status.drift_ms_per_min = s.drift_us_per_min and s.drift_us_per_min / 1000 or nil
    status.counters = s.counters
    local med, p90 = median_and_p90(frame_periods)
    status.frame_ms = med and med / 1000
    status.frame_jitter_ms = med and (p90 - med) / 1000
    status.dropped_frames = dropped
    status.updated = os.date("!%Y-%m-%dT%H:%M:%SZ")
    setvar("State", status.state)
    setvar("Peers", tostring(s.peers))
    setvar("Session", s.session or "")
    setvar("Tempo", fmt(s.bpm, 3))
    setvar("Beat", fmt(s.beat, 2))
    setvar("Phase", fmt(s.phase, 2))
    setvar("Playing", s.playing == nil and "" or (s.playing and "yes" or "no"))
    setvar("LastAction", status.last_action or "")
    setvar("DriftMsPerMin", fmt(status.drift_ms_per_min, 3))
    setvar("FrameMs", fmt(status.frame_ms, 1))
    setvar("FrameJitterMs", fmt(status.frame_jitter_ms, 1))
    setvar("DroppedFrames", tostring(dropped))
    setvar("MissedBeats", tostring(s.counters.missed_beats or 0))
    setvar("Problems", table.concat(status.problems, "; "))
    setvar("Error", status.last_error or "")
    setvar("ActiveMode", status.mode) -- not "Mode": that is the configuration, which this would overwrite
    setvar("Node", status.node or "")
    setvar("OwnSession", s.own_session == nil and "" or (s.own_session and "yes" or "no"))
    setvar("Version", VERSION)
    setvar("Updated", status.updated)
  end

  local ping_bound, next_announce_us, last_announce_us, announce_now, last_session = now_us(), 0, 0, true, nil
  local sender_for
  -- the sender whose network a peer's address is on: loopback for 127.x, otherwise the first other address
  sender_for = function(ip)
    local loop = ip:match("^127%.") ~= nil
    for _, sd in ipairs(senders) do
      if (sd.address:match("^127%.") ~= nil) == loop then return sd end
    end
    return senders[1]
  end

  local function frame()
    local now = now_us()
    local period = now - last_frame_us
    last_frame_us = now
    frames = frames + 1
    if frames > 1 then
      frame_periods[#frame_periods + 1] = period
      if #frame_periods > FRAME_WINDOW then table.remove(frame_periods, 1) end
      local med = median_and_p90(frame_periods)
      if #frame_periods >= 30 and period > 1.5 * med then
        dropped = dropped + 1
        status.last_dropped = string.format("frame of %.1f ms (median %.1f)", period / 1000, med / 1000)
      end
    end

    if frames % CONFIG_EVERY == 0 then
      local sf = Root().ManetSocket and Root().ManetSocket.Showfile
      if sf ~= showfile then
        report("warnings", "show loaded: " .. tostring(sf))
        showfile, status.show = sf, sf
        tempo_written = nil
      end
      config, status.problems = read_config()
      follower:set_quantum(config.quantum)
    end

    for _ = 1, MAX_PACKETS do
      local d, ip, port = mc:receivefrom()
      if not d then break end
      local m = follower:discovery(d, now_us())
      -- discovery/UdpMessenger.hpp: an Alive is answered with a Response to its sender
      if peer and m and m.type == P.ALIVE and ip then
        local sd = sender_for(ip)
        if sd then sd.sock:sendto(follower:announcement(P.RESPONSE, sd.address, mep_port), ip, port) end
      end
    end
    -- The measurement socket carries pongs for this console's measurements and, in peer mode, pings from peers
    -- measuring the session through it; a ping is answered with a compensated ghost time (answer_ping).
    local function on_uc(d, ip, port, bound)
      local kind = d:byte(9)
      if peer and kind == P.PING then
        local pong = follower:answer_ping(d, bound, now_us())
        if pong then uc:sendto(pong, ip, port) end
        return now_us()
      end
      follower:pong(d, now_us())
      return bound
    end
    uc:settimeout(0)
    for _ = 1, MAX_PACKETS do
      local d, ip, port = uc:receivefrom()
      if not d then break end
      ping_bound = on_uc(d, ip, port, ping_bound)
    end
    -- Measurement exchanges: send a ping, wait up to 3 ms for its pong, within the frame's budget.
    local start, n = now_us(), 0
    uc:settimeout(0.003)
    while n < MAX_EXCHANGES_PER_FRAME and now_us() - start < MEASURE_BUDGET_US do
      local ping = follower:next_ping(now_us())
      if not ping then break end
      uc:sendto(ping.data, ping.address, ping.port)
      n = n + 1
      local waited = now_us()
      local d, ip, port = uc:receivefrom()
      if not d then break end
      ping_bound = on_uc(d, ip, port, math.max(ping_bound, waited))
    end
    uc:settimeout(0)
    ping_bound = now_us() -- a ping read from the next frame on cannot have arrived before this look

    if peer then
      -- the operator moved the speed master (not this plugin): propose the tempo to the session (TEMPO-1)
      local t0 = now_us()
      if frames % 3 == 0 and config.master_handle and tempo_written and tempo_written.master == config.master
          and t0 >= tempo_settle_us then
        local mb = master_bpm(config.master_handle)
        if mb and math.abs(mb - tempo_written.bpm) >= config.threshold then
          tempo_moves = tempo_moves + 1
          if tempo_moves >= 2 and follower:propose_tempo(mb, t0) then
            local proposed = follower:position(t0)
            tempo_written = { master = config.master, bpm = proposed and proposed.bpm or mb }
            report("warnings", string.format("tempo %.3f proposed to the session", tempo_written.bpm))
            announce_now = true
            tempo_moves = 0
          end
        else
          tempo_moves = 0
        end
      end
      -- play / pause from the plugin's commands (STARTSTOPSTATE-2)
      if control.transport ~= nil then
        follower:propose_start_stop(control.transport, t0)
        report("warnings", control.transport and "start proposed to the session" or "stop proposed to the session")
        control.transport = nil
        announce_now = true
      end
      if follower.current ~= last_session then announce_now, last_session = true, follower.current end
      -- announcements: every 250 ms, and at once (at most every 50 ms) after a change (discovery/UdpMessenger.hpp)
      if t0 >= next_announce_us or (announce_now and t0 - last_announce_us >= 50000) then
        for _, sd in ipairs(senders) do
          sd.sock:sendto(follower:announcement(P.ALIVE, sd.address, mep_port), P.MULTICAST_ADDRESS, P.PORT)
        end
        last_announce_us, next_announce_us, announce_now = t0, t0 + P.BROADCAST_PERIOD_US, false
      end
    end

    local med = median_and_p90(frame_periods)
    local t = now_us()
    for _, ev in ipairs(follower:frame(t, med or 16667, { lead_us = config.lead_us, always = not config.start_stop })) do
      handle(ev, t + config.lead_us)
    end
    reconcile_tempo(now_us())

    if frames % STATUS_EVERY == 0 then publish(now_us()) end
  end

  running = true
  Printf("gma3_beat_sync %s: following (joined on %s)", VERSION, table.concat(status.joined, ", "))
  publish(now_us())
  while not control.stop do
    local fok, ferr = pcall(frame)
    if fok then
      consecutive_errors = 0
    else
      consecutive_errors = consecutive_errors + 1
      status.last_error = tostring(ferr)
      report("errors", tostring(ferr))
      if consecutive_errors >= MAX_ERRORS then
        ErrPrintf("gma3_beat_sync: stopping after %d failing frames: %s", consecutive_errors, tostring(ferr))
        break
      end
    end
    coroutine.yield()
  end
  if peer then -- leave the session (discovery/UdpMessenger.hpp, sendByeBye)
    for _, sd in ipairs(senders) do pcall(function()
      sd.sock:sendto(follower:announcement(P.BYEBYE, sd.address, mep_port), P.MULTICAST_ADDRESS, P.PORT) end) end
  end
  close()
  running = false
  pcall(publish, now_us(), control.stop and "stopped" or "error")
  Printf("gma3_beat_sync: %s", status.state)
end

local function print_status()
  local s = shared.status
  if not s or not running then Printf("gma3_beat_sync %s: not running", VERSION) return end
  Printf("gma3_beat_sync %s: %s, %s peer(s), tempo %s, beat %s, playing %s", VERSION, tostring(s.state),
    tostring(s.peers), fmt(s.tempo, 2), fmt(s.beat, 2), tostring(s.playing))
  if s.problems and #s.problems > 0 then Printf("  problems: %s", table.concat(s.problems, "; ")) end
  if s.last_action then Printf("  last action: %s", s.last_action) end
  if s.last_error then Printf("  last error: %s", s.last_error) end
end

local function Main(_, argument)
  local arg = tostring(argument or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "stop" then
    if shared.control then shared.control.stop = true end
    return
  elseif arg == "status" then
    print_status()
    return
  elseif arg == "play" or arg == "pause" then
    -- peer mode: start or stop the session (a follower has no say in it)
    if not running or not shared.control then Printf("gma3_beat_sync: not running") return end
    if shared.status and shared.status.mode ~= "peer" then
      ErrPrintf('gma3_beat_sync: "%s" needs BeatSync.Mode "peer"', arg)
      return
    end
    shared.control.transport = arg == "play"
    return
  elseif arg ~= "" and arg ~= "start" then
    ErrPrintf('gma3_beat_sync: unknown argument "%s" (use start, stop, status, play or pause)', arg)
    return
  end
  if running then
    Printf("gma3_beat_sync: already running")
    return
  end
  run()
end

local function Cleanup() end

-- This chunk runs at import and again on every show load, and a show load ends a running loop. Neither a
-- CmdIndirect nor a Timer issued here takes effect (BS-02 record), so the plugin cannot restart itself; it marks
-- the shared status, and the State saved with the show, as not running.
if type(signalTable) == "table" then
  if shared.status and shared.status.state ~= "stopped" then shared.status.state = "not running" end
  shared.control = nil
  local ok_get, state = pcall(getvar, "State")
  if ok_get and state and state ~= "stopped" and state ~= "not running" then pcall(setvar, "State", "not running") end
end

return Main, Cleanup
