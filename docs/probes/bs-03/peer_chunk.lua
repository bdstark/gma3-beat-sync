-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- BS-03 probe chunk (not part of the product), run inside the console through the bridge by peer_probe.mjs, which
-- prepends the protocol module as P and sets DURATION_US and NODE (8 bytes). For DURATION_US the console takes part
-- in Link as a full peer would from a plugin: it founds its own session, announces it every 250 ms, and answers
-- measurement pings once per frame. Its session timeline is exact by construction: 120 BPM, beat 0 at ghost time 0,
-- and ghost time = this console's wall clock in microseconds (so the ghost-host transform is the identity). A Link
-- peer that joins the session measures its clock through these once-a-frame replies; comparing that peer's phase
-- with this timeline shows the error the replies cause.
--
-- Message layouts as in the Link source (modules/link/include/ableton): discovery/v1/Messages.hpp (header),
-- link/NodeState.hpp and link/PeerState.hpp (tmln, sess, stst, mep4), link/v1/Messages.hpp and
-- link/PingResponder.hpp (a pong: sess, __gt, then the ping's payload). Work per frame is bounded: 32 packets per
-- socket.

local socket = require("socket")
local pack = string.pack
local function now_us() return P.llround(socket.gettime() * 1e6) end
local function entry(key, value) return key .. pack(">I4", #value) .. value end

local MPB = 500000 -- 120 BPM
local ms, uc, lc -- multicast sender, measurement socket, discovery listener
local function finish(result)
  for _, s in ipairs({ ms, uc, lc }) do if s then s:close() end end
  return result
end

uc = socket.udp4()
if not uc:setsockname("127.0.0.1", 0) then return finish({ error = "bind measurement socket" }) end
local _, mep_port = uc:getsockname()
uc:settimeout(0)
ms = socket.udp4()
ms:setsockname("127.0.0.1", 0)
ms:setoption("ip-multicast-if", "127.0.0.1")
ms:setoption("ip-multicast-loop", true)
lc = socket.udp4()
lc:setoption("reuseaddr", true)
lc:setoption("reuseport", true)
lc:setsockname("0.0.0.0", P.PORT)
lc:setoption("ip-add-membership", { multiaddr = P.MULTICAST_ADDRESS, interface = "127.0.0.1" })
lc:settimeout(0)

local function message(mtype)
  local head = "_asdp_v\1" .. pack(">I1I1I2", mtype, mtype == P.BYEBYE and 0 or 5, 0) .. NODE
  if mtype == P.BYEBYE then return head end
  return head .. entry("tmln", pack(">i8i8i8", MPB, 0, 0)) .. entry("sess", NODE)
    .. entry("stst", pack(">I1i8i8", 0, 0, 0)) .. entry("mep4", pack(">I1I1I1I1I2", 127, 0, 0, 1, mep_port))
end

-- COMPENSATE (set by the driver): stamp each pong's ghost time half way between the earliest the ping can have
-- arrived (the end of the previous frame's check of the socket, or this console's previous reply, whichever is
-- later) and the reply, instead of at the reply. A Link peer
-- pings again as soon as a pong arrives (link/Measurement.hpp), so a ping usually arrives just after that check and
-- waits most of a frame; the peer assumes the ghost time was taken half way through its round trip.
local start = now_us()
local last_check = start
local next_alive = start
local alive_sent, pings, answered, frames, joined_at = 0, 0, 0, 0, nil
local peers = {}
while now_us() - start < DURATION_US do
  local t = now_us()
  if t >= next_alive then
    ms:sendto(message(P.ALIVE), P.MULTICAST_ADDRESS, P.PORT)
    alive_sent = alive_sent + 1
    next_alive = t + 250000
  end
  -- answer the pings that arrived since the last frame (link/PingResponder.hpp)
  for _ = 1, 32 do
    local d, ip, port = uc:receivefrom()
    if not d then break end
    local m = P.decode_measurement(d)
    if m and m.type == P.PING then
      pings = pings + 1
      if m.answered then
        local now = now_us()
        local gt = COMPENSATE and P.llround((last_check + now) / 2) or now
        uc:sendto("_link_v\1\2" .. entry("sess", NODE) .. entry("__gt", pack(">i8", gt)) .. d:sub(10), ip, port)
        answered = answered + 1
        -- a ping read later in this frame cannot have arrived before this reply was sent
        last_check = now_us()
      end
    end
  end
  last_check = now_us()
  -- watch the other peers' announcements: has one joined this session?
  for _ = 1, 32 do
    local d = lc:receivefrom()
    if not d then break end
    local m = P.decode_discovery(d)
    if m and m.node_id ~= NODE and m.session_id then
      peers[P.hex(m.node_id)] = P.hex(m.session_id)
      if m.session_id == NODE and not joined_at then joined_at = now_us() end
    end
  end
  frames = frames + 1
  coroutine.yield()
end
ms:sendto(message(P.BYEBYE), P.MULTICAST_ADDRESS, P.PORT)

local seen = {}
for node, sess in pairs(peers) do seen[#seen + 1] = node .. "@" .. sess end
return finish({
  node = P.hex(NODE), mep_port = mep_port, start = start, finish = now_us(), frames = frames,
  alive_sent = alive_sent, pings = pings, answered = answered, joined_at = joined_at,
  peers = table.concat(seen, " "),
})
