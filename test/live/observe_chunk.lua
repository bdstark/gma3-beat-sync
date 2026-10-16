-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Observer run inside the console by test/live/plugin_live.mjs, which prepends the protocol module as P and sets
-- SEQ (a sequence number) and FRAMES. Independently of the plugin, it finds the session, measures it (as
-- test/live/follow_chunk.lua does, with the same bounds) and records the sequence's current cue at the start of
-- every frame for FRAMES frames. Returns the session timeline, the ghost-host intercept and each cue change with
-- its wall-clock time, so the test can place the plugin's actions on the session's beat grid.

local socket = require("socket")
local mc, uc
local function now_us() return P.llround(socket.gettime() * 1e6) end
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
  for _ = 1, 32 do
    local d = mc:receivefrom()
    if not d then break end
    local m = P.decode_discovery(d)
    if m and m.type ~= P.BYEBYE and m.mep4 and m.timeline and m.session_id then peer = m break end
  end
  if not peer then coroutine.yield() end
end
if not peer then return finish({ error = "no peer" }) end

-- Peers that answer slowly (a relay such as LinkMaster answered in 1-2 ms, sometimes 30 ms, against 0.3 ms for a
-- Link test peer) miss many 3 ms receives; the observer then needs more timeouts and late (unpaired) replies before
-- it gives up. It stays within 1.2 s so the whole chunk fits the bridge's 5 s request budget.
local points, prev, timeouts, unusable, attempts, late = {}, nil, 0, 0, 0, 0
local m_start, f_start, in_frame = now_us(), now_us(), 0
while #points <= P.MEASUREMENT_POINTS and timeouts < 60 and unusable < 120 and attempts < 400
  and now_us() - m_start < 1200000 do
  attempts = attempts + 1
  local sent = now_us()
  uc:sendto(P.encode_ping(sent, prev), peer.mep4.address, peer.mep4.port)
  -- read until this ping's pong or 3 ms: late pongs of earlier pings are skipped (and counted), so one slow reply
  -- does not make every later exchange read the previous ping's pong
  local pong, received
  while true do
    local left = 0.003 - (now_us() - sent) / 1e6
    if left <= 0 then break end
    uc:settimeout(left)
    local d = uc:receive()
    if not d then break end
    received = now_us()
    local m = P.decode_measurement(d)
    if m and m.type == P.PONG and m.session_id == peer.session_id and m.host == sent then pong = m break end
    late = late + 1
  end
  if not pong then
    timeouts = timeouts + 1
  else
    local got = P.measurement_points(pong, received)
    if #got == 0 then unusable = unusable + 1 end
    for _, p in ipairs(got) do points[#points + 1] = p end
    prev = pong.ghost
  end
  in_frame = in_frame + 1
  if in_frame >= 10 or now_us() - f_start >= 4000 then
    coroutine.yield()
    in_frame, f_start = 0, now_us()
  end
end
local xform = P.ghost_xform(points)
if not xform or #points <= P.MEASUREMENT_POINTS then
  return finish({ error = string.format("measurement failed (%d points, %d timeouts, %d unusable, %d late, %d pings)",
    #points, timeouts, unusable, late, attempts) })
end

local seq = DataPool().Sequences[SEQ]
if not seq then return finish({ error = "no sequence " .. SEQ }) end
local function current_cue()
  local c = seq.CurrentCue
  return c and c.no or -1
end

local changes = {}
local last_cue = current_cue()
local first = now_us()
for _ = 1, FRAMES do
  -- keep the newest timeline of the session (a tempo change or a start moves it)
  for _ = 1, 32 do
    local d = mc:receivefrom()
    if not d then break end
    local m = P.decode_discovery(d)
    if m and m.session_id == peer.session_id and m.timeline and m.timeline.beat_origin > peer.timeline.beat_origin then
      peer.timeline = m.timeline
    end
    -- and the newest start/stop state (link/Controller.hpp: a newer timestamp wins)
    if m and m.session_id == peer.session_id and m.start_stop
      and (not peer.start_stop or m.start_stop.timestamp > peer.start_stop.timestamp) then
      peer.start_stop = m.start_stop
    end
  end
  local h = now_us()
  local cue = current_cue()
  if cue ~= last_cue then
    changes[#changes + 1] = string.format("%d:%d", h, cue)
    last_cue = cue
  end
  coroutine.yield()
end

return finish({
  timeline = string.format("%d,%d,%d", peer.timeline.micros_per_beat, peer.timeline.beat_origin,
    peer.timeline.time_origin),
  intercept = xform.intercept,
  changes = table.concat(changes, ","),
  start_stop = peer.start_stop and string.format("%d,%d,%d", peer.start_stop.playing and 1 or 0,
    peer.start_stop.beats, peer.start_stop.timestamp) or nil,
  first = first,
  last = now_us(),
})
