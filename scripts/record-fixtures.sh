#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 gma3-beat-sync contributors
#
# Records the harness fixtures in test/fixtures/ from test peers on this machine:
#   peer-120-stopped.txt     one peer at 120 bpm, stopped, with 5 ping/pong exchanges
#   peer-playing-changes.txt one peer playing at 133.5 bpm, then a tempo change, stop, and leave (ByeBye)
#   two-peers.txt            two peers that start at different tempos and join one session
# Each packet is labelled with Link's own reading of it (gbs-capture). Only run it on a network you control:
# the captures contain the machine's interface addresses. Build the tools first: scripts/check.sh peer
set -eu
cd "$(dirname "$0")/.."
BIN=${BUILD_DIR:-build}/tools/bin
OUT=test/fixtures

"$BIN/gbs-test-peer" --tempo 120 --interval-ms 0 --duration-s 3.5 >/dev/null &
sleep 1
"$BIN/gbs-capture" --seconds 2 --ping 5 --note "one peer, 120 bpm, stopped" >"$OUT/peer-120-stopped.txt"
wait

(sleep 2; echo "tempo 140"; sleep 1; echo stop; sleep 1; echo quit) |
  "$BIN/gbs-test-peer" --tempo 133.5 --play --interval-ms 0 >/dev/null &
sleep 0.5
"$BIN/gbs-capture" --seconds 4 --ping 3 \
  --note "one peer at 133.5 bpm: plays at 1 s, tempo 140 at 2 s, stops at 3 s, leaves at 4 s" \
  >"$OUT/peer-playing-changes.txt"
wait

"$BIN/gbs-test-peer" --tempo 120 --interval-ms 0 --duration-s 4 >/dev/null &
sleep 0.5
"$BIN/gbs-test-peer" --tempo 90 --interval-ms 0 --duration-s 3.5 >/dev/null &
sleep 1
"$BIN/gbs-capture" --seconds 1.5 --note "two peers, started at 120 and 90 bpm, in one session" >"$OUT/two-peers.txt"
wait
grep -c '^packet' "$OUT"/peer-*.txt "$OUT"/two-peers.txt
