# gma3-beat-sync

A grandMA3 plugin that follows a tempo session on the local network. It is meant to be compatible with Link™,
Ableton's synchronization technology. The plugin sets a speed master to the session's tempo, keeps effects in phase
with its bars, and fires show actions on the beat. It runs entirely inside the console: no computer, helper program,
OSC or MIDI setup is needed.

**Status:** in development. The plugin follows a session and drives a speed master, `ReSync` and commands on
beats, bars, start and stop; see [docs/plugin.md](docs/plugin.md). On grandMA3 onPC 2.5.1, the follower cases of
Link's [test plan](https://github.com/Ableton/link/blob/master/TEST-PLAN.md) pass against a test peer built from the
Link library and against Ableton Live, whose session was relayed to the console's computer by another app
([record](docs/probes/bs-02-live-ableton-2026-10-16.md)). An opt-in peer mode lets the console take part in the
session: its speed master's tempo and its start and stop reach the other apps. Its test plan cases pass against the
test peer ([record](docs/probes/bs-03-peer-live-2026-10-16.md)). The work is in [TICKETS.md](TICKETS.md).

## How it works

The console has no Link input, but its Lua plugins can use UDP sockets. The plugin:

1. listens for the announcements of the Link apps on the network (tempo, timeline, start/stop);
2. measures its clock against one of them;
3. on every console frame:
   - computes the current beat and bar;
   - sets the speed master's BPM when the tempo changes;
   - realigns sequences on the bar;
   - runs the commands configured for the beat.

The console runs plugins once a frame, about every 16.6 ms on onPC 2.5.1, so an action runs within about ±8 ms of
its beat, and the console shows its effect about a frame later (`BeatSync.LeadMs` makes up for that).

## The bridge for gma3-phrase-sync (`bridge/`)

A second, separate program in this repository: `link-bridge` publishes the tempo and bar phase of
gma3-phrase-sync (which follows Pioneer CDJs) to a Link session, and reports the session back to it. The
service stays MIT-licensed and contains no Link code; it sends its timeline over loopback UDP in a small protocol,
LB1 or LB2, specified in [`docs/link-bridge.md`](https://github.com/bdstark/link-bridge-protocol/blob/1ef87da471bbef2adf52ed287e30206aaa488004/docs/link-bridge.md) of the MIT crate
[link-bridge-protocol](https://github.com/bdstark/link-bridge-protocol). The bridge is written in Rust, uses Ableton's Link library
from `modules/link` through its C wrapper (`abl_link`), and shares no code with the console plugin.

```sh
cargo run -p link-bridge -- --listen 127.0.0.1:7822
```

Then set `[sink.link] bridge = "127.0.0.1:7822"` in gma3-phrase-sync's configuration. The bridge:

- listens on a loopback address only (`127.0.0.1:7822` by default) and ignores datagrams from anywhere else;
- answers every clock ping at once, stamped with the Link clock when the ping arrived;
- takes timelines in order within a run of the service, and lets a restarted service's run replace the old one;
- while the deck plays, sets the session's tempo and aligns the session's bar phase so the deck's beat falls when it
  says (the phase, not the beat count, so a new track starting on another bar number moves nothing); while it is
  stopped, sets the tempo only;
- shares start and stop with the session only with `--start-stop` (off by default);
- lets go of the session after the service says goodbye or sends nothing for 3 s, leaving the tempo and phase as
  they are, and stays in the session;
- answers each message in its own revision (LB1 or LB2), so a service that speaks only LB1 works as before;
- reports the session to a service that pings in LB2 (`SESSION`): its tempo, the beat in bars of `--quantum` beats
  (4 by default), whether it plays (when start/stop is shared), the peers, and whether its tempo or phase is that
  service's own timeline. A report follows each pong and each change (0.001 BPM, 1 ms of phase, peers and the rest),
  at most 20 a second;
- answers a sender speaking a newer protocol revision with its own newest (`VERSION`), at most once a second.

It needs Rust 1.99 or later, CMake 3.16 or later and a C++ compiler. The protocol's messages come from the
`link-bridge-protocol` crate, which Cargo fetches from its repository at a pinned revision.
Tests: `scripts/check.sh bridge` ([docs/testing.md](docs/testing.md#the-bridge-bridge)). The work is tickets BS-05
and BS-06 in [TICKETS.md](TICKETS.md).

## Related projects

[gma3-mcp](https://github.com/bdstark/gma3-mcp), an MCP server for grandMA3, will read this plugin's status and
configure its actions. It talks to the plugin only through the console and shares no code with this repository.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).

- **Protocol code:** the plugin implements the Link network protocol in Lua. It is written from Ableton's Link
  source code, which is published under the GPL version 2 or later (Copyright 2016, Ableton AG). This repository
  is licensed the same way.
- **The Link library:** used to build a test peer for this repository's tests, and linked into the bridge
  (`bridge/`). It is included as a git submodule under its own license (GPL version 2 or later), with its own
  third-party dependencies. Nothing from it is shipped in the plugin.
- **The bridge's dependencies:** [`link-bridge-protocol`](https://github.com/bdstark/link-bridge-protocol) (MIT), `ctrlc` (MIT or Apache-2.0)
  and, to build, `cmake` (MIT or Apache-2.0), with their own dependencies listed in `Cargo.lock`.

### Third-party code in `modules/`

| Path | What | Version | License |
| --- | --- | --- | --- |
| `modules/link` | [Link](https://github.com/Ableton/link), Copyright 2016, Ableton AG | tag `Link-4.1` | GPL-2.0-or-later ([LICENSE.md](https://github.com/Ableton/link/blob/Link-4.1/LICENSE.md)) |
| `modules/link/modules/asio-standalone` | [Asio](https://github.com/chriskohlhoff/asio), Link's network library (its own submodule) | `asio-1-38-2`, pinned by Link | Boost Software License 1.0 (`LICENSE_1_0.txt`) |
| `modules/link/third_party/catch` | Catch, the test framework Link's own unit tests use; not built here | bundled with Link | Boost Software License 1.0 (header of `catch.hpp`) |

## Development

Clone with the submodules, then run the checks (stock Lua 5.5 as `lua` and `luac`, CMake 3.16 or later, a C++
compiler and `python3` are needed; the bridge also needs Rust):

```sh
git clone --recurse-submodules https://github.com/bdstark/gma3-beat-sync.git
cd gma3-beat-sync
scripts/check.sh
```

`scripts/check.sh` checks the SPDX headers, parses every Lua file with Lua 5.5, runs the Lua harness, builds the
test tools from `modules/link` and checks the fixtures against Link's own parser and arithmetic. CI runs the same
steps. `scripts/check.sh bridge` checks the bridge (`cargo fmt`, `clippy` and its tests); it is separate from the
others because it needs Rust. [docs/testing.md](docs/testing.md) describes the
harness, the test peer, the bridge's tests and the live tests on onPC.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [ACCESSIBILITY.md](ACCESSIBILITY.md) and the
[code of conduct](CODE_OF_CONDUCT.md).

## Trademarks and affiliation

Ableton, Link and Live are trademarks of Ableton AG. grandMA3 is a trademark of MA Lighting Technology GmbH.

This project is not affiliated, associated, authorized, endorsed by, or in any way officially connected with Ableton
AG or MA Lighting Technology GmbH. This is not an official Ableton page.
