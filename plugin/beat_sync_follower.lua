-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- beat_sync_follower: follows a Link session from packets and a clock, with no console and no sockets, so the
-- harness can drive it with fixtures and a simulated clock. The console plugin feeds it packets and frames and
-- carries out what it asks for (pings to send, actions to run).
--
-- Written from Ableton's Link source (GPL-2.0-or-later, Copyright 2016, Ableton AG) at the tag pinned in
-- modules/link; paths are relative to modules/link/include/ableton. It follows without announcing itself: other
-- peers do not see it, and it never changes the session.
--
-- Usage:
--   local F = dofile("plugin/beat_sync_follower.lua")
--   local f = F.new(P, { quantum = 4 })          -- P is beat_sync_protocol
--   f:discovery(bytes, now_us)                     -- each packet from 224.76.78.75:20808
--   local ping = f:next_ping(now_us)               -- { data, address, port } while measuring, else nil
--   f:pong(bytes, now_us)                          -- each packet on the measurement socket
--   local events = f:frame(now_us, frame_us)       -- once per console frame; see frame()
--   f:status(now_us)                               -- a table for publishing

local F = {}
F.VERSION = "0.1.0"

local Follower = {}
Follower.__index = Follower

-- link/Sessions.hpp: SESSION_EPS (500 ms) in handleSuccessfulMeasurement; re-measure every 30 s
local SESSION_EPS_US = 500000
local REMEASURE_US = 30000000
-- A start's first beat still runs when the follower learns of the start up to this late. Peers announce at most every
-- 50 ms (discovery/UdpMessenger.hpp, broadcastState), and a peer alone in its session starts at once, so the news
-- of a start can arrive a few tens of ms after its first beat.
local START_GRACE_US = 100000
F.START_GRACE_US = START_GRACE_US

function F.new(P, opts)
  opts = opts or {}
  local self = setmetatable({}, Follower)
  self.P = P
  self.quantum = P.llround((opts.quantum or 4) * 1e6) -- micro-beats
  self.peers = {}      -- node id -> { session_id, timeline, start_stop, mep4, seen_us, ttl_us }
  self.sessions = {}   -- session id -> { timeline, start_stop, xform, measured_us, failed }
  self.current = nil   -- the session followed
  self.measuring = nil -- { session_id, endpoint, points, prev_ghost, sent_us, timeouts }
  self.counters = { packets = 0, rejected = 0, pongs = 0, unpaired_pongs = 0, measurements = 0, failed = 0 }
  self.last = {}       -- state seen by the previous frame()
  return self
end

------------------------------------------------------------------------------------------------------------------
-- Packets

-- discovery/UdpMessenger.hpp and discovery/PeerGateway.hpp: Alive and Response update a peer, ByeBye removes it.
function Follower:discovery(data, now_us)
  local P = self.P
  self.counters.packets = self.counters.packets + 1
  local m = P.decode_discovery(data)
  if not m then
    self.counters.rejected = self.counters.rejected + 1
    return
  end
  if m.type == P.BYEBYE then
    self.peers[m.node_id] = nil
    return
  end
  if not (m.session_id and m.timeline) then
    self.counters.rejected = self.counters.rejected + 1
    return
  end
  local peer = self.peers[m.node_id] or {}
  peer.session_id, peer.timeline, peer.start_stop = m.session_id, m.timeline, m.start_stop
  peer.mep4 = m.mep4 or peer.mep4
  peer.seen_us, peer.ttl_us = now_us, m.ttl * 1000000
  self.peers[m.node_id] = peer
  self.peers[m.node_id].node_id = m.node_id

  local s = self.sessions[m.session_id]
  if not s then
    s = { timeline = m.timeline }
    self.sessions[m.session_id] = s
  elseif m.timeline.beat_origin > s.timeline.beat_origin then
    s.timeline = m.timeline -- link/Sessions.hpp, updateTimeline: the larger beat origin wins
    if m.session_id == self.current then self.timeline_changed = true end
  end
  -- link/Controller.hpp, handleStartStopStateFromSession: a newer timestamp wins
  if m.start_stop and (not s.start_stop or m.start_stop.timestamp > s.start_stop.timestamp) then
    s.start_stop = m.start_stop
  end
end

