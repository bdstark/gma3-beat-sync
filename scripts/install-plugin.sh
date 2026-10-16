#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 gma3-beat-sync contributors
#
# Copies the plugin into the grandMA3 user library, from where onPC imports it:
#   Import Plugin Library "gma3_beat_sync.xml" At Plugin <an empty slot>
#   Plugin "gma3_beat_sync"
# Set GMA3_LIBRARY to use another library folder (default: ~/MALightingTechnology/gma3_library).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
lib=${GMA3_LIBRARY:-$HOME/MALightingTechnology/gma3_library}
if [ ! -d "$lib" ]; then
  echo "grandMA3 library folder not found at $lib (set GMA3_LIBRARY)" >&2
  exit 1
fi
dest="$lib/datapools/plugins"
mkdir -p "$dest"
cp "$here/plugin/gma3_beat_sync.xml" "$here/plugin/gma3_beat_sync.lua" "$here/plugin/beat_sync_protocol.lua" \
  "$here/plugin/beat_sync_follower.lua" "$dest/"
echo "Installed to $dest"
echo 'In grandMA3, check that the plugin slot is empty, then:'
echo '  Import Plugin Library "gma3_beat_sync.xml" At Plugin <slot>'
echo '  Plugin "gma3_beat_sync"'
