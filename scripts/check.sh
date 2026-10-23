#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 gma3-beat-sync contributors
#
# Repository checks, run locally and in CI.
#   scripts/check.sh lua      Lua 5.5 syntax check of every .lua file
#   scripts/check.sh spdx     every source file carries the SPDX licence identifier
#   scripts/check.sh harness  the Lua harness (test/lua/*_test.lua) under stock Lua 5.5
#   scripts/check.sh scripts  node --check of every .mjs file, and the probe scripts' offline tests (needs node)
#   scripts/check.sh peer     build the test tools from the Link submodule (tools/test-peer, modules/link) and
#                             check the test peer's JSON lines (needs python3)
#   scripts/check.sh fixtures every fixture's expect lines are what Link's parser reads (needs peer)
#   scripts/check.sh vectors  test/fixtures/vectors.txt is what Link's arithmetic gives (needs peer)
#   scripts/check.sh bridge   the Link bridge in bridge/: cargo fmt --check, clippy -D warnings and cargo test (needs
#                             Rust, CMake and the submodule; not part of all)
#   scripts/check.sh [all]    all of the above but bridge
set -eu

cd "$(dirname "$0")/.."
LUA=${LUA:-lua}
LUAC=${LUAC:-luac}
BUILD_DIR=${BUILD_DIR:-build}

# Source files of this repository; the submodule and build output are excluded.
sources() {
  find . \( -path ./modules -o -path ./build -o -path ./target -o -path ./.git \) -prune -o -type f \( "$@" \) -print | sort
}

check_lua_version() {
  version=$("$LUA" -v 2>&1)
  case "$version" in
    "Lua 5.5"*) ;;
    *) echo "error: need Lua 5.5 (the console's version), found: $version" >&2; exit 1 ;;
  esac
}

check_lua() {
  check_lua_version
  count=0
  for f in $(sources -name '*.lua'); do
    "$LUAC" -p "$f"
    count=$((count + 1))
  done
  echo "lua: $count file(s) parse under $("$LUA" -v 2>&1)"
}

check_spdx() {
  missing=0
  count=0
  for f in $(sources -name '*.lua' -o -name '*.cpp' -o -name '*.hpp' -o -name '*.h' -o -name '*.sh' -o -name '*.mjs' \
    -o -name 'CMakeLists.txt' -o -name '*.cmake' -o -name '*.yml' -o -name '*.xml' -o -name '*.rs' -o -name '*.toml'); do
    count=$((count + 1))
    if ! head -n 5 "$f" | grep -q 'SPDX-License-Identifier: GPL-2.0-or-later'; then
      echo "error: $f has no 'SPDX-License-Identifier: GPL-2.0-or-later' in its first 5 lines" >&2
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ] || exit 1
  echo "spdx: $count source file(s) carry the identifier"
}

check_harness() {
  check_lua_version
  count=0
  for f in $(sources -path './test/lua/*_test.lua'); do
    echo "harness: $f"
    "$LUA" "$f"
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    echo "harness: no test/lua/*_test.lua files yet"
  fi
}

check_scripts() {
  count=0
  for f in $(sources -name '*.mjs'); do
    node --check "$f"
    count=$((count + 1))
  done
  echo "scripts: $count .mjs file(s) parse"
  for t in $(sources -name '*_test.mjs'); do
    echo "scripts: $t"
    node "$t"
  done
}

check_peer() {
  if [ ! -f modules/link/CMakeLists.txt ]; then
    echo "error: modules/link is empty; run: git submodule update --init --recursive" >&2
    exit 1
  fi
  cmake -S tools/test-peer -B "$BUILD_DIR/tools" -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$BUILD_DIR/tools" -j 4
  for t in gbs-test-peer gbs-capture gbs-vectors; do test -x "$BUILD_DIR/tools/bin/$t"; done
  echo "peer: built gbs-test-peer, gbs-capture, gbs-vectors from Link $(git -C modules/link describe --tags)"
  tools/test-peer/json_lines_test.sh "$BUILD_DIR/tools/bin/gbs-test-peer"
}

check_fixtures() {
  bin="$BUILD_DIR/tools/bin"
  count=0
  for f in test/fixtures/*.txt; do
    [ "$f" = test/fixtures/vectors.txt ] && continue
    if ! "$bin/gbs-capture" --decode <"$f" | diff -u "$f" - >&2; then
      echo "error: $f: expect lines differ from Link's parser (above)" >&2
      exit 1
    fi
    count=$((count + 1))
  done
  if ! "$LUA" test/fixtures/make_variants.lua | "$bin/gbs-capture" --decode | diff -u test/fixtures/variants.txt - >&2; then
    echo "error: test/fixtures/variants.txt is not the output of make_variants.lua; regenerate it with:" >&2
    echo "  $LUA test/fixtures/make_variants.lua | $bin/gbs-capture --decode > test/fixtures/variants.txt" >&2
    exit 1
  fi
  if ! "$LUA" test/fixtures/make_peer_messages.lua | "$bin/gbs-capture" --decode | diff -u test/fixtures/peer_messages.txt - >&2; then
    echo "error: test/fixtures/peer_messages.txt is not the output of make_peer_messages.lua; regenerate it with:" >&2
    echo "  $LUA test/fixtures/make_peer_messages.lua | $bin/gbs-capture --decode > test/fixtures/peer_messages.txt" >&2
    exit 1
  fi
  echo "fixtures: $count file(s) agree with Link's parser"
}

check_vectors() {
  if ! "$BUILD_DIR/tools/bin/gbs-vectors" | diff -u test/fixtures/vectors.txt - >&2; then
    echo "error: test/fixtures/vectors.txt differs from gbs-vectors; regenerate it with:" >&2
    echo "  $BUILD_DIR/tools/bin/gbs-vectors > test/fixtures/vectors.txt" >&2
    exit 1
  fi
  echo "vectors: test/fixtures/vectors.txt matches Link's arithmetic"
}

check_bridge() {
  if [ ! -f modules/link/CMakeLists.txt ]; then
    echo "error: modules/link is empty; run: git submodule update --init --recursive" >&2
    exit 1
  fi
  cargo fmt --all --check
  cargo clippy -p link-bridge --all-targets -- -D warnings
  cargo test -p link-bridge
  echo "bridge: fmt, clippy and tests pass (tests/link_session.rs is ignored: it joins the network's Link session)"
}

case "${1:-all}" in
  lua) check_lua ;;
  spdx) check_spdx ;;
  harness) check_harness ;;
  scripts) check_scripts ;;
  peer) check_peer ;;
  fixtures) check_fixtures ;;
  vectors) check_vectors ;;
  bridge) check_bridge ;;
  all) check_spdx; check_lua; check_harness; check_scripts; check_peer; check_fixtures; check_vectors ;;
  *) echo "usage: $0 [lua|spdx|harness|scripts|peer|fixtures|vectors|bridge|all]" >&2; exit 2 ;;
esac