-- Drops peers whose ttl has passed (discovery/PeerGateway.hpp, the prune timer) and sessions without peers.
function Follower:prune(now_us)
  local alive = {}
  for id, p in pairs(self.peers) do
    if now_us - p.seen_us > p.ttl_us then self.peers[id] = nil else alive[p.session_id] = true end
  end
  for id in pairs(self.sessions) do
    if not alive[id] then self.sessions[id] = nil end
  end
  if self.measuring and not self.sessions[self.measuring.session_id] then self.measuring = nil end
  if self.current and not self.sessions[self.current] then self.current = nil end
end

------------------------------------------------------------------------------------------------------------------
-- Measurement (link/Measurement.hpp, link/MeasurementService.hpp, link/Sessions.hpp)

-- The peer to measure a session through: its founder if present (the session id is the founder's node id),
-- otherwise any peer with an IPv4 measurement endpoint (link/Sessions.hpp, launchSessionMeasurement).
function Follower:measurement_peer(session_id)
  local founder = self.peers[session_id]
  if founder and founder.session_id == session_id and founder.mep4 then return founder end
  local best
  for _, p in pairs(self.peers) do
    if p.session_id == session_id and p.mep4 and (not best or p.node_id < best.node_id) then best = p end
  end
  return best
end

-- The session that needs a measurement next: one never measured, or the current one after 30 s.
function Follower:session_to_measure(now_us)
  local pick
  for id, s in pairs(self.sessions) do
    if not s.xform and not s.failed and (not pick or id < pick) then pick = id end
  end
  if pick then return pick end
  local cur = self.current and self.sessions[self.current]
  if cur and cur.measured_us and now_us - cur.measured_us >= REMEASURE_US then return self.current end
  return nil
end

-- The next ping to send, or nil. A ping that got no paired pong within 50 ms counts as a timeout; after 5 the
-- measurement fails.
function Follower:next_ping(now_us)
  local P = self.P
  local m = self.measuring
  if m and m.sent_us then
    if now_us - m.sent_us < P.MEASUREMENT_TIMEOUT_US then return nil end
    m.timeouts = m.timeouts + 1
    m.sent_us = nil
    if m.timeouts >= P.MEASUREMENT_RETRIES then
      self:finish_measurement(now_us, nil)
      return nil
    end
  end
  if not m then
    local id = self:session_to_measure(now_us)
    if not id then return nil end
    local peer = self:measurement_peer(id)
    if not peer then return nil end
    m = { session_id = id, endpoint = peer.mep4, points = {}, timeouts = 0 }
    self.measuring = m
  end
  m.sent_us = now_us
  return { data = P.encode_ping(now_us, m.prev_ghost), address = m.endpoint.address, port = m.endpoint.port }
end

-- A packet on the measurement socket. Only a pong of the session being measured that echoes the last ping's host
-- time counts: a late pong of an earlier ping would skew the points (BS-04 saw a 15.9 ms receive).
function Follower:pong(data, now_us)
  local P = self.P
  local m = self.measuring
  local pong = P.decode_measurement(data)
  if not (pong and pong.type == P.PONG) then return end
  self.counters.pongs = self.counters.pongs + 1
  if not (m and m.sent_us and pong.session_id == m.session_id and pong.host == m.sent_us) then
    self.counters.unpaired_pongs = self.counters.unpaired_pongs + 1
    return
  end
  for _, p in ipairs(P.measurement_points(pong, now_us)) do m.points[#m.points + 1] = p end
  m.prev_ghost = pong.ghost
  m.sent_us = nil
  if #m.points > P.MEASUREMENT_POINTS then self:finish_measurement(now_us, P.ghost_xform(m.points)) end
end

function Follower:finish_measurement(now_us, xform)
  local m = self.measuring
  self.measuring = nil
  local s = m and self.sessions[m.session_id]
  if not s then return end
  if xform then
    -- The change of the ghost-host offset between measurements of the same session is the clock drift between
    -- this console and the session.
    if s.xform and s.measured_us and now_us > s.measured_us then
      s.drift_us_per_min = (xform.intercept - s.xform.intercept) / ((now_us - s.measured_us) / 60e6)
    end
    s.xform, s.measured_us, s.failed = xform, now_us, nil
    self.counters.measurements = self.counters.measurements + 1
    self:choose_session(m.session_id, now_us)
  else
    self.counters.failed = self.counters.failed + 1
    if m.session_id == self.current then
      s.measured_us = now_us -- keep following on the old transform; retry after the re-measure interval
    else
      s.failed = true -- link/Sessions.hpp: a failed other session is forgotten until seen again
    end
  end
end

-- link/Sessions.hpp, handleSuccessfulMeasurement: switch to a newly measured session when its ghost time is ahead
-- by more than 500 ms, or within 500 ms when its id is smaller.
function Follower:choose_session(id, now_us)
  local P = self.P
  if not self.current or not self.sessions[self.current] or not self.sessions[self.current].xform then
    self.current = id
    return
  end
  if id == self.current then return end
  local cur = self.sessions[self.current].xform
  local new = self.sessions[id].xform
  local diff = P.host_to_ghost(new, now_us) - P.host_to_ghost(cur, now_us)
  if diff > SESSION_EPS_US or (math.abs(diff) < SESSION_EPS_US and id < self.current) then self.current = id end
end

------------------------------------------------------------------------------------------------------------------
-- Frames

-- Whether the session plays at session beat b: link/StartStopState.hpp carries (isPlaying, beats, timestamp), and a
-- start requested with quantization takes effect at that beat (link/Controller.hpp maps it to the client as the
-- time of that beat, mapStartStopStateFromSessionToClient). A stop takes effect at once.
local function playing_at(ss, beat)
  return ss ~= nil and ss.playing and beat >= ss.beats
end

-- The session's beat, phase and tempo at host time t, or nil when no session is measured.
function Follower:position(t_us)
  local P = self.P
  local s = self.current and self.sessions[self.current]
  if not (s and s.xform) then return nil end
  local ghost = P.host_to_ghost(s.xform, t_us)
  local beat = P.to_beats(s.timeline, ghost)
  return {
    beat = beat,                                  -- micro-beats on the session timeline (beat 0 = grid origin)
    phase = P.phase(beat, self.quantum),          -- micro-beats into the bar
    bpm = P.clamp_bpm(P.bpm(s.timeline.micros_per_beat)),
    playing = playing_at(s.start_stop, beat),
    session_id = self.current,
  }
end

-- The host time of a session beat (micro-beats).
function Follower:time_of_beat(beat)
  local P = self.P
  local s = self.sessions[self.current]
  return P.ghost_to_host(s.xform, P.from_beats(s.timeline, beat))
end

function Follower:set_quantum(beats)
  local q = self.P.llround(beats * 1e6)
  if q > 0 and q ~= self.quantum then self.quantum = q end
end

-- Called once per console frame at host time now_us, with the expected frame period. Returns a list of events,
-- each { kind, ... }:
--   joined { session_id }, left { session_id }, tempo { bpm }, start, stop,
--   beat { beat, at_us, bar } for each beat nearest this frame: at_us is the beat's own host time, and the beat is
--   due when t - frame_us/2 < at_us <= t + frame_us/2, where t = now_us + opts.lead_us (default 0). A lead fires
--   events early, to make up for the time the console takes to apply a command. bar is true on a quantum boundary.
-- Beats are reported only while the session plays, unless opts.always is set. A start is reported on the frame
-- nearest the beat it takes effect at; when the follower learns of a start after its first beat (up to
-- START_GRACE_US late), that beat is reported at once with late = true. Beats that a late frame missed by more than
-- one frame are not reported but counted (counters.missed_beats).
function Follower:frame(now_us, frame_us, opts)
  opts = opts or {}
  local P = self.P
  self:prune(now_us)
  local events = {}
  local half = frame_us // 2
  local t = now_us + (opts.lead_us or 0)
  local pos = self:position(t)
  local last = self.last
  if pos and last.session_id ~= pos.session_id then
    if last.session_id then events[#events + 1] = { kind = "left", session_id = last.session_id } end
    events[#events + 1] = { kind = "joined", session_id = pos.session_id }
    last.next_beat, last.playing, last.beat_at_us = nil, false, nil
  elseif not pos and last.session_id then
    events[#events + 1] = { kind = "left", session_id = last.session_id }
  end
  if pos then
    local s = self.sessions[self.current]
    local playing = playing_at(s.start_stop, P.to_beats(s.timeline, P.host_to_ghost(s.xform, t + half)))
    pos.playing = playing
    if pos.bpm ~= last.bpm then events[#events + 1] = { kind = "tempo", bpm = pos.bpm } end
    local start_beat
    if playing ~= (last.playing or false) then
      events[#events + 1] = { kind = playing and "start" or "stop" }
      if playing then start_beat = -((-s.start_stop.beats) // 1000000) * 1000000 end -- the first whole beat
    end
    -- the first beat not yet reported: the next whole beat after the earliest time this frame covers. A new
    -- timeline (a tempo change, or a start that moved the beat grid) restarts the count, so the beats it skipped
    -- are not taken for missed ones.
    -- When the count restarts, it starts one frame back, so a beat that is already up to a frame late when the
    -- follower learns of it (a peer alone in its session starts at once, moving its grid so that the start beat is
    -- the moment play was pressed) is still reported, late; the duplicate check below keeps it from being reported
    -- twice.
    local next_beat = last.next_beat
    if self.timeline_changed then
      self.timeline_changed = nil
      self.counters.timeline_changes = (self.counters.timeline_changes or 0) + 1
      next_beat = nil
    end
    local from = P.to_beats(s.timeline, P.host_to_ghost(s.xform, t - half - frame_us))
    if not next_beat or next_beat > from + 64 * 1000000 then next_beat = (from // 1000000 + 1) * 1000000 end
    if start_beat then
      local at = self:time_of_beat(start_beat)
      if at <= t + half and at > t - START_GRACE_US and not (last.beat_at_us and at <= last.beat_at_us + half) then
        events[#events + 1] = { kind = "beat", beat = start_beat, at_us = at, bar = P.phase(start_beat, self.quantum) == 0,
          late = true }
        last.beat_at_us = at
        next_beat = start_beat + 1000000
      elseif at > t + half then
        next_beat = start_beat
      end
    end
    local guard = 0
    while guard < 64 do
      local at = self:time_of_beat(next_beat)
      if at > t + half then break end
      if at <= t - half - frame_us then
        self.counters.missed_beats = (self.counters.missed_beats or 0) + 1
      elseif last.beat_at_us and at <= last.beat_at_us + half then
        -- already reported under the previous timeline (a new timeline can move a beat by less than a frame)
      elseif opts.always or playing_at(s.start_stop, next_beat) then
        events[#events + 1] = { kind = "beat", beat = next_beat, at_us = at, bar = P.phase(next_beat, self.quantum) == 0 }
        last.beat_at_us = at
      end
      next_beat = next_beat + 1000000
      guard = guard + 1
    end
    last.next_beat = next_beat
  end
  last.session_id = pos and pos.session_id or nil
  last.bpm = pos and pos.bpm or nil
  last.playing = pos and pos.playing or false
  self.position_now = pos
  return events
end

function Follower:status(now_us)
  local n_peers, n_sessions = 0, 0
  for _ in pairs(self.peers) do n_peers = n_peers + 1 end
  for _ in pairs(self.sessions) do n_sessions = n_sessions + 1 end
  local pos = self:position(now_us)
  return {
    state = pos and "following" or (n_peers > 0 and "measuring" or "no session"),
    peers = n_peers,
    sessions = n_sessions,
    session = pos and self.P.hex(pos.session_id) or nil,
    bpm = pos and pos.bpm or nil,
    beat = pos and pos.beat / 1e6 or nil,
    phase = pos and pos.phase / 1e6 or nil,
    playing = pos and pos.playing, -- false when stopped, nil without a session (not "pos and x or nil")
    drift_us_per_min = pos and self.sessions[self.current].drift_us_per_min or nil,
    counters = self.counters,
  }
end

-- In the console this file is one of the plugin's components (plugin/gma3_beat_sync.xml). The console runs each
-- component with (plugin name, component name, signal table, handle); the signal table is shared by all of the
-- plugin's components, so the module registers itself there. Loaded with dofile() or load(source)(), there are no
-- arguments and it only returns the table.
local signal_table = select(3, ...)
if type(signal_table) == "table" then signal_table.beat_sync_follower = F end

return F
