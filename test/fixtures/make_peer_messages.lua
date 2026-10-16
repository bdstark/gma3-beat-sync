-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Writes the messages the plugin sends as a full peer (BS-03), from the follower's own encoders, as fixture "packet"
-- lines, so Link's own parser can label them (gbs-capture --decode) and the harness can check them. scripts/check.sh
-- fixtures runs
--   lua test/fixtures/make_peer_messages.lua | gbs-capture --decode > test/fixtures/peer_messages.txt
-- and fails when the result differs from the committed file. Values are fixed so the output is the same every run.
-- Usage: lua test/fixtures/make_peer_messages.lua

local root = (arg and arg[0] or ""):match("^(.*)test/fixtures/[^/]*$") or "./"
local P = dofile(root .. "plugin/beat_sync_protocol.lua")
local F = dofile(root .. "plugin/beat_sync_follower.lua")

local function line(note, kind, data)
  print("# " .. note)
  print("packet " .. kind .. " " .. P.hex(data))
end

print("# Messages of the plugin as a full peer (BS-03), from test/fixtures/make_peer_messages.lua, labelled by Link's parser")
local f = F.new(P, { quantum = 4, peer = { node_id = "\1\35\69\103\137\171\205\239", now_us = 1000000, bpm = 133.5 } })
line("peer Alive, own session at 133.5 bpm, stopped, loopback endpoint", "discovery", f:announcement(P.ALIVE, "127.0.0.1", 54321))
line("peer Response on a network address", "discovery", f:announcement(P.RESPONSE, "192.168.1.20", 54321))
f:propose_start_stop(true, 3000000)
line("peer Alive after a start (next bar)", "discovery", f:announcement(P.ALIVE, "127.0.0.1", 54321))
f:propose_tempo(140, 4000000)
line("peer Alive after a tempo change to 140 bpm", "discovery", f:announcement(P.ALIVE, "127.0.0.1", 54321))
f:propose_start_stop(false, 5000000)
line("peer Alive after a stop", "discovery", f:announcement(P.ALIVE, "127.0.0.1", 54321))
line("peer ByeBye", "discovery", f:announcement(P.BYEBYE, "127.0.0.1", 54321))
line("peer pong to a first ping (host time only)", "pong", f:answer_ping(P.encode_ping(123456789), 2000000, 2016667))
line("peer pong to a later ping (host and previous ghost time)", "pong",
  f:answer_ping(P.encode_ping(123470000, 1016000), 2016667, 2017000))
