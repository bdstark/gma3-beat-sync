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
--
-- Peer mode (BS-03): F.new(P, { peer = { node_id = <8 bytes>, now_us = t, bpm = b } }) also takes part in Link as a
-- full peer: it founds its own session (tempo b), which other peers can join, and it may join theirs by Link's rule;
-- f:announcement(type, address, port) builds its Alive, Response or ByeBye; f:answer_ping(data, bound_us, now_us)
-- builds the pong for a measurement ping; f:propose_tempo(bpm, now_us) and f:propose_start_stop(playing, now_us)
-- change the session as a Link app's user would.

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

-- Bounds on what the network can make the follower keep and do. The tables are capped, so pruning, choosing and
-- status stay bounded however many identities appear. When a table is full, the entry seen longest ago is evicted,
-- except the followed session, the one being measured and their peers; when only those are left, the newcomer is
-- dropped (counters.dropped).
local MAX_PEERS = 64
local MAX_SESSIONS = 16
local MAX_TTL_US = 30000000 -- a peer's announced ttl (up to 255 s) is honoured up to 30 s; Link's own is 5 s
-- A measurement fails after 5 timeouts (link/Measurement.hpp), and also after 20 paired pongs that brought no data
-- points, 300 pings, or 2 s, so one session cannot hold the measurement forever.
local MAX_UNUSABLE = 20
local MAX_ATTEMPTS = 300
local MEASURE_DEADLINE_US = 2000000
-- A session whose measurement failed is tried again after 1 s, then 2, 4 ... up to 30 s, while it is announced.
local RETRY_FIRST_US, RETRY_MAX_US = 1000000, 30000000
-- Values a session's timeline and start/stop state may hold. Link's tempo range is 20 to 999 bpm
-- (link/ClientSessionTimelines.hpp, clampTempo), which a peer sends as llround(60e6 / bpm) micros per beat
-- (link/Tempo.hpp): 60060 to 3000000. Beats and times are kept within 2^53 so the arithmetic stays exact.
local MIN_MPB, MAX_MPB = 60060, 3000000
local MAX_ABS = 2 ^ 53
F.MAX_PEERS, F.MAX_SESSIONS = MAX_PEERS, MAX_SESSIONS

function F.new(P, opts)
  opts = opts or {}
  local self = setmetatable({}, Follower)
  self.P = P
  self.quantum = P.llround((opts.quantum or 4) * 1e6) -- micro-beats
  self.peers = {}      -- node id -> { node_id, session_id, timeline, start_stop, mep4, seen_us, ttl_us }
  self.n_peers = 0
  self.sessions = {}   -- session id -> { timeline, start_stop, xform, measured_us, seen_us, failed, retry_us, backoff_us }
  self.n_sessions = 0
  self.current = nil   -- the session followed
  self.measuring = nil -- { session_id, endpoint, points, prev_ghost, sent_us, timeouts, unusable, attempts, started_us }
  self.counters = { packets = 0, rejected = 0, invalid_timelines = 0, pongs = 0, unpaired_pongs = 0,
    measurements = 0, failed = 0, retries = 0, evicted_peers = 0, evicted_sessions = 0 }
  self.last = {}       -- state seen by the previous frame()
  if opts.peer then
    -- link/Controller.hpp: a new node founds its own session, its node id is the session id, and its ghost time
    -- starts at 0 (initXForm: intercept = -now); the timeline starts at beat 0 at ghost time 0 (initSessionState)
    local pr = opts.peer
    self.peer_mode, self.node_id = true, pr.node_id
    local mpb = P.micros_per_beat(P.clamp_bpm(pr.bpm or 120))
    self.sessions[pr.node_id] = { own = true, seen_us = pr.now_us,
      timeline = { micros_per_beat = mpb, beat_origin = 0, time_origin = 0 },
      start_stop = { playing = false, beats = 0, timestamp = 0 },
      xform = { slope = 1.0, intercept = -pr.now_us }, measured_us = pr.now_us }
    self.n_sessions = 1
    self.current = pr.node_id
  end
  return self
end

------------------------------------------------------------------------------------------------------------------
-- Packets

