-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 gma3-beat-sync contributors
--
-- Writes hand-made packet variants (malformed, unusual and edge cases) as fixture "packet" lines. Link's own parser
-- then labels them: scripts/check.sh fixtures runs
--   lua test/fixtures/make_variants.lua | gbs-capture --decode > test/fixtures/variants.txt
-- Usage: lua test/fixtures/make_variants.lua

local pack = string.pack

local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function entry(key, value) return key .. pack(">I4", #value) .. value end
local function header(mtype, ttl, group, node)
  return "_asdp_v\1" .. pack(">I1I1I2", mtype, ttl, group) .. (node or "\1\2\3\4\5\6\7\8")
end

local node = "\1\2\3\4\5\6\7\8"
local tmln = entry("tmln", pack(">i8i8i8", 500000, 1234567, -987654321))
local sess = entry("sess", node)
local stst = entry("stst", pack(">I1i8i8", 1, 4000000, 123456789))
local mep4 = entry("mep4", pack(">I1I1I1I1I2", 192, 168, 1, 20, 54321))
local mep6 = entry("mep6", "\254\128" .. string.rep("\0", 13) .. "\1" .. pack(">I2", 50000)) -- fe80::1
local aep4 = entry("aep4", pack(">I1I1I1I1I2", 10, 0, 0, 7, 20809))
local full = tmln .. sess .. stst .. mep4

local cases = {
  { "alive, all entries", header(1, 5, 0) .. full },
  { "response, all entries", header(2, 5, 0) .. full },
  { "byebye, no payload", header(3, 0, 0) },
  { "byebye with a payload (not read)", header(3, 0, 0) .. "garbage" },
  { "alive, IPv6 measurement endpoint", header(1, 5, 0) .. tmln .. sess .. stst .. mep6 },
  { "alive, audio endpoint", header(1, 5, 0) .. full .. aep4 },
  { "alive, no payload", header(1, 5, 0) },
  { "alive, only a timeline", header(1, 5, 0) .. tmln },
  { "alive, unknown entry skipped", header(1, 5, 0) .. entry("zzzz", "whatever") .. full },
  { "alive, unknown entry of size 0", header(1, 5, 0) .. entry("zzzz", "") .. full },
  { "alive, duplicate timeline (last wins)",
    header(1, 5, 0) .. full .. entry("tmln", pack(">i8i8i8", 461538, 7, 8)) },
  { "alive, stst playing byte 2", header(1, 5, 0) .. entry("stst", pack(">I1i8i8", 2, 0, 1)) },
  { "alive, ttl 255", header(1, 255, 0) .. full },
  { "alive, negative times", header(1, 5, 0) .. entry("tmln", pack(">i8i8i8", 60060, -5, -6)) },
  { "alive, group 1 (ignored)", header(1, 5, 1) .. full },
  { "message type 0 (invalid)", header(0, 5, 0) .. full },
  { "message type 4 (unknown)", header(4, 5, 0) .. full },
  { "wrong protocol version", "_asdp_v\2" .. header(1, 5, 0):sub(9) .. full },
  { "wrong magic", "_asdq_v\1" .. header(1, 5, 0):sub(9) .. full },
  { "empty", "" },
  { "header only, 19 bytes", header(1, 5, 0):sub(1, 19) },
  { "header only, 20 bytes", header(1, 5, 0) },
  { "truncated entry header", header(1, 5, 0) .. full .. "tml" },
  { "entry size beyond the message", header(1, 5, 0) .. "tmln" .. pack(">I4", 24) .. pack(">i8", 1) },
  { "timeline entry too short", header(1, 5, 0) .. entry("tmln", pack(">i8i8", 1, 2)) .. sess },
  { "timeline entry too long", header(1, 5, 0) .. entry("tmln", pack(">i8i8i8I1", 1, 2, 3, 4)) .. sess },
  { "session entry too short", header(1, 5, 0) .. tmln .. entry("sess", "\1\2\3") },
  { "session entry empty (zero id)", header(1, 5, 0) .. tmln .. entry("sess", "") },
  { "session entry too long", header(1, 5, 0) .. tmln .. entry("sess", "123456789") },
  { "mep4 entry too long", header(1, 5, 0) .. tmln .. entry("mep4", "1234567") },
  { "huge entry size", header(1, 5, 0) .. "tmln" .. pack(">I4", 0xffffffff) .. string.rep("\0", 24) },
}

local measurement = {
  { "ping, host time", "_link_v\1\1" .. entry("__ht", pack(">i8", 1000)) },
  { "ping, host and previous ghost time",
    "_link_v\1\1" .. entry("__ht", pack(">i8", 1000)) .. entry("_pgt", pack(">i8", 2000)) },
  { "ping, payload too large (not answered)",
    "_link_v\1\1" .. entry("__ht", pack(">i8", 1000)) .. entry("_pgt", pack(">i8", 2000)) .. "x" },
  { "pong, full", "_link_v\1\2" .. entry("sess", node) .. entry("__gt", pack(">i8", 5000))
    .. entry("__ht", pack(">i8", 1000)) .. entry("_pgt", pack(">i8", 4000)) },
  { "pong, no previous ghost time", "_link_v\1\2" .. entry("sess", node) .. entry("__gt", pack(">i8", 5000))
    .. entry("__ht", pack(">i8", 1000)) },
  { "pong, no session", "_link_v\1\2" .. entry("__gt", pack(">i8", 5000)) },
  { "pong, bad ghost size", "_link_v\1\2" .. entry("sess", node) .. entry("__gt", pack(">i4", 5)) },
  { "pong, truncated", ("_link_v\1\2" .. entry("sess", node) .. entry("__gt", pack(">i8", 5000))):sub(1, -3) },
  { "measurement type 3", "_link_v\1\3" .. entry("sess", node) },
  { "measurement type 0", "_link_v\1\0" },
  { "measurement header only", "_link_v\1" },
  { "measurement wrong version", "_link_v\2\2" .. entry("sess", node) },
}

print("# Hand-made packet variants from test/fixtures/make_variants.lua, labelled by Link's parser (gbs-capture)")
for _, c in ipairs(cases) do
  print("# " .. c[1])
  print("packet discovery " .. hex(c[2]))
end
for _, c in ipairs(measurement) do
  print("# " .. c[1])
  print("packet " .. (c[1]:match("^ping") and "ping" or "pong") .. " " .. hex(c[2]))
end
