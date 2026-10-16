-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- beat_sync_protocol: the Link network protocol and timeline arithmetic, in plain Lua 5.5.
--
-- Written from Ableton's Link source (GPL-2.0-or-later, Copyright 2016, Ableton AG) at the tag pinned in
-- modules/link. Each part cites the file it comes from; paths are relative to modules/link/include/ableton.
--
-- The module has no console dependency, reads no globals at load time and keeps no state, so the console plugin
-- and the stock-Lua harness (test/lua/protocol_test.lua) load the same file. Load it with dofile() or
-- load(source)(); it returns the module table.
--
-- Numbers: times are integer microseconds and beats are integer micro-beats, as on the wire (link/Beats.hpp,
-- discovery/NetworkByteStreamSerializable.hpp). Floating-point steps repeat Link's own operations in the same
-- order, so results match Link's bit for bit (checked against gbs-vectors output).

local M = {}

M.VERSION = "0.1.0"

-- discovery/IpInterface.hpp: multicastEndpointV4()
M.MULTICAST_ADDRESS = "224.76.78.75"
M.PORT = 20808

-- discovery/v1/Messages.hpp and link/v1/Messages.hpp: kMaxMessageSize. Link receives into a buffer of this size.
M.MAX_MESSAGE_SIZE = 512

-- discovery/v1/Messages.hpp: protocol header and message types
local DISCOVERY_HEADER = "_asdp_v\1"
M.ALIVE, M.RESPONSE, M.BYEBYE = 1, 2, 3
-- link/v1/Messages.hpp: protocol header and message types
local MEASUREMENT_HEADER = "_link_v\1"
M.PING, M.PONG = 1, 2

-- Payload entry keys, 4 bytes, big endian (the static_asserts next to each key in the Link source)
local KEY = {
  tmln = 0x746d6c6e, -- link/Timeline.hpp
  sess = 0x73657373, -- link/SessionId.hpp (SessionMembership)
  stst = 0x73747374, -- link/StartStopState.hpp
  mep4 = 0x6d657034, -- link/PeerState.hpp (MeasurementEndpointV4)
  mep6 = 0x6d657036, -- link/PeerState.hpp (MeasurementEndpointV6)
  aep4 = 0x61657034, -- link/PeerState.hpp (AudioEndpointV4)
  aep6 = 0x61657036, -- link/PeerState.hpp (AudioEndpointV6)
  ht = 0x5f5f6874, -- link/PayloadEntries.hpp (HostTime, "__ht")
  gt = 0x5f5f6774, -- link/PayloadEntries.hpp (GHostTime, "__gt")
  pgt = 0x5f706774, -- link/PayloadEntries.hpp (PrevGHostTime, "_pgt")
}
M.KEY = KEY

local unpack, pack, byte, sub, format = string.unpack, string.pack, string.byte, string.sub, string.format
local floor, tointeger = math.floor, math.tointeger

------------------------------------------------------------------------------------------------------------------
-- Value decoders. Each takes the entry's value bytes and returns the value, or nil when the size is wrong: Link's
-- parsePayload (discovery/Payload.hpp) throws when an entry's value does not consume exactly its size, and the
-- whole message is dropped.