-- Compared against both bounds directly: math.abs(math.mininteger) is still negative in Lua.
local function in_range(v) return v >= -MAX_ABS and v <= MAX_ABS end

local function valid_timeline(tl)
  return math.type(tl.micros_per_beat) == "integer" and tl.micros_per_beat >= MIN_MPB and tl.micros_per_beat <= MAX_MPB
    and in_range(tl.beat_origin) and in_range(tl.time_origin)
end

local function valid_start_stop(ss)
  return ss == nil or (in_range(ss.beats) and in_range(ss.timestamp))
end
F.valid_start_stop = valid_start_stop
F.valid_timeline = valid_timeline

-- Removes the entry of `tbl` seen longest ago among those `protected` does not keep; returns its key, or nil when
-- every entry is protected.
local function evict_oldest(tbl, protected)
  local oldest, key
  for k, v in pairs(tbl) do
    if not protected(k, v) and (not oldest or v.seen_us < oldest) then oldest, key = v.seen_us, k end
  end
  if key then tbl[key] = nil end
  return key
end

function Follower:remove_peer(id)
  if self.peers[id] then
    self.peers[id] = nil
    self.n_peers = self.n_peers - 1
  end
end

function Follower:remove_session(id)
  if self.sessions[id] then
    self.sessions[id] = nil
    self.n_sessions = self.n_sessions - 1
  end
end

-- discovery/UdpMessenger.hpp and discovery/PeerGateway.hpp: Alive and Response update a peer, ByeBye removes it. A
-- message whose timeline or start/stop state is out of range is rejected: the last valid state stays.
function Follower:discovery(data, now_us)
  local P = self.P
  self.counters.packets = self.counters.packets + 1
  local m = P.decode_discovery(data)
  if not m then
    self.counters.rejected = self.counters.rejected + 1
    return
  end
  if self.peer_mode and m.node_id == self.node_id then return end -- discovery/UdpMessenger.hpp ignores itself
  if m.type == P.BYEBYE then
    self:remove_peer(m.node_id)
    return m
  end
  if not (m.session_id and m.timeline) then
    self.counters.rejected = self.counters.rejected + 1
    return
  end
  if not (valid_timeline(m.timeline) and valid_start_stop(m.start_stop)) then
    self.counters.rejected = self.counters.rejected + 1
    self.counters.invalid_timelines = self.counters.invalid_timelines + 1
    return
  end

  local s = self.sessions[m.session_id]
  if not s then
    if self.n_sessions >= MAX_SESSIONS then
      -- the followed session and the one being measured are never evicted
      local measuring = self.measuring and self.measuring.session_id
      if not evict_oldest(self.sessions, function(k) return k == self.current or k == measuring end) then
        self.counters.dropped = (self.counters.dropped or 0) + 1
        return
      end
      self.n_sessions = self.n_sessions - 1
      self.counters.evicted_sessions = self.counters.evicted_sessions + 1
    end
    s = { timeline = m.timeline }
    self.sessions[m.session_id] = s
    self.n_sessions = self.n_sessions + 1
  elseif m.timeline.beat_origin > s.timeline.beat_origin then
    s.timeline = m.timeline -- link/Sessions.hpp, updateTimeline: the larger beat origin wins
    if m.session_id == self.current then self.timeline_changed = true end
  end
  s.seen_us = now_us
  -- link/Controller.hpp, handleStartStopStateFromSession: a newer timestamp wins (and, for a peer that joined this
  -- session, only a state newer than any it knew when it joined: see Follower:join)
  if m.start_stop and (not s.start_stop or m.start_stop.timestamp > s.start_stop.timestamp)
    and (not s.ss_floor or m.start_stop.timestamp > s.ss_floor) then
    s.start_stop = m.start_stop
  end

  local peer = self.peers[m.node_id]
  if not peer then
    if self.n_peers >= MAX_PEERS then
      -- peers of the followed session (and of the one being measured) are never evicted for newcomers
      local measuring = self.measuring and self.measuring.session_id
      if not evict_oldest(self.peers, function(_, p) return p.session_id == self.current or p.session_id == measuring end) then
        self.counters.dropped = (self.counters.dropped or 0) + 1
        return
      end
      self.n_peers = self.n_peers - 1
      self.counters.evicted_peers = self.counters.evicted_peers + 1
    end
    peer = { node_id = m.node_id }
    self.peers[m.node_id] = peer
    self.n_peers = self.n_peers + 1
  end
  peer.session_id, peer.timeline, peer.start_stop = m.session_id, m.timeline, m.start_stop
  peer.mep4 = m.mep4 or peer.mep4
  peer.seen_us, peer.ttl_us = now_us, math.min(m.ttl * 1000000, MAX_TTL_US)
  return m
