# Chat Perf — saturation benchmark

Can `examples/chat_perf` saturate the machine? Yes: with 20 concurrent
senders pushing 1 KB payloads for 12 s against 774 members, the server
peaked at **869% CPU (8.7 of 14 cores)**. The load generator was not the
bottleneck (390% peak on its own BEAM). This is the run the baseline
document said was missing: sustained, parallel load instead of one sender
with 200 small messages.

The harness (`../bench/`) and the raw result JSON
(`../bench/results/`) are committed alongside this doc so the numbers can
be re-run, not just quoted.

## Method

- Host: macOS, Apple Silicon, 14 cores, loopback only.
- Server: `tey run` from `examples/chat_perf` (kex 0.4.0-beta.3, OTP 29),
  fresh per run.
- Loader: `bench/wload.erl` (Erlang escript, OTP 27) — one BEAM process
  per connection across all schedulers, each with local delivery counters
  and a local latency histogram, so the generator has no central receive
  bottleneck. Supersedes the single-process Node harness for saturation
  purposes; the Node scripts remain the tool for the baseline methodology.
- macOS's default soft fd limit (256) caps both server and loader well
  below 1000 connections (`emfile` past ~205 clients) — the runner raises
  `ulimit -n` for both process trees before starting.
- CPU is sampled every 0.2 s over the listener's process tree (server) and
  the loader's processes separately. The old sampler hardcoded ports and
  reported `beam=0`; `bench/cpusample.sh` takes the port as an argument.

## Results

### N = 200, count mode (10 senders, 200 × 1024 B each)

| phase | result |
|---|---|
| join | 200/200, wall 157 ms (p50 80 ms) |
| paced (10 msgs @ 10/s) | 2000/2000, p50 1.5 ms |
| flood | 400,000/400,000, loss 0, wall 1.061 s, **377,081 fanout/s**, mean 539 ms / max 1056 ms |
| server CPU | avg 187%, max **696%** |
| loader CPU | avg 105%, max 342% |

### N = 1000, soak mode (20 senders, 12 s, 1024 B payloads)

| phase | result |
|---|---|
| join | 774/1000 within the 90 s join timeout (226 failed — undiagnosed, see caveats) |
| paced (10 msgs @ 10/s) | 7740/7740, p50 4.0 ms |
| soak | 371,117 sent → 11,394,520 deliveries, wall 50.2 s, **226,835 fanout/s**; drain timed out, remainder uncollected |
| server CPU | avg 153%, max **869%** |
| loader CPU | avg 30%, max 390% |

## Findings

1. **The room scales to the hardware, then past comfort.** ~227k
   deliveries/s of 1 KB payloads holds the server at 1.5–8.7 cores. The
   README's ~450k/s figure used 90-byte lines — fan-out throughput is
   byte-size dependent, and the ceiling is the room process's serial cast
   loop (one process, N mailbox casts per message).
2. **Interactive latency survives saturation.** Paced traffic at 10 msg/s
   stays at p50 1.5–4 ms in both runs, matching the baseline.
3. **Loss accounting at saturation is drain-timeout arithmetic**, not proof
   of dropped messages: with 287M expected deliveries the 30 s drain cannot
   catch up. Do not quote `loss` from a saturated run as reliability data —
   quote fanout/s and CPU.
4. **Join admission under a simultaneous burst is the open question.**
   774/1000 in 90 s is far off the README's 1000/1000 in 2.3 s (Node
   harness). Untried: staged `--wave` joins, which are also the more
   realistic shape — a wave run is in progress.
5. **All scaling claims stop at the platform cap.** Both variants top out
   at exactly 1024 concurrent connections regardless of hardware; filed
   upstream as kexhq/kex#390.

## Reproducing

```sh
cd examples/chat_perf/bench
N=1000 SOAK=12 SENDERS=20 PAYLOAD=1024 PACED=10 ruby run-wload.rb
# or, with wave joins and per-client roster sync:
N=1000 WAVE=100 WAVEGAP=500 SYNC=1 SOAK=12 SENDERS=20 PAYLOAD=1024 ruby run-wload.rb
```

`run-wload.rb` wraps server start, CPU sampling (server and loader
separately), the run, and teardown; every knob is an env var (`APP`,
`PORT`, `N`, `PROTO`, `SENDERS`, `FLOOD`/`SOAK`, `PAYLOAD`, `PACED`,
`WAVE`, `WAVEGAP`, `SYNC`, `TIMEOUT`). Needs unsandboxed loopback
networking and a Ruby with stdlib `json`.
`escript wload.erl --selftest` verifies the wire codec and the stats
pipeline with no sockets involved.
