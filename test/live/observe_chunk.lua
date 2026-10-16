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

local points, prev, timeouts, unusable, attempts = {}, nil, 0, 0, 0
local m_start, f_start, in_frame = now_us(), now_us(), 0
while #points <= P.MEASUREMENT_POINTS and timeouts < 5 and unusable < 20 and attempts < 300
  and now_us() - m_start < 1000000 do
  attempts = attempts + 1
  local sent = now_us()
  uc:sendto(P.encode_ping(sent, prev), peer.mep4.address, peer.mep4.port)
  local d = uc:receive()
  local received = now_us()
  local pong = d and P.decode_measurement(d)
  if not d then
    timeouts = timeouts + 1
  elseif pong and pong.type == P.PONG and pong.session_id == peer.session_id and pong.host == sent then
    local got = P.measurement_points(pong, received)
    if #got == 0 then unusable = unusable + 1 end
    for _, p in ipairs(got) do points[#points + 1] = p end
    prev = pong.ghost
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
  first = first,
  last = now_us(),
})
