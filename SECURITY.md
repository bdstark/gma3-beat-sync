# Security policy

## Report a vulnerability privately

Use GitHub's **[Report a vulnerability](https://github.com/bdstark/gma3-beat-sync/security/advisories/new)** to
submit a private report.

If you cannot use GitHub private reporting, email the maintainer at
**[bdstark@gmail.com](mailto:bdstark@gmail.com)** with the subject `gma3-beat-sync security report`. Do not post
exploit details in public issues, pull requests or discussions before the maintainer has had an opportunity to
assess the report and coordinate disclosure.

Include:

- the affected commit and plugin version;
- the exact grandMA3 version, onPC or console, and the network setup;
- the access and settings required, a minimal reproduction, expected versus actual behaviour, and the impact;
- sanitised logs, a packet capture or a small proof of concept, plus any mitigation you have verified.

Do not send credentials, customer show files or proprietary console files. Test only systems and networks you own
or are authorised to test, using a disposable show disconnected from production output.

Reports and fixes are handled on a best-effort basis. There is no guaranteed response or remediation time, bounty
program or commitment to backport fixes. If you have not received a response, follow up privately. Ordinary bugs
and feature requests belong in [GitHub issues](https://github.com/bdstark/gma3-beat-sync/issues).

## Versions

The current development line is `main`; security fixes target that line. Older commits and forks do not receive
automatic fixes. Include the exact revision in a report even if you cannot reproduce it on current `main`.

## Trust boundaries and deployment assumptions

The plugin opens UDP sockets on the console's network. It binds port 20808 on all interfaces and joins the IPv4
multicast group 224.76.78.75, where Link apps announce their sessions (address and port from
`include/ableton/discovery/IpInterface.hpp` in the Link source, `modules/link`). It also sends measurement requests
to the peers it finds.

**The Link protocol has no authentication.** Any device that can send packets to the console's network can:

- announce a session, so the plugin follows its tempo, beat and start/stop state;
- through that, change the configured speed master and trigger the show actions configured for beats, bars, start
  and stop;
- send malformed or oversized packets to the plugin.

So the plugin trusts every device on the networks the console is connected to. Run it only on a network you
control, such as a dedicated show network, and never on a network open to the public or the audience. A firewall
between the show network and other networks should block UDP port 20808. Configure only show actions whose effect
is acceptable if an untrusted device drives the timing.

The plugin is meant to treat every packet as untrusted input: it parses with bounds checks, never executes packet
content, and bounds the work and blocking it does per console frame. Reports of a packet that crashes or stalls
the plugin or the console, makes it run an action that is not configured, makes it read or write files, or makes it
send traffic to an address that is not a peer it measures are welcome. Include the network access required so the
impact can be assessed against this trust boundary.

If you suspect misuse, stop the plugin, disconnect the console from the untrusted network, and check the show state
and the speed masters before resuming operation. Preserve a sanitised packet capture for a private report.
