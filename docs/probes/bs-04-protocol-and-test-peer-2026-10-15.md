# Probe: the Link protocol, the test peer and a first console follow (2026-10-15)

BS-04. Link source at tag `Link-4.1` (`modules/link`); paths below are relative to
`modules/link/include/ableton`. Tests ran on macOS with grandMA3 onPC 2.5.1 on the same machine, on the disposable
show `NewShow_2026.10.15_23.16.24UTC`, with the console lock held. No show data changed and every socket was
closed.

## Protocol facts used by `plugin/beat_sync_protocol.lua`

All integers are big endian (network byte order, `discovery/NetworkByteStreamSerializable.hpp`). Times are
`std::chrono::microseconds` as int64; beats are `Beats`, int64 micro-beats (`link/Beats.hpp`).

### Discovery (`discovery/v1/Messages.hpp`, `discovery/UdpMessenger.hpp`, `discovery/PeerGateway.hpp`)

- Multicast group 224.76.78.75, port 20808 (`discovery/IpInterface.hpp`, `multicastEndpointV4()`). IPv6 uses
  ff12::8080 on the same port.
- A message is at most 512 bytes (`kMaxMessageSize`).
- Header, 20 bytes: `_asdp_v\x01` (8), message type (1), ttl (1), session group id (2), node id (8).
  - Types: 1 Alive, 2 Response, 3 ByeBye; 0 is invalid. Messages from other group ids and from the node itself are
    ignored.
  - A message shorter than 20 bytes or without the protocol header is read as type 0 and ignored.
- An Alive is answered with a unicast Response to its sender (`UdpMessenger::operator()`). A follower that never
  announces itself therefore receives only the multicast Alive messages, which is enough.
- Ttl 5 s; peers broadcast every ttl / 20 = 250 ms, at most every 50 ms (`PeerGateway.hpp`: `ttl = 5`,
  `ttlRatio = 20`; `UdpMessenger::broadcastState`). A peer is dropped when its ttl passes without an announcement
  (`PeerGateway::onPeerState`, the prune timer), or at once on a ByeBye.
- The payload of a ByeBye is not read.

### Payload entries (`discovery/Payload.hpp`, `link/PeerState.hpp`, `link/NodeState.hpp`)

- Each entry: key (4 bytes), size (4), value (size bytes). Unknown keys are skipped.
- An entry header that does not fit, or a size beyond the message, makes the whole message invalid
  (`parseByteStream` throws; `UdpMessenger::receivePeerState` drops the message).
- A known entry whose value does not consume exactly its size also invalidates the message (`ParsePayload`).
  Exception: a node id (`std::array<uint8_t, 8>`, read by `Deserialize<std::array>`) shorter than 8 bytes fills
  the first bytes and leaves the rest zero, so `sess` with 0 to 7 bytes is accepted. A longer one fails.
- Duplicate keys: each one is parsed, so the last wins.
- Entries in an Alive or Response (`PeerState::toPayload`):

  | Key | Source | Value |
  | --- | --- | --- |
  | `tmln` 0x746d6c6e | `link/Timeline.hpp` | micros per beat (int64), beat origin (micro-beats), time origin (ghost µs) |
  | `sess` 0x73657373 | `link/SessionId.hpp` | session id, the node id of the session's founder (8 bytes) |
  | `stst` 0x73747374 | `link/StartStopState.hpp` | playing (1 byte, non-zero is true), beats, timestamp (ghost µs) |
  | `mep4` 0x6d657034 | `link/PeerState.hpp`, `link/EndpointV4.hpp` | measurement endpoint: IPv4 address (4), port (2) |
  | `mep6` 0x6d657036 | `link/PeerState.hpp`, `link/EndpointV6.hpp` | measurement endpoint: IPv6 address (16), port (2) |
  | `aep4`, `aep6` | `link/PeerState.hpp` | audio endpoints (Link 4 audio); not used by this project |

  An endpoint of the other IP version has size 0 and is not sent.

### Measurement (`link/v1/Messages.hpp`, `link/Measurement.hpp`, `link/PingResponder.hpp`, `link/MeasurementService.hpp`)

- Header, 9 bytes: `_link_v\x01` (8), message type (1): 1 ping, 2 pong.
- Entries: `__ht` 0x5f5f6874 host time, `__gt` 0x5f5f6774 ghost time, `_pgt` 0x5f706774 previous ghost time
  (`link/PayloadEntries.hpp`), each an int64 of µs.