end

-- Drops peers whose ttl has passed (discovery/PeerGateway.hpp, the prune timer) and sessions without peers. When
-- the followed session goes, the follower moves to the best surviving measured session at once.
function Follower:prune(now_us)
  local alive = {}
  for id, p in pairs(self.peers) do
    if now_us - p.seen_us > p.ttl_us then self:remove_peer(id) else alive[p.session_id] = true end
  end
  for id in pairs(self.sessions) do
    -- a peer is a member of its current session, so that session stays even without other peers
    if not alive[id] and not (self.peer_mode and id == self.current) then self:remove_session(id) end
  end
  if self.measuring and not self.sessions[self.measuring.session_id] then self.measuring = nil end
  if self.current and not self.sessions[self.current] then
    self.current = nil
    for id, s in pairs(self.sessions) do
      if s.xform then self:choose_session(id, now_us) end
    end
  end
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

-- The session that needs a measurement next: one never measured (a failed one once its retry time has come), or
-- the current one after 30 s. Only sessions with a peer that announces an IPv4 measurement endpoint are candidates,
-- so a session that cannot be measured never blocks the others; it becomes a candidate when such a peer appears.
function Follower:session_to_measure(now_us)
  local measurable = {}
  for _, p in pairs(self.peers) do
    if p.mep4 then measurable[p.session_id] = true end
  end
  local pick
  for id, s in pairs(self.sessions) do
    if measurable[id] and not s.own and not s.xform and (not s.failed or now_us >= s.retry_us) and (not pick or id < pick) then
      pick = id
    end
  end
  if pick then
    if self.sessions[pick].failed then self.counters.retries = self.counters.retries + 1 end
    return pick
  end
  local cur = self.current and self.sessions[self.current]
  if cur and not cur.own and measurable[self.current] and cur.measured_us and now_us - cur.measured_us >= REMEASURE_US then
    return self.current
  end
  return nil
end

-- The next ping to send, or nil. A ping that got no paired pong within 50 ms counts as a timeout; the measurement
-- fails after 5 timeouts, 20 paired pongs without data points, 300 pings or 2 s.
function Follower:next_ping(now_us)
  local P = self.P
  local m = self.measuring
  if m and m.sent_us then
    if now_us - m.sent_us < P.MEASUREMENT_TIMEOUT_US then return nil end
    m.timeouts = m.timeouts + 1
    m.sent_us = nil
  end
  if m and (m.timeouts >= P.MEASUREMENT_RETRIES or m.unusable >= MAX_UNUSABLE or m.attempts >= MAX_ATTEMPTS
      or now_us - m.started_us > MEASURE_DEADLINE_US) then
    self:finish_measurement(now_us, nil)
    m = nil
  end
  if not m then
    local id = self:session_to_measure(now_us)
    if not id then return nil end
    local peer = self:measurement_peer(id)
    if not peer then return nil end
    m = { session_id = id, endpoint = peer.mep4, points = {}, timeouts = 0, unusable = 0, attempts = 0,
      started_us = now_us }
    self.measuring = m
  end
  m.sent_us = now_us
  m.attempts = m.attempts + 1
  return { data = P.encode_ping(now_us, m.prev_ghost), address = m.endpoint.address, port = m.endpoint.port }
end

