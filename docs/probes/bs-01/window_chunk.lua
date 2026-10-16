-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- BS-01 probe chunk (not part of the product), run through the bridge by drift.mjs, which prepends the protocol
-- module as P and sets SEQ (sequence number), MASTER (speed master number), ACTION (nil, "setbpm", "setbpm-bar",
-- "resync-bar", "go", "go-beat") and FRAMES. It joins the session, measures the peer, optionally acts, then
-- records the sequence's current cue at the start of every frame for FRAMES frames. Returns the session timeline,
-- the transform and each cue change with its wall-clock time.

local socket = require("socket")
local function now_us() return P.llround(socket.gettime() * 1e6) end

local MAX_PACKETS = 32 -- discovery packets read per frame; the rest wait

local mc, uc
local function finish(result)
  if mc then mc:close() end
  if uc then uc:close() end
  return result
end

mc = socket.udp4()
mc:setoption("reuseaddr", true)
mc:setoption("reuseport", true)
if not mc:setsockname("0.0.0.0", P.PORT) then return finish({ error = "bind" }) end
mc:setoption("ip-add-membership", { multiaddr = P.MULTICAST_ADDRESS, interface = "127.0.0.1" })
mc:settimeout(0)
uc = socket.udp4()
uc:setsockname("0.0.0.0", 0)
uc:settimeout(0.003)

local peer
local t0 = now_us()
while not peer and now_us() - t0 < 1500000 do
  for _ = 1, MAX_PACKETS do
    local d = mc:receivefrom()
    if not d then break end
    local m = P.decode_discovery(d)
    if m and m.type ~= P.BYEBYE and m.mep4 and m.timeline and m.session_id then peer = m break end
  end
  if not peer then coroutine.yield() end
end
if not peer then return finish({ error = "no peer" }) end

-- Bounded like test/live/follow_chunk.lua: 10 exchanges or 4 ms per frame, 20 unusable replies, 300 in total, 1 s.
local points, prev, exchanges, timeouts, unusable, attempts = {}, nil, 0, 0, 0, 0
local m_start, f_start, in_frame = now_us(), now_us(), 0
while #points <= P.MEASUREMENT_POINTS and timeouts < P.MEASUREMENT_RETRIES and unusable < 20 and attempts < 300
  and now_us() - m_start < 1000000 do
  attempts = attempts + 1
  local sent = now_us()
  uc:sendto(P.encode_ping(sent, prev), peer.mep4.address, peer.mep4.port)
  local d = uc:receive()
  local received = now_us()
  local pong = d and P.decode_measurement(d)
  -- pair the pong with this ping: it echoes our host time
  if not d then
    timeouts = timeouts + 1
  elseif pong and pong.type == P.PONG and pong.session_id == peer.session_id and pong.host == sent then
    local got = P.measurement_points(pong, received)
    if #got == 0 then unusable = unusable + 1 end
    for _, p in ipairs(got) do points[#points + 1] = p end
    prev = pong.ghost
    exchanges = exchanges + 1
  else
    unusable = unusable + 1
  end
  in_frame = in_frame + 1
  if in_frame >= 10 or now_us() - f_start >= 4000 then
    coroutine.yield()
    in_frame, f_start = 0, now_us()
  end
end
local xform = P.ghost_xform(points)
if not xform or #points <= P.MEASUREMENT_POINTS then return finish({ error = "measurement failed" }) end

local seq = DataPool().Sequences[SEQ]
if not seq then return finish({ error = "no sequence " .. SEQ }) end
local function current_cue()
  local c = seq.CurrentCue -- the sequence's current cue (it keeps the last cue after Off)
  return c and c.no or -1
end

local bpm = P.bpm(peer.timeline.micros_per_beat)
local quantum = 4000000
local function beat_at(h) return P.to_beats(peer.timeline, P.host_to_ghost(xform, h)) end

local acts = {}
local function act(kind, h)
  local t = now_us()
  if kind == "setbpm" then
    Cmd(string.format("Master 3.%d At BPM %.4f", MASTER, bpm))
  elseif kind == "resync" then
    Cmd("ReSync Sequence " .. SEQ)
  elseif kind == "go" then
    Cmd("Go+ Sequence " .. SEQ)
  end
  acts[#acts + 1] = string.format("%s@%d+%d", kind, h, now_us() - t)
end

if ACTION == "setbpm" then act("setbpm", now_us()) end
if ACTION == "go" then
  -- start the chase on the next beat
  local h = now_us()
  local next_beat = (beat_at(h) // 1000000 + 1) * 1000000
  local target = P.ghost_to_host(xform, P.from_beats(peer.timeline, next_beat))
  for _ = 1, 120 do if now_us() >= target - 8000 then break end coroutine.yield() end -- at most 2 s
  act("go", now_us())
end

local changes = {}
local last_cue = current_cue()
local last_beat = beat_at(now_us())
local frames = {}
for _ = 1, FRAMES do
  local h = now_us()
  local cue = current_cue()
  if cue ~= last_cue then
    changes[#changes + 1] = string.format("%d:%d", h, cue)
    last_cue = cue
  end
  local b = beat_at(h)
  if ACTION == "setbpm-bar" and b // quantum ~= last_beat // quantum then act("setbpm", h) end
  if ACTION == "resync-bar" and b // quantum ~= last_beat // quantum then act("resync", h) end
  if ACTION == "go-beat" and b // 1000000 ~= last_beat // 1000000 then act("go", h) end
  last_beat = b
  frames[#frames + 1] = h
  coroutine.yield()
end

return finish({
  timeline = string.format("%d,%d,%d", peer.timeline.micros_per_beat, peer.timeline.beat_origin,
    peer.timeline.time_origin),
  intercept = xform.intercept,
  exchanges = exchanges,
  bpm = bpm,
  changes = table.concat(changes, ","),
  acts = table.concat(acts, ","),
  firstFrame = frames[1],
  lastFrame = frames[#frames],
  frames = #frames,
})
