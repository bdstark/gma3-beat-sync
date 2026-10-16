#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 gma3-beat-sync contributors
#
# gbs-test-peer prints valid JSON lines whatever the commands on stdin contain: quotes, backslashes, control
# characters and UTF-8 in an unknown command are escaped. The peer runs with Link disabled, so it joins nothing.
# Usage: tools/test-peer/json_lines_test.sh <path to gbs-test-peer>
set -eu
peer=$1
out=$(printf '%s\n' 'say"hello' 'back\slash' "$(printf 'ctl\001\037\177x')" "$(printf 'caf\303\251"')" 'tempo -1' 'quantum x' 'sample' 'quit' |
  "$peer" --disabled --interval-ms 0)
printf '%s\n' "$out" | python3 -I -c '
import json, sys
lines = sys.stdin.read().splitlines()
events = [json.loads(l) for l in lines]  # raises on an invalid line
cmds = [e["cmd"] for e in events if e["ev"] == "error"]
want = ["say\"hello", "back\\slash", "ctl\x01\x1f\x7fx", "café\"", "tempo", "quantum"]
assert cmds == want, (cmds, want)
assert [e["ev"] for e in events][-2:] == ["ack", "end"], events[-2:]
print("json_lines_test: %d lines, all valid JSON; error commands round-trip exactly" % len(events))
'