-- A packet on the measurement socket. Only a pong of the session being measured that echoes the last ping's host
-- time counts: a late pong of an earlier ping would skew the points (BS-04 saw a 15.9 ms receive). A paired pong
-- that brings no data points counts towards failing the measurement.
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
  local got = P.measurement_points(pong, now_us)
  if #got == 0 then m.unusable = m.unusable + 1 end
  for _, p in ipairs(got) do m.points[#m.points + 1] = p end
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
    s.xform, s.measured_us, s.failed, s.retry_us, s.backoff_us = xform, now_us, nil, nil, nil
    self.counters.measurements = self.counters.measurements + 1
    self:choose_session(m.session_id, now_us)
  else
    self.counters.failed = self.counters.failed + 1
    if s.xform then
      s.measured_us = now_us -- keep following on the old transform; retry after the re-measure interval
    else
      -- link/Sessions.hpp forgets a failed session until it is seen again; here it is retried while it is
      -- announced, after a growing pause
      s.backoff_us = math.min((s.backoff_us or RETRY_FIRST_US // 2) * 2, RETRY_MAX_US)
      s.failed, s.retry_us = true, now_us + s.backoff_us
    end
  end
end

-- Makes session id the current one. A peer does what link/Controller.hpp (joinSession) does on joining a different
-- session: it resets its start/stop state ("Prevent passing the state of the previous session to the new one"). The
-- members' existing state is then not taken over, as link/Peers.hpp passes on only a state no member had before, so
-- a peer that joins a playing session is not playing until a member starts or stops again (STARTSTOPSTATE-2). The
-- follower (not a Link app) keeps reporting the session's state as it is.
function Follower:join(id)
  if self.peer_mode and id ~= self.current then
    local s = self.sessions[id]
    s.ss_floor = s.start_stop and s.start_stop.timestamp or nil
    s.start_stop = { playing = false, beats = 0, timestamp = 0 }
  end
  self.current = id
end

-- link/Sessions.hpp, handleSuccessfulMeasurement: switch to a newly measured session when its ghost time is ahead
-- by more than 500 ms, or within 500 ms when its id is smaller.
function Follower:choose_session(id, now_us)
  local P = self.P
  if not self.current or not self.sessions[self.current] or not self.sessions[self.current].xform then
    self:join(id)
    return
  end
  if id == self.current then return end
  local cur = self.sessions[self.current].xform
  local new = self.sessions[id].xform
  local diff = P.host_to_ghost(new, now_us) - P.host_to_ghost(cur, now_us)
  if diff > SESSION_EPS_US or (math.abs(diff) < SESSION_EPS_US and id < self.current) then self:join(id) end
end

------------------------------------------------------------------------------------------------------------------
-- Peer mode (BS-03)

local function entry(key, value) return string.pack(">I4I4", key, #value) .. value end

-- The node's Alive (1), Response (2) or ByeBye (3): discovery/v1/Messages.hpp header, then the payload of
-- link/PeerState.hpp: tmln, sess and stst of the current session, and the IPv4 measurement endpoint for the interface
-- the message goes out on.
function Follower:announcement(mtype, address, port)
  local P = self.P
  local head = "_asdp_v\1" .. string.pack(">I1I1I2", mtype, mtype == P.BYEBYE and 0 or P.DEFAULT_TTL_S, 0) .. self.node_id
  if mtype == P.BYEBYE then return head end
  local s = self.sessions[self.current]
  local tl, ss = s.timeline, s.start_stop or { playing = false, beats = 0, timestamp = 0 }
  local a, b, c, d = address:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  return head
    .. entry(P.KEY.tmln, string.pack(">i8i8i8", P.effective_micros_per_beat(tl), tl.beat_origin, tl.time_origin))
    .. entry(P.KEY.sess, self.current)
    .. entry(P.KEY.stst, string.pack(">I1i8i8", ss.playing and 1 or 0, ss.beats, ss.timestamp))
    .. entry(P.KEY.mep4, string.pack(">I1I1I1I1I2", tonumber(a), tonumber(b), tonumber(c), tonumber(d), port))
end

-- The pong for a measurement ping (link/PingResponder.hpp: session id, ghost time, then the ping's payload), or nil
-- when Link would not answer it. The ghost time is not taken at the reply: a plugin answers once per frame, so the
-- ping has waited since bound_us (the earliest it can have arrived: the end of the previous look at the socket, or
-- the previous reply); the stamp is half way between, where the measuring peer assumes it is (link/Measurement.hpp).
-- The BS-03 probe measured 8 ms of error without this and under 0.2 ms with it.
function Follower:answer_ping(data, bound_us, now_us)
  local P = self.P
  local m = P.decode_measurement(data)
  if not (m and m.type == P.PING and m.answered) then return nil end
  local s = self.sessions[self.current]
  local stamp = P.llround((math.min(bound_us, now_us) + now_us) / 2)
  self.counters.pings_answered = (self.counters.pings_answered or 0) + 1
  return "_link_v\1\2" .. entry(P.KEY.sess, self.current)
    .. entry(P.KEY.gt, string.pack(">i8", P.host_to_ghost(s.xform, stamp))) .. data:sub(10)
end

-- A tempo change from this node, as link/ClientSessionTimelines.hpp (updateSessionTimelineFromClient) makes one: the
-- beat at now stays where it is, the new timeline starts there at the new tempo, and its beat origin is larger than
-- the old one, so the other peers adopt it (link/Sessions.hpp).
function Follower:propose_tempo(bpm, now_us)
  local P = self.P
  local s = self.sessions[self.current]
  if not s then return false end
  local ghost = P.host_to_ghost(s.xform, now_us)
  local beat = P.to_beats(s.timeline, ghost)
  local origin = math.max(beat, s.timeline.beat_origin + 1)
  local mpb = P.micros_per_beat(P.clamp_bpm(bpm))
  local tl = { micros_per_beat = mpb, beat_origin = origin, time_origin = ghost }
  tl.time_origin = ghost - (P.from_beats(tl, beat) - ghost) -- keep the beat at now: origin beats lie after now when bumped
  if not valid_timeline(tl) then return false end
  s.timeline = tl
  self.timeline_changed = true
  self.counters.tempo_proposals = (self.counters.tempo_proposals or 0) + 1
  return true
end

-- A start or a stop from this node (link/StartStopState.hpp, as Link's setIsPlaying with a requested beat does it): a
-- start begins on the next bar of the session's grid, a stop at once; the newer timestamp makes the other peers adopt it.
function Follower:propose_start_stop(playing, now_us)
  local P = self.P
  local s = self.sessions[self.current]
  if not s then return false end
  local ghost = P.host_to_ghost(s.xform, now_us)
  local beat = P.to_beats(s.timeline, ghost)
  local at = playing and P.next_phase_match(beat, 0, self.quantum) or beat
  local old = s.start_stop
  s.start_stop = { playing = playing, beats = at, timestamp = math.max(ghost, old and old.timestamp + 1 or ghost) }
  self.counters.start_stop_proposals = (self.counters.start_stop_proposals or 0) + 1
  return true
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
  local n_peers, n_sessions, failed = self.n_peers, self.n_sessions, 0
  for _, s in pairs(self.sessions) do if s.failed then failed = failed + 1 end end
  local pos = self:position(now_us)
  local own_session = nil -- not "a and b or nil": that turns false into nil
  if self.peer_mode and pos then own_session = self.current == self.node_id end
  return {
    state = pos and "following" or (n_peers > 0 and "measuring" or "no session"),
    peers = n_peers,
    sessions = n_sessions,
    failed_sessions = failed, -- announced sessions whose measurement failed and is being retried
    own_session = own_session, -- peer mode: true in the session it founded, false in another; nil when following
    session = pos and self.P.hex(pos.session_id) or nil,
    bpm = pos and pos.bpm or nil,
    beat = pos and pos.beat / 1e6 or nil,
    phase = pos and pos.phase / 1e6 or nil,
    playing = pos and pos.playing, -- false when stopped, nil without a session (not "pos and x or nil")
    drift_us_per_min = pos and self.sessions[self.current].drift_us_per_min or nil,
    ghost_intercept_us = pos and self.sessions[self.current].xform.intercept or nil, -- ghost = host + this (slope 1)
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
