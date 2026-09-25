# Chat example — baseline scalability benchmark

The "before" numbers for `examples/chat_perf`: how `examples/chat` (as of this
measurement) scales as a broadcast room grows, and where it stops. The perf
variant exists to attack exactly the walls this run found; its README carries
the side-by-side comparison.

## Method

- Server: `tey run` from `examples/chat`, fresh per rung, loopback
  (127.0.0.1), macOS, app BEAM on Homebrew Erlang/OTP 29.
- Load: a single-process Node 22 generator (`WebSocket` client, no
  dependencies) that opens N connections with unique names, confirms each
  join by the roster line carrying the member's own name, then runs three
  phases:
  1. **join** — all N connections opened at once (a join storm);
  2. **paced** — 30 chat messages at 10 msg/s (an interactive room's rate);
  3. **flood** — 200 chat messages back-to-back (~90-byte lines).
- Latency is end-to-end per delivery: send timestamp embedded in the payload,
  compared against arrival time (same host, `Date.now()`).
- Rungs: N = 10, 50, 100, 250, 500, 1000, 2000, plus repeats at the top to
  separate the failure modes. Raw per-rung JSON lives beside the generator.

## Results

| N | join wall | paced p50/p95 | flood msg/s | fan-out deliv./s | flood p50 / p99 | server RSS |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 32 ms | 0 / 1 ms | 18,182 | 181,818 | 5 / 9 ms | 216 MB |
| 50 | 53 ms | 1 / 1 ms | 4,167 | 208,333 | 23 / 45 ms | 224 MB |
| 100 | 148 ms | 1 / 1 ms | 2,299 | 228,311 | 48 / 85 ms | 243 MB |
| 250 | 814 ms | 1 / 2 ms | 913 | 228,311 | 112 / 216 ms | 301 MB |
| 500 | 3.1 s | 2 / 3 ms | 431 | 215,517 | 235 / 458 ms | 309 MB |
| 1000 | 17.2 s | 3 / 6 ms | 198 | 198,413 | 492 / 996 ms | ~380 MB |

N = 1000 detail (the one rung at which every phase completed): paced latency
p99 6 ms with 30,000/30,000 deliveries; flood drained 200 broadcasts to all
1000 members in 1.008 s, broadcast-completion latency p50 497 ms / p99 1001 ms.

An idle-hold of 35 s at N = 250 produced zero disconnects — idle members are
not dropped (the `receiveMessage` timeout fix holds under load).

## Findings

1. **Interactive latency is flat.** At a human 10 msg/s, p95 stays 1–6 ms all
   the way to 1000 members. Ordinary chat traffic does not stress this design
   at any room size it can reach.
2. **The room process has a fixed send budget.** Fan-out throughput is
   constant at ~200–230k deliveries/s whether N is 10 or 1000: the single
   `serving Room` process performs every `socket.send` inline
   (`room.kex`'s `broadcast`), so per-message cost grows linearly with N
   (~0.5 ms per 100 members) and a flood's queue-drain latency grows with it.
3. **Join cost is quadratic.** Each join broadcasts a system line plus the
   full roster — an O(N)-sized string — to all N members: N joins cost O(N²)
   bytes and sends. Join wall grows 32 ms → 17.2 s from N=10 → 1000.
4. **A slow socket stalls everyone.** Near saturation (N ≳ 800), identical
   join storms admitted anywhere from 653 to 1000 of 1000 clients across
   runs: a `socket.send` that blocks on a full TCP buffer blocks the room
   process itself, and join confirmations queue behind it. Only *failed*
   sends prune a member; a merely stuck one waits.
5. **Hard ceiling: 1024 concurrently serviced connections.** At N = 2000,
   TCP accepts every connection (2000 ESTABLISHED) but exactly 1024
   WebSocket handshakes ever complete. This is **not** BEAM's port table:
   `-Q 8192` was verified present in the app BEAM's argv (via a `KEX_ERL`
   wrapper — `ERL_AFLAGS` does not reach the app because `tey run` execs the
   `kex` toolchain binary, which execs BEAM directly) and the wall did not
   move. The cap is in the Kex socket layer and has the shape of a classic
   `FD_SETSIZE`/`select` limit on macOS. Nothing an application does can
   raise it today.
6. **Below the ceiling, zero loss.** No dropped deliveries, no spurious
   closes, no server errors or crashes at any rung; ~190 KB of server memory
   per connection over the ~200 MB BEAM baseline.

## What this implies for `chat_perf`

- Move sends out of the room process: one writer process per member, so
  fan-out runs in parallel across schedulers and a stuck socket stalls only
  itself.
- Stop broadcasting the roster: `$join:`/`leave:` deltas are O(1) bytes per
  member; the full list becomes something a client asks for — paginated —
  when it wants it.
- Targets: flood fan-out well above 230k deliv./s, join wall well under 17 s
  at N = 1000, paced latency no worse than baseline, and no join-storm
  collapse below the 1024-connection platform cap.

## Reproducing

The generator and per-rung JSON outputs live in
`/var/folders/m3/_sxhj6qs5zg90_0qksc_hchr0000gn/T/opencode/chat-bench/`
(`bench.mjs`, `run-ladder.sh`, `results.jsonl`), a scratch directory; copy
them somewhere durable before it is cleaned. `node bench.mjs --port 3000
--clients 100` runs a single rung against any running chat server.
