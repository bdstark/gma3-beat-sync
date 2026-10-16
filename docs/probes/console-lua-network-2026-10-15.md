# Probe: the console's Lua and UDP networking (2026-10-15)

grandMA3 onPC 2.5.1 on macOS. The scripts below ran inside the console through GrandMA3MCP's bridge plugin (its
`lua` request), on a disposable show. No show data changed, and every socket was closed. No Link peer was running.

## Results

- **Lua version:** `_VERSION` is `Lua 5.5`. `string.pack` and `string.unpack` exist, and integers are 64-bit, which
  covers microsecond timestamps.
- **LuaSocket:** version `3.0-rc1`, loaded with `require("socket")`. `socket.gettime()` is available.
- **Use `socket.udp4()`.** `socket.udp()` creates its socket lazily, so `setoption` before binding fails with
  "setsockopt failed".
- **What works with `socket.udp4()`:**
  - `reuseaddr` and `reuseport`;
  - binding `0.0.0.0:20808` twice at the same time (two sockets on the port, as with another Link app on the same
    machine);
  - `ip-add-membership` for `224.76.78.75`;
  - `ip-multicast-loop`.
- **Blocking is bounded.** A blocking receive with a 3 ms timeout returned after 3.4 ms on the plugin thread.
- **Frame period:** a chunk that yields once per frame measured 60 frames: median 16.6 ms, 90th percentile 17.3 ms,
  minimum 11.9 ms, maximum 21.2 ms (60 Hz).
- **Packets:** none were received in 60 frames, as expected with no peer running.

## Still open (GL-01)

- Real announcements and their parsing.
- Whether peers answer measurement pings from a follower that never announced itself.
- Two plugin loops at once.
- `ReSync` behaviour, and the drift over time.

## Scripts

Capabilities and frame timing (the first version used `socket.udp()`, which is why its option calls failed):

```lua
local socket = require("socket")
local r = { lua = _VERSION, unpack = type(string.unpack), socketVersion = socket._VERSION, gettime = type(socket.gettime) }
local u = socket.udp4()
u:setoption("reuseaddr", true)
u:setoption("reuseport", true)
assert(u:setsockname("0.0.0.0", 20808))
assert(u:setoption("ip-add-membership", { multiaddr = "224.76.78.75", interface = "0.0.0.0" }))
u:settimeout(0.003)
local t0 = socket.gettime(); u:receivefrom(); r.blockingReceive3msTookMs = (socket.gettime() - t0) * 1000
u:settimeout(0)
local ts, packets = {}, 0
for i = 1, 60 do
  ts[#ts + 1] = socket.gettime()
  coroutine.yield() -- resumed on the console's next frame
  while u:receivefrom() do packets = packets + 1 end
end
local ds = {}
for i = 2, #ts do ds[#ds + 1] = (ts[i] - ts[i - 1]) * 1000 end
table.sort(ds)
r.frameMs = { min = ds[1], median = ds[#ds // 2], p90 = ds[math.floor(#ds * 0.9)], max = ds[#ds] }
r.packets = packets
u:close()
return r
```

Port sharing:

```lua
local s = require("socket")
local u, v = s.udp4(), s.udp4()
for _, k in ipairs({ u, v }) do k:setoption("reuseaddr", true); k:setoption("reuseport", true) end
local a = u:setsockname("0.0.0.0", 20808)
local b = v:setsockname("0.0.0.0", 20808)
local m = v:setoption("ip-add-membership", { multiaddr = "224.76.78.75", interface = "0.0.0.0" })
local l = v:setoption("ip-multicast-loop", true)
u:close(); v:close()
return { a, b, m, l } -- all 1
```
