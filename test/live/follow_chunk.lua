-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Follower run inside the console by test/live/follow_test_peer.mjs, which prepends the protocol module as P and
-- sets QUANTUM (micro-beats). It runs on the plugin thread for about two seconds, yielding once per frame, and
-- returns its samples. It closes its sockets on every path.
--
-- Protocol steps, as in the Link source (modules/link/include/ableton):
--   discovery: listen on 224.76.78.75:20808 for Alive/Response messages (discovery/UdpMessenger.hpp);
--   measurement: ping the peer's measurement endpoint, then ping again with the last pong's ghost time, collecting
--     data points until there are more than 100 (link/Measurement.hpp); the median is the ghost-host offset
--     (link/MeasurementService.hpp);
--   follow: the session's beat at ghost time g is timeline.toBeats(g), and beat 0 is the quantum grid's origin
--     (link/Timeline.hpp, link/ClientSessionTimelines.hpp, link/Phase.hpp).

local socket = require("socket")
local function now_us() return P.llround(socket.gettime() * 1e6) end

local mc, uc
local function finish(result)
  if mc then mc:close() end
  if uc then uc:close() end
  return result
end

mc = socket.udp4()
mc:setoption("reuseaddr", true)
mc:setoption("reuseport", true)
local bound, berr = mc:setsockname("0.0.0.0", P.PORT)
if not bound then return finish({ error = "bind: " .. tostring(berr) }) end
-- A peer on the same machine is heard on the loopback interface; "0.0.0.0" lets the system pick the default one.
local joined = {}
for _, iface in ipairs({ "127.0.0.1", "0.0.0.0" }) do
  local ok, err = mc:setoption("ip-add-membership", { multiaddr = P.MULTICAST_ADDRESS, interface = iface })
  joined[#joined + 1] = iface .. "=" .. (ok and "ok" or tostring(err))
end
mc:settimeout(0)
uc = socket.udp4()
uc:setsockname("0.0.0.0", 0)
uc:settimeout(0.003) -- bounded blocking receive: 3 ms

-- 1. Discovery
local peer
local discovery_frames, packets = 0, 0
local t0 = now_us()
while not peer and now_us() - t0 < 1500000 do
  while true do
    local d = mc:receivefrom()
    if not d then break end
    packets = packets + 1
    local m = P.decode_discovery(d)
    if m and m.type ~= P.BYEBYE and m.mep4 and m.timeline and m.session_id then
      peer = m
      break
    end
  end
  if not peer then
    coroutine.yield()
    discovery_frames = discovery_frames + 1
  end
end
if not peer then return finish({ error = "no peer announced itself within 1.5 s", joined = table.concat(joined, " "),
  packets = packets }) end

-- 2. Measurement
local points, prev_ghost, rtts, timeouts, exchanges, measure_frames = {}, nil, {}, 0, 0, 0
local measure_start = now_us()
while #points <= P.MEASUREMENT_POINTS and timeouts < P.MEASUREMENT_RETRIES do
  local sent = now_us()
  uc:sendto(P.encode_ping(sent, prev_ghost), peer.mep4.address, peer.mep4.port)
  local d = uc:receive()
  local received = now_us()
  local pong = d and P.decode_measurement(d)
  if pong and pong.type == P.PONG and pong.session_id == peer.session_id then
    for _, p in ipairs(P.measurement_points(pong, received)) do points[#points + 1] = p end
    prev_ghost = pong.ghost
    rtts[#rtts + 1] = received - sent
    exchanges = exchanges + 1
  else
    timeouts = timeouts + 1
  end
  if exchanges % 10 == 0 then
    coroutine.yield() -- at most 10 exchanges (bounded to 3 ms each) per frame
    measure_frames = measure_frames + 1
  end
end
local measure_us = now_us() - measure_start
local xform = P.ghost_xform(points)
if not xform then return finish({ error = "measurement failed", timeouts = timeouts, exchanges = exchanges }) end
table.sort(rtts)

-- 3. Follow: one sample at the start of each frame
local samples, frame_us, updates = {}, {}, 0
local last = now_us()
for _ = 1, 120 do
  while true do
    local d = mc:receivefrom()
    if not d then break end
    local m = P.decode_discovery(d)
    if m and m.session_id == peer.session_id and m.timeline then
      if m.timeline.micros_per_beat ~= peer.timeline.micros_per_beat
        or m.timeline.beat_origin ~= peer.timeline.beat_origin then updates = updates + 1 end
      peer.timeline, peer.start_stop = m.timeline, m.start_stop or peer.start_stop
    end
  end
  local h = now_us()
  frame_us[#frame_us + 1] = h - last
  last = h
  local beat = P.to_beats(peer.timeline, P.host_to_ghost(xform, h))
  samples[#samples + 1] = string.format("%d:%d:%d:%d", h, P.phase(beat, QUANTUM),
    P.effective_micros_per_beat(peer.timeline), peer.start_stop and peer.start_stop.playing and 1 or 0)
  coroutine.yield()
end
table.sort(frame_us)

return finish({
  samples = table.concat(samples, ","),
  joined = table.concat(joined, " "),
  peer = string.format("node %s session %s mep4 %s:%d", P.hex(peer.node_id), P.hex(peer.session_id),
    peer.mep4.address, peer.mep4.port),
  discoveryFrames = discovery_frames,
  measurement = { exchanges = exchanges, points = #points, timeouts = timeouts, frames = measure_frames,
    intercept = xform.intercept, rttMedianUs = rtts[#rtts // 2 + 1], rttMaxUs = rtts[#rtts],
    tookUs = measure_us },
  timelineUpdates = updates,
  frameMs = { median = frame_us[#frame_us // 2 + 1] / 1000, max = frame_us[#frame_us] / 1000 },
})
