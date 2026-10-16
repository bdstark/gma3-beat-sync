# gma3-beat-sync

A grandMA3 plugin that follows a tempo session on the local network. It is meant to be compatible with Link™,
Ableton's synchronization technology. The plugin sets a speed master to the session's tempo, keeps effects in phase
with its bars, and fires show actions on the beat. It runs entirely inside the console: no computer, helper program,
OSC or MIDI setup is needed.

**Status:** in development; there is no plugin to install yet. The design and the work are in
[TICKETS.md](TICKETS.md). The protocol module (`plugin/beat_sync_protocol.lua`) parses the session's messages and
does the timeline arithmetic, checked against the Link library's own code, and has followed a test peer inside
onPC ([docs/probes](docs/probes)). It has not been tested against Ableton Live, and no compatibility is claimed
until the applicable cases of Link's [test plan](https://github.com/Ableton/link/blob/master/TEST-PLAN.md) pass.

## How it will work

The console has no Link input, but its Lua plugins can use UDP sockets. The plugin will:

1. listen for the announcements of the Link apps on the network (tempo, timeline, start/stop);
2. measure its clock against one of them;
3. on every console frame:
   - compute the current beat and bar;
   - set the speed master's BPM;
   - realign effects on the bar;
   - run the actions configured for the beat.

The console runs plugins once a frame, about every 16.6 ms on onPC 2.5.1, so an action lands within about ±8 ms of
its beat.

## Related projects

[gma3-mcp](https://github.com/bdstark/gma3-mcp), an MCP server for grandMA3, will read this plugin's status and
configure its actions. It talks to the plugin only through the console and shares no code with this repository.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).

- **Protocol code:** the plugin implements the Link network protocol in Lua. It is written from Ableton's Link
  source code, which is published under the GPL version 2 or later (Copyright 2016, Ableton AG). This repository
  is licensed the same way.
- **The Link library:** used only to build a test peer for this repository's tests. It is included as a git
  submodule under its own license (GPL version 2 or later), with its own third-party dependencies. Nothing from it
  is shipped in the plugin.

### Third-party code in `modules/`

| Path | What | Version | License |
| --- | --- | --- | --- |
| `modules/link` | [Link](https://github.com/Ableton/link), Copyright 2016, Ableton AG | tag `Link-4.1` | GPL-2.0-or-later ([LICENSE.md](https://github.com/Ableton/link/blob/Link-4.1/LICENSE.md)) |
| `modules/link/modules/asio-standalone` | [Asio](https://github.com/chriskohlhoff/asio), Link's network library (its own submodule) | `asio-1-38-2`, pinned by Link | Boost Software License 1.0 (`LICENSE_1_0.txt`) |
| `modules/link/third_party/catch` | Catch, the test framework Link's own unit tests use; not built here | bundled with Link | Boost Software License 1.0 (header of `catch.hpp`) |

## Development

Clone with the submodules, then run the checks (stock Lua 5.5 as `lua` and `luac`, CMake 3.16 or later, a C++
compiler and `python3` are needed):

```sh
git clone --recurse-submodules https://github.com/bdstark/gma3-beat-sync.git
cd gma3-beat-sync
scripts/check.sh
```

`scripts/check.sh` checks the SPDX headers, parses every Lua file with Lua 5.5, runs the Lua harness, builds the
test tools from `modules/link` and checks the fixtures against Link's own parser and arithmetic. CI runs the same
steps. [docs/testing.md](docs/testing.md) describes the harness, the test peer and the live tests on onPC.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [ACCESSIBILITY.md](ACCESSIBILITY.md) and the
[code of conduct](CODE_OF_CONDUCT.md).

## Trademarks and affiliation

Ableton, Link and Live are trademarks of Ableton AG. grandMA3 is a trademark of MA Lighting Technology GmbH.

This project is not affiliated, associated, authorized, endorsed by, or in any way officially connected with Ableton
AG or MA Lighting Technology GmbH. This is not an official Ableton page.