- **A peer answers any ping** whose payload is at most 32 bytes (the size of `__ht` + `_pgt`), from any sender; it
  does not check that the sender is a peer (`PingResponder::Impl::operator()`). The pong carries `sess`, `__gt`
  (the responder's ghost time now), then the ping's payload copied back.
- The measuring side sends a ping with `__ht`; on each pong of the same session it records up to two data points
  and pings again with `__ht` and `_pgt` (the pong's `__gt`):
  - `ghost - (host_now + echoed_host) / 2`;
  - when the pong carries `_pgt`: `(ghost + prev_ghost) / 2 - echoed_host`.
  - A value of 0 means absent.
- It stops after more than 100 points, or fails after 5 timeouts of 50 ms. The result is
  `GhostXForm{1, llround(median(points))}`: ghost = host + intercept (`link/GhostXForm.hpp`, `link/Median.hpp`).
- Sessions are re-measured every 30 s (`link/Sessions.hpp`, the 30 000 000 µs timer).

### Timeline arithmetic (`link/Timeline.hpp`, `link/Tempo.hpp`, `link/Phase.hpp`, `link/ClientSessionTimelines.hpp`)

- `toBeats(t) = beatOrigin + llround((t - timeOrigin) / microsPerBeat * 1e6)` and its inverse `fromBeats`. Link
  holds the tempo as a double bpm (`60e6 / microsPerBeat`) and rounds it back with `llround`.
- Beat 0 of the session timeline is the origin of the quantum grid for all participants
  (`updateClientTimelineFromSession`). So the session's phase at ghost time g is `phase(toBeats(g), quantum)`.
- Tempo range 20 to 999 bpm (`clampTempo`).
- Within a session, a peer adopts another peer's timeline when its beat origin is larger (`Sessions.hpp`,
  `sawSessionTimeline`). Between sessions, the one whose ghost time is ahead by more than 500 ms wins, or, within
  500 ms, the smaller session id (`Sessions.hpp`, `handleSuccessfulMeasurement`). BS-02 needs both.

## Tools built (tools/test-peer)

- `gbs-test-peer`: joins a session through Link's own `ableton::Link`, sets the tempo, starts and stops from
  stdin commands, and prints its beat, phase and tempo as JSON lines with the wall clock.
- `gbs-capture`: records the session's packets and ping/pong exchanges as fixtures and labels each packet with
  Link's own parser, so the Lua harness compares its parser with Link's, packet by packet. `--decode` labels
  hand-made packets (`test/fixtures/make_variants.lua`).
- `gbs-vectors`: prints reference values from Link's arithmetic (4 589 cases); the harness reproduces all of them
  exactly.

## Observations

- **Same-machine peers are heard only on the loopback interfaces.** On this Mac a socket that joined the group on
  the default interface (en0, which is what `0.0.0.0` picks) received nothing from a test peer on the same machine,
  while two Link peers saw each other. Link joins the group on every interface address
  (`platforms/asio/Context.hpp`), and the packets arrived on 127.0.0.1 and on a second loopback address. Joining on
  127.0.0.1 as well fixed it, both for `gbs-capture` and inside the console. The plugin must join on loopback too
  for a peer on the same machine (onPC with Live on the same computer). LuaSocket cannot list interfaces, so the
  plugin will need the interface addresses from configuration or from the console.
- **Start right after enabling is lost in Link itself.** A play committed 200 ms after `Link::enable(true)` was
  never announced; plays 600 ms and 1.1 s after it were. Enabling resets the session's start/stop state on Link's
  thread (`link/Controller.hpp`, `resetState()`). `gbs-test-peer --play` therefore plays 1 s after enabling.
- The capture contains the machine's loopback addresses only; the hand-made variants use documentation-style
  private addresses.

## First console follow (live test)

`test/live/follow_test_peer.mjs` ran `test/live/follow_chunk.lua` inside the console through gma3-mcp's bridge
(`lua` request; the bridge is only the development path for running code on the console). The chunk joined the
group on 127.0.0.1 and 0.0.0.0, found the test peer's Alive, measured with 51 ping/pong exchanges (101 points,
at most 10 exchanges per frame, each receive bounded to 3 ms), then sampled the session's phase at the start of
120 frames. The script compared each sample with the test peer's own phase at the same wall-clock instant.

| Scenario | Judged samples | Phase error mean / median / p95 / max | Notes |
| --- | --- | --- | --- |
| steady, 133.5 bpm, playing | 120 | 0.009 / 0.010 / 0.017 / 0.022 ms | |
| tempo change to 140 bpm during the follow | 114 (6 in the 100 ms after the change not judged) | 0.009 / 0.009 / 0.016 / 0.017 ms | 1 timeline update seen; tempo matched after it |
| stopped | 120 | 0.009 / 0.009 / 0.017 / 0.018 ms | start/stop state matched |

- Measurement took 82–98 ms over 5 frames. Round trips: median 82–112 µs; maximum 387 µs to 15.9 ms. One
  exchange that should have been bounded to 3 ms returned after 15.9 ms, so the plugin thread can be descheduled
  during a receive. A late pong would then be read by the next exchange; BS-02 must pair each pong with its ping
  (the echoed `__ht`) and discard others.
- Frames: median 16.68 ms, maximum 33.7 ms (one frame dropped).
- **Tolerance stated for the live test: 1 ms phase error**, judged on every sample except the 100 ms after a tempo
  change. All three scenarios passed with a maximum of 0.022 ms. The error is measured at the instant the sample
  is taken; when an action fires depends on the frame, which BS-02 measures.
- Not yet tested: a peer on another machine, Ableton Live, two sessions, peers leaving, and the plugin's own loop
  (BS-01, BS-02).
