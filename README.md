# gma3-link

A grandMA3 plugin that follows a tempo session on the local network. It is meant to be compatible with Link™,
Ableton's synchronization technology. The plugin sets a speed master to the session's tempo, keeps effects in phase
with its bars, and fires show actions on the beat. It runs entirely inside the console: no computer, helper program,
OSC or MIDI setup is needed.

**Status:** planning. Nothing is implemented yet. The design and the work are in [TICKETS.md](TICKETS.md). The
console's Lua environment has been probed ([docs/probes](docs/probes)). It has not yet been tested against a real
Link session, and no compatibility is claimed until the applicable cases of Link's
[test plan](https://github.com/Ableton/link/blob/master/TEST-PLAN.md) pass.

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

[GrandMA3MCP](https://github.com/bdstark/GrandMA3MCP), an MCP server for grandMA3, will read this plugin's status and
configure its actions. It talks to the plugin only through the console and shares no code with this repository.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).

- **Protocol code:** the plugin implements the Link network protocol in Lua. It is written from Ableton's Link
  source code, which is published under the GPL version 2 or later (Copyright 2016, Ableton AG). This repository
  is licensed the same way.
- **The Link library:** used only to build a test peer for this repository's tests. It is included as a git
  submodule under its own license (GPL version 2 or later), with its own third-party dependencies.

## Trademarks and affiliation

Ableton, Link and Live are trademarks of Ableton AG. grandMA3 is a trademark of MA Lighting Technology GmbH.

This project is not affiliated, associated, authorized, endorsed by, or in any way officially connected with Ableton
AG or MA Lighting Technology GmbH. This is not an official Ableton page.
