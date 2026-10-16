# Probe: the console as a full Link peer (BS-03, 2026-10-16)

BS-01 decided "follower only", from an estimate: a plugin answers measurement pings only once per frame (9.3 ms
median round trip), which it expected to cost a measuring peer about 4.7 ms. This probe measured that error, and a
way to remove it.

grandMA3 onPC 2.5.1 (macOS), the disposable show `NewShow_2026.10.15_23.16.24UTC`, the console lock held. No other
Link app was running (LinkMaster stopped at the maintainer's request), so the announcing console could not affect
anyone's session. Nothing was changed on the console. Scripts: [bs-03/](bs-03/); raw output:
[bs-03/results/](bs-03/results/).

## Method

`peer_probe.mjs` starts `gbs-test-peer` (BS-04) in its own session at 100 BPM, printing its phase with the wall
clock every 5 ms. It then runs `peer_chunk.lua` in the console for 4.5 s through gma3-mcp's bridge. The chunk:

- founds a session at 120 BPM whose timeline is exact by construction: beat 0 at ghost time 0, and ghost time is the
  console's wall clock in µs;
- announces it every 250 ms in the Link message layouts (`discovery/v1/Messages.hpp`, `link/PeerState.hpp`);
- answers measurement pings once per frame, as `link/PingResponder.hpp` does: session id, the ghost time, and the
  ping's payload.

The test peer sees the console's session and measures it through those replies. It joins the session because its
ghost time is far ahead (`link/Sessions.hpp`), 0.4–0.8 s after the console appears. After the join, its phase is
compared with the console's exact phase at the same wall-clock instant, every 5 ms. The difference is the error the
console's replies cause.

## Results

| Replies | Error of the joining peer (mean; min–max within the run) | Runs |
| --- | --- | --- |
| ghost time stamped when the reply is sent | +7.98, +8.06, +8.03 ms (each within ±0.05 ms) | 3 |
| stamped half way between the ping's earliest arrival and the reply, first version | −0.14, −10.64, −0.12 ms | 3 |
| the same, with the earliest arrival also bounded by the console's previous reply | −0.13, −0.09, −0.16, −0.14 ms (each within ±0.3 ms) | 4 |

All 52 pings in each run were answered. A positive error means the peer's beats run early.

- **Why 8 ms and not 4.7.** Link pings again as soon as a pong arrives (`link/Measurement.hpp`), so after the first
  exchange each ping arrives just after the console's previous reply and waits almost a full frame (16.7 ms). The
  measuring peer assumes the ghost time was taken half way through its round trip (`link/Measurement.hpp`: ghost −
  (send + receive) / 2), so it is off by half the wait. That error is systematic, not random, which is what makes it
  correctable.
- **The compensation.** A ping cannot have arrived before the console's last look at its socket, which is the end of
  the previous frame's check, or the console's previous reply in the same frame, whichever is later. Stamping the pong
  with the ghost time half way between that moment and the reply puts the stamp near the midpoint of the peer's round
  trip.
- **The first version's outlier.** In run 2, the peer's next ping sometimes arrived while the console was still
  reading its socket in the same frame. That ping was answered at once but stamped as if it had waited a frame. The
  earliest arrival is now also bounded by the console's previous reply. With that, four of four runs were within
  0.16 ms.

## Conclusion

With compensated replies, a full peer in a plugin is accurate enough: within 0.2 ms, far inside the 3 ms of Link's
AUDIOENGINE-1 case. This reverses BS-01's "follower only" for BS-03, which the maintainer chose to build (as an opt-in
mode; the follower stays the default).

Not covered by this probe:

- other computers and real network jitter;
- Ableton Live measuring through the console;
- Link's re-measurement every 30 s;
- longer sessions;
- the console joining a session it did not found.

BS-03's live tests cover what the test peer can.
