# Contributing

Please follow the [code of conduct](CODE_OF_CONDUCT.md) in all project interactions.
For documentation and user-facing changes, follow the [accessibility guidance](ACCESSIBILITY.md).

Contributions are welcome: bug reports, documentation corrections, console and network test results and focused
code changes. This is an independent project at the planning stage; [TICKETS.md](TICKETS.md) lists the planned work
and what has been tested. For suspected vulnerabilities, use [private security reporting](SECURITY.md) instead of a
public issue or pull request.

## Licence of contributions

This repository is licensed under the GNU General Public License, version 2 or (at your option) any later version
([LICENSE](LICENSE)). By submitting a contribution you agree that it is licensed under the same terms,
GPL-2.0-or-later, and you confirm that you have the right to contribute it under those terms.

- Every source file starts with `SPDX-License-Identifier: GPL-2.0-or-later` in its first five lines.
  `scripts/check.sh spdx` checks this.
- Do not copy code from projects under licences that are incompatible with GPL-2.0-or-later.
- Do not copy MA Lighting documentation, proprietary console files or show files into the repository.
- The Link library in `modules/link` is a git submodule under its own licence. Change it only by moving the
  submodule to another release tag, never by editing files inside it.

## Trademarks and compatibility claims

- Ableton, Link and Live are trademarks of Ableton AG. Write the mark as "Link™" or "Link", never as part of this
  project's name, and less prominently than the project's own name. Use compatibility wording, such as
  "compatible with Link".
- Do not add Ableton logos or other Ableton visual assets.
- Keep the trademark and affiliation notices in [README.md](README.md#trademarks-and-affiliation).
- Do not claim compatibility with Link until the applicable cases of Link's
  [TEST-PLAN.md](https://github.com/Ableton/link/blob/master/TEST-PLAN.md) pass, and record the evidence:
  BEATTIME-1, BEATTIME-2 and STARTSTOPSTATE-1 for a follower; TEMPO-1 to TEMPO-5 and STARTSTOPSTATE-2 for a full
  peer.

## Protocol facts

Every statement about the Link network protocol (message layout, field sizes, timing, addresses) cites the file in
the Link source it comes from, for example `include/ableton/discovery/v1/Messages.hpp`, at the submodule's pinned
tag, or a packet capture stored as a test fixture. Record new facts in a probe record in `docs/probes/`.

## Report a bug or propose a feature

Open a [GitHub issue](https://github.com/bdstark/gma3-beat-sync/issues). For bugs, include:

- the repository commit and plugin version;
- the exact grandMA3 version, and whether it is onPC (with its operating system) or a console;
- the other apps in the session and their versions, and the network setup (wired, Wi-Fi, same machine);
- a minimal reproduction, expected behaviour, observed behaviour and sanitised logs or plugin status.

Remove credentials, private paths and identifying show data. Use a small synthetic show instead of uploading a
production show.

## Set up and check a change

Fork the repository, create a branch from current `main`, and clone with the submodules:

```sh
git clone --recurse-submodules https://github.com/bdstark/gma3-beat-sync.git
# in an existing clone:
git submodule update --init --recursive
```

You need stock Lua 5.5 (the console's version) as `lua` and `luac`, CMake 3.16 or later, a C++ compiler and
`python3` (one test parses the test peer's JSON output with it). From the repository root:

```sh
scripts/check.sh
```

This runs the SPDX check, the Lua 5.5 syntax check, the Lua harness (`test/lua/*_test.lua`) and the test peer build.
CI runs the same steps. Add focused regression tests for changed behaviour, including failure paths: malformed
packets, a lost peer, a missing speed master or sequence, and late frames. Keep tests independent of a console where
possible. Explain any checks you could not run.

## Live testing

Live tests on a console are separate and optional unless needed to substantiate console behaviour.

- Use a disposable show, with no live output driving a production rig.
- The plugin opens UDP sockets and joins a multicast group on the console's network. Test on a network you control.
- Record the exact commit, console version, platform, network, the other apps in the session, the procedure and the
  observed results. Distinguish untested cases from failures.

## Preserve the plugin's guarantees

- The plugin never stalls the console. Blocking socket calls are bounded to a few milliseconds per frame.
- Failures are reported, never hidden: no session, a lost peer, a speed master or sequence that does not exist, a
  dropped frame.
- Packets from the network are untrusted input. Parse them with bounds checks and never execute their content.
- The plugin works on its own. It does not depend on gma3-mcp or any other plugin.

## Submit a pull request

Describe the concrete problem, the resulting behaviour, the tests and any limitations. Link the ticket or issue.
Include live evidence when the change relies on undocumented console behaviour or on the behaviour of other Link
apps, or state that it remains unverified. Keep build output, local configuration, secrets and show data out of the
patch. Review is best effort; a contribution does not imply support for every console version or network setup.
