# Chat Perf

The perf-focused sibling of `examples/chat`: the same broadcast WebSocket
chat room — shared password, display name per connection — rebuilt around
the two walls its baseline benchmark hit (see
[docs/baseline-benchmark.md](docs/baseline-benchmark.md) for the "before"
numbers and how they were measured).

## What changed, and why

| | `examples/chat` (baseline) | `chat_perf` |
| --- | --- | --- |
| who sends | the room process, inline, on every broadcast | one writer process per member; the room only casts |
| join/leave traffic | the full roster, to everyone, on every join — O(N²) bytes over N joins | a one-name `$join:`/`$leave:` delta — O(1) bytes per member |
| the full roster | pushed on every join | pulled by the client, a page at a time (`$roster:<n>`) |
| dead connections | pruned when a broadcast's send fails | the member's own writer closes the socket, which fails its handler into `leave` |

The structural point of the writer processes: the room process never touches
a socket, so fan-out runs in parallel across schedulers and a member whose
TCP buffer is full stalls only its own writer. In the baseline, one stuck
`socket.send` stalled the whole room — joins included — which is what made
join storms collapse around ~800 members.

The structural point of the deltas: the client keeps its own roster — the
room's `* X joined` lines are for the log; `$join:`/`$leave:` maintain the
set; `$users:<page>/<pages>:` pages are the answer to `$roster:<n>`, used on
connect and by the roster's "sync" button. A join is now O(1) bytes per
existing member no matter how big the room is.

Known wrinkle, shared with the baseline's wire format: lines are told apart
by prefix and a display name is just a query parameter, so a name that looks
like `$join:` reaches the page looking like one. Nothing is injected — every
line is built with `textContent` — but a real protocol would tag each line
rather than trust a prefix. Kept identical so the two examples stay
comparable.

Also shared with the baseline: the platform's hard ceiling of 1024
concurrently serviced connections (docs/baseline-benchmark.md, finding 5) —
that one lives below anything an application can do.

## Results against the baseline

Same host, same harness, same methodology as
[docs/baseline-benchmark.md](docs/baseline-benchmark.md) (storm joins; 200
back-to-back ~90-byte lines for the flood):

| N | join wall | flood fan-out | flood latency p50/p99 |
|---:|---|---|---|
| 10 | 32 ms → 34 ms | 182k/s → 250k/s | 5/9 ms → 5/7 ms |
| 50 | 53 ms → 45 ms | 208k/s → 526k/s | 23/45 ms → 9/17 ms |
| 100 | 148 ms → 64 ms | 229k/s → 465k/s | 48/85 ms → 25/41 ms |
| 250 | 814 ms → 188 ms | 228k/s → 485k/s | 112/216 ms → 53/100 ms |
| 500 | 3.1 s → 0.63 s | 216k/s → 455k/s | 235/458 ms → 111/216 ms |
| 1000 | 17.2 s → 2.3 s | 198k/s → 458k/s | 492/996 ms → 222/433 ms |

- **Fan-out roughly doubles and stops depending on N's drain penalty**: the
  baseline's serialized sends pinned every rung at ~200–230k deliveries/s;
  the writers lift it to ~450–530k/s, with flood latency p50 roughly halved
  at every size. The new ceiling is the room process casting to N mailboxes —
  one process again, but each cast is ~an order of magnitude cheaper than a
  socket send.
- **Join stops being quadratic-in-practice**: 5–7× faster walls at the top
  rungs, and the baseline's collapse is gone — identical 1000-client join
  storms admitted a nondeterministic 653–1000 of 1000 across baseline runs;
  `chat_perf` admitted 1000/1000 on every run, in 2.3–2.4 s.
- **The paginated pull holds up under the storm itself**: each of the 1000
  clients fetched its 20 roster pages while the other 999 were still joining
  — 20,000 request/reply round trips, p95 4.9 s per client, zero clients
  missing their own name in the pages they collected.
- **Interactive latency unchanged**: 1–5 ms p95 across all rungs at 10
  msg/s, as in the baseline.
- **The costs**: ~50% more memory at the top rungs (a writer process per
  member: ~505 MB RSS at N=1000 vs ~380 MB baseline), and both variants stop
  at exactly 1024 concurrent connections — the platform cap in the Kex
  socket layer (baseline doc, finding 5), which no application change moves.

## Running it

```sh
tey install
tey run        # http://localhost:3000/
```

Open that URL in two or more browser tabs, enter `let-me-in` as the room
password and a different name in each, and chat between them. `PORT` and
`HOST` move it exactly as in `examples/chat`.

## Layout

| File | Owns |
| --- | --- |
| `src/main.kex` | the room password and the routes; the `ws` handler answers `$roster` pages on its own connection |
| `src/chat_perf/room.kex` | the writer registry, the writer processes, and the room's slots — where both structural changes live |
| `src/chat_perf/protocol.kex` | the line shapes the room and the browser agree on (module `ChatPerf.Protocol`) |
| `src/chat_perf/views.kex` | the login form and the chat page (module `ChatPerf.Views`), same escaping contract as the baseline |
| `spec/` | the wire format and both pages, checked without a server: `tey test` |
| `docs/baseline-benchmark.md` | the "before" measurement this example exists to beat |

It is part of the Rodolfo monorepo's Tey workspace
(`tey("rodolfo", workspace: true)`), so one `tey install` at the root covers
it; copied out of the monorepo it needs `package.kex` pointed at a release,
like any other package.

## Specs

```sh
tey test
```

Everything a spec can reach is a pure function of its input: the wire format
in `ChatPerf.Protocol` — now including the deltas, the paginated answer, and
the request parser — and what the two pages escape and dispatch on. The
routes and the room need a running server; the benchmark harness in
docs/baseline-benchmark.md is the tool for those.