-- link/NodeId.hpp: 8 bytes, read as a std::array (discovery/NetworkByteStreamSerializable.hpp,
-- Deserialize<std::array>): a shorter value fills the first bytes and leaves the rest zero; a longer one fails.
local function node_id(v)
  if #v > 8 then return nil end
  return v .. string.rep("\0", 8 - #v)
end

local function int64(v) -- discovery/NetworkByteStreamSerializable.hpp: std::chrono::microseconds as int64
  if #v ~= 8 then return nil end
  return (unpack(">i8", v))
end

local function timeline(v) -- link/Timeline.hpp: (Tempo as micros per beat, Beats as micro-beats, time origin)
  if #v ~= 24 then return nil end
  local mpb, bo, to = unpack(">i8i8i8", v)
  return { micros_per_beat = mpb, beat_origin = bo, time_origin = to }
end

local function start_stop(v) -- link/StartStopState.hpp: (bool as one byte, Beats, timestamp)
  if #v ~= 17 then return nil end
  local playing, beats, ts = unpack(">I1i8i8", v)
  return { playing = playing ~= 0, beats = beats, timestamp = ts }
end

local function endpoint_v4(v) -- link/EndpointV4.hpp: 4-byte address, 2-byte port
  if #v ~= 6 then return nil end
  local a, b, c, d, port = unpack(">I1I1I1I1I2", v)
  return { address = format("%d.%d.%d.%d", a, b, c, d), port = port }
end

local function endpoint_v6(v) -- link/EndpointV6.hpp: 16-byte address, 2-byte port
  if #v ~= 18 then return nil end
  return { address = sub(v, 1, 16), port = (unpack(">I2", v, 17)), v6 = true }
end

-- Walks the payload entries (discovery/Payload.hpp: parseByteStream). Each entry is a 4-byte key, a 4-byte size
-- and the value. Returns a table of decoded known entries (the last of duplicate keys wins, as Link's handlers
-- overwrite), or nil and a reason when Link would throw.
local function parse_entries(data, pos, decoders)
  local out = {}
  local n = #data
  while pos <= n do
    if n - pos + 1 < 8 then return nil, "truncated entry header" end
    local key, size = unpack(">I4I4", data, pos)
    pos = pos + 8
    if size > n - pos + 1 then return nil, "entry larger than message" end
    local d = decoders[key]
    if d then
      local value = d.decode(sub(data, pos, pos + size - 1))
      if value == nil then return nil, "bad " .. d.name .. " entry size " .. size end
      out[d.name] = value
    end
    pos = pos + size
  end
  return out
end

local DISCOVERY_ENTRIES = {
  [KEY.tmln] = { name = "timeline", decode = timeline },
  [KEY.sess] = { name = "session_id", decode = node_id },
  [KEY.stst] = { name = "start_stop", decode = start_stop },
  [KEY.mep4] = { name = "mep4", decode = endpoint_v4 },
  [KEY.mep6] = { name = "mep6", decode = endpoint_v6 },
  [KEY.aep4] = { name = "aep4", decode = endpoint_v4 },
  [KEY.aep6] = { name = "aep6", decode = endpoint_v6 },
}

local PONG_ENTRIES = {
  [KEY.sess] = { name = "session_id", decode = node_id },
  [KEY.gt] = { name = "ghost", decode = int64 },
  [KEY.pgt] = { name = "prev_ghost", decode = int64 },
  [KEY.ht] = { name = "host", decode = int64 },
}

------------------------------------------------------------------------------------------------------------------
-- Messages

-- Decodes a discovery message (discovery/v1/Messages.hpp, discovery/UdpMessenger.hpp, link/PeerState.hpp).
-- Returns a message table, or nil and a reason when Link would ignore the message:
--   { type = 1|2|3, ttl, group, node_id (8-byte string), timeline, session_id, start_stop, mep4, mep6, aep4, aep6 }
-- Entries a message does not carry are nil. The payload of a ByeBye is not read, as in Link.
function M.decode_discovery(data)
  if type(data) ~= "string" then return nil, "not a string" end
  -- parseMessageHeader: protocol header (8) + type (1) + ttl (1) + group (2) + node id (8)
  if #data < 20 or sub(data, 1, 8) ~= DISCOVERY_HEADER then return nil, "header" end
  local mtype, ttl, group = unpack(">I1I1I2", data, 9)
  if mtype == 0 then return nil, "header" end -- kInvalid
  local msg = { type = mtype, ttl = ttl, group = group, node_id = sub(data, 13, 20) }
  if group ~= 0 then return nil, "group", msg end -- UdpMessenger ignores other groups
  if mtype == M.BYEBYE then return msg end
  if mtype ~= M.ALIVE and mtype ~= M.RESPONSE then return nil, "type", msg end
  local entries, err = parse_entries(data, 21, DISCOVERY_ENTRIES)
  if not entries then return nil, "payload", msg, err end
  for k, v in pairs(entries) do msg[k] = v end
  return msg
end

-- Decodes a measurement message (link/v1/Messages.hpp). For a pong (link/Measurement.hpp), returns
--   { type = 2, session_id, ghost, prev_ghost, host }   (entries the pong does not carry are nil)
-- For a ping (link/PingResponder.hpp), returns { type = 1, payload_size, answered } where answered says whether a
-- Link peer would reply (payload at most the size of HostTime + PrevGHostTime). Returns nil and a reason otherwise.
local MAX_PING_PAYLOAD = 2 * (8 + 8) -- link/PingResponder.hpp: sizeInByteStream(makePayload(HostTime, PrevGHostTime))
function M.decode_measurement(data)
  if type(data) ~= "string" then return nil, "not a string" end
  if #data < 9 or sub(data, 1, 8) ~= MEASUREMENT_HEADER then return nil, "header" end
  local mtype = byte(data, 9)
  if mtype == 0 then return nil, "header" end
  if mtype == M.PING then
    local size = #data - 9
    return { type = mtype, payload_size = size, answered = size <= MAX_PING_PAYLOAD }
  end
  if mtype ~= M.PONG then return nil, "type", { type = mtype } end
  local entries, err = parse_entries(data, 10, PONG_ENTRIES)
  if not entries then return nil, "payload", { type = mtype }, err end
  entries.type = mtype
  return entries
end

local function entry(key, value_format, ...)
  local value = pack(value_format, ...)
  return pack(">I4I4", key, #value) .. value
end

-- Encodes a ping as link/Measurement.hpp sends it: HostTime, plus PrevGHostTime (the ghost time of the last
-- pong) on every ping after the first.
function M.encode_ping(host_us, prev_ghost_us)
  local s = MEASUREMENT_HEADER .. pack(">I1", M.PING) .. entry(KEY.ht, ">i8", host_us)
  if prev_ghost_us then s = s .. entry(KEY.pgt, ">i8", prev_ghost_us) end
  return s
end

-- The data points one pong yields (link/Measurement.hpp, operator()): the ghost-minus-host offset estimated
-- from the pong's ghost time and the host times around it. host_now_us is the host time the pong arrived.
-- A pong without ghost or host time yields none, as in Link (which treats 0 as absent).
function M.measurement_points(pong, host_now_us)
  local points = {}
  local gt, pgt, ht = pong.ghost or 0, pong.prev_ghost or 0, pong.host or 0
  if gt ~= 0 and ht ~= 0 then
    points[#points + 1] = gt - (host_now_us + ht) * 0.5
    if pgt ~= 0 then
      points[#points + 1] = (gt + pgt) * 0.5 - ht
    end
  end
  return points
end

-- link/Measurement.hpp: kNumberDataPoints, kNumberMeasurements; the 50 ms timer in resetTimer()
M.MEASUREMENT_POINTS = 100
M.MEASUREMENT_RETRIES = 5
M.MEASUREMENT_TIMEOUT_US = 50000
-- discovery/PeerGateway.hpp: ttl 5 s, broadcast every ttl/ttlRatio (20) = 250 ms; a peer is pruned after its ttl
M.DEFAULT_TTL_S = 5
M.BROADCAST_PERIOD_US = 250000

------------------------------------------------------------------------------------------------------------------
-- Arithmetic

-- std::llround: round half away from zero, to an integer.
local function llround(x)
  if x >= 0 then
    local r = floor(x)
    if x - r >= 0.5 then r = r + 1 end
    return tointeger(r) or r
  end
  local r = floor(-x)
  if -x - r >= 0.5 then r = r + 1 end
  return -(tointeger(r) or r)
end
M.llround = llround

-- link/Median.hpp: the middle value, or the mean of the two middle values (needs more than 2 values).
function M.median(values)
  local n = #values
  if n <= 2 then return nil end
  local v = table.move(values, 1, n, 1, {})
  table.sort(v)
  if n % 2 == 0 then return (v[n // 2 + 1] + v[(n - 1) // 2 + 1]) / 2.0 end
  return v[n // 2 + 1]
end

-- link/MeasurementService.hpp: a finished measurement gives GhostXForm{1, llround(median(data))}.
function M.ghost_xform(points)
  local m = M.median(points)
  if m == nil then return nil end
  return { slope = 1.0, intercept = llround(m) }
end

-- link/GhostXForm.hpp
function M.host_to_ghost(x, host_us) return llround(x.slope * host_us) + x.intercept end
function M.ghost_to_host(x, ghost_us) return llround((ghost_us - x.intercept) / x.slope) end

-- link/Tempo.hpp: a timeline carries the tempo as micros per beat; Link turns it into bpm and back.
function M.bpm(micros_per_beat) return 60.0 * 1e6 / micros_per_beat end
function M.micros_per_beat(bpm) return llround(60.0 * 1e6 / bpm) end
-- The micros per beat Link computes with: Tempo holds bpm as a double, and microsPerBeat() rounds it back. A
-- timeline table may carry that double as bpm (update_client_timeline does, as Link's tempTl does).
local function effective_mpb(tl) return M.micros_per_beat(tl.bpm or M.bpm(tl.micros_per_beat)) end
M.effective_micros_per_beat = effective_mpb

-- link/ClientSessionTimelines.hpp: clampTempo
M.MIN_BPM, M.MAX_BPM = 20.0, 999.0
function M.clamp_bpm(bpm) return math.min(math.max(bpm, M.MIN_BPM), M.MAX_BPM) end

-- link/Beats.hpp: Beats(double) is llround(beats * 1e6); floating() is microBeats / 1e6
local function beats_from_float(b) return llround(b * 1e6) end

-- link/Timeline.hpp: toBeats, fromBeats (with link/Tempo.hpp microsToBeats, beatsToMicros)
function M.to_beats(tl, time_us)
  local mpb = effective_mpb(tl)
  return tl.beat_origin + beats_from_float((time_us - tl.time_origin) / mpb)
end

function M.from_beats(tl, beats)
  local mpb = effective_mpb(tl)
  return tl.time_origin + llround(((beats - tl.beat_origin) / 1e6) * mpb)
end

-- link/Phase.hpp: phase, in [0, quantum); 0 when the quantum is 0
function M.phase(beats, quantum)
  if quantum == 0 then return 0 end
  local bins = (math.abs(beats) + quantum) // quantum
  return (beats + bins * quantum) % quantum
end

-- link/Phase.hpp: nextPhaseMatch, closestPhaseMatch
function M.next_phase_match(x, target, quantum)
  local desired = M.phase(target, quantum)
  local xphase = M.phase(x, quantum)
  local diff = quantum == 0 and 0 or (desired - xphase + quantum) % quantum
  return x + diff
end

function M.closest_phase_match(x, target, quantum)
  return M.next_phase_match(x - beats_from_float(0.5 * (quantum / 1e6)), target, quantum)
end

-- link/Phase.hpp: toPhaseEncodedBeats, fromPhaseEncodedBeats. Beat 0 of the session timeline is the origin of
-- the quantum grid shared by all participants (link/ClientSessionTimelines.hpp).
function M.to_phase_encoded_beats(tl, time_us, quantum)
  local beat = M.to_beats(tl, time_us)
  return M.closest_phase_match(beat, beat - tl.beat_origin, quantum)
end

function M.from_phase_encoded_beats(tl, beat, quantum)
  local from_origin = beat - tl.beat_origin
  local origin_offset = from_origin - M.phase(from_origin, quantum)
  local inverse = M.closest_phase_match(quantum - M.phase(from_origin, quantum), quantum - M.phase(beat, quantum),
    quantum)
  return M.from_beats(tl, tl.beat_origin + origin_offset + quantum - inverse)
end

-- link/ClientSessionTimelines.hpp: updateClientTimelineFromSession. Gives a client timeline (in host time) that
-- continues cur_client's beats at at_us with the session's tempo, anchored at the host time of session beat 0.
function M.update_client_timeline(cur_client, session, at_us, xform)
  local temp = { micros_per_beat = session.micros_per_beat, bpm = session.bpm or M.bpm(session.micros_per_beat),
    beat_origin = M.to_beats(cur_client, at_us), time_origin = at_us }
  local host_beat_zero = M.ghost_to_host(xform, M.from_beats(session, 0))
  return { micros_per_beat = effective_mpb(temp), beat_origin = M.to_beats(temp, host_beat_zero),
    time_origin = host_beat_zero }
end

------------------------------------------------------------------------------------------------------------------
-- Formatting

function M.hex(s)
  return (s:gsub(".", function(c) return format("%02x", byte(c)) end))
end

function M.unhex(h)
  if #h % 2 ~= 0 or h:find("[^0-9a-fA-F]") then return nil end
  return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end))
end

-- In the console this file is one of the plugin's components (plugin/gma3_beat_sync.xml). The console runs each
-- component with (plugin name, component name, signal table, handle); the signal table is shared by all of the
-- plugin's components, so the module registers itself there. Loaded with dofile() or load(source)(), there are no
-- arguments and it only returns the table.
local signal_table = select(3, ...)
if type(signal_table) == "table" then signal_table.beat_sync_protocol = M end

return M
