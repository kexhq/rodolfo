# Kex and Tey problems found while building Rodolfo's examples

Everything below was hit while writing `examples/library`, the book-management
CRUD example. Each entry gives the exact error text, the smallest reproduction
that still shows it, and the workaround the example ships with, so the
workarounds can be removed one at a time as the toolchain is fixed.

Toolchain used:

```
kex 0.4.0-beta (c5f3f6d, built 2026-08-31)
tey 0.2.0 (Kex 0.3.4, 86c221b)
```

Both from `/opt/homebrew/bin`. Compiler sources referenced by path are in a
checkout of `kexhq/kex` next to this repository (`../kex`).

## Re-verified 2026-09-20, against `kexhq/kex#386` (`10fd708`, not yet merged)

A candidate fix for kexhq/kex#383, #384, and #385 (this file's own findings
from earlier today), plus #375. Built locally in a worktree
(`/tmp/kex-pr386`, `make build`) and re-tried every workaround this file's
own 2026-09-20 section above had just reverted.

**#383 is fixed**, but needs one code change alongside it, not none:
`examples/chat/src/main.kex` now imports `Connection` explicitly
(`using Net.HTTP.WebSocket, only: [Connection, Message, Text, BinaryMessage,
CloseMessage]`) — the fix makes `only: [Connection]` actually work, rather
than making `.close` resolve correctly with no import of `Connection` at
all. Verified: `kex -C` reports nothing, where it reported both `close`
errors before.

**#384 is fixed for both shapes tried**: the zero-argument-slot minimal
repro from the upstream issue, and — the real test — pulling
`examples/chat`'s `Room` back out into its own `Chat.Room` module. Verified
past what #383/#384's own fixes cover on their own: `kex -C` reports zero
errors (not even #383's, once `Connection` is imported), all 22 spec cases
pass, and `kex --compile` produces a working `kex_main.beam` with the real
`socket.close` calls intact — no stubbing needed this time, unlike every
previous attempt today. A live WebSocket run still doesn't get past the
`env.query` call in the `ws` handler, but a throwaway copy with
`IO.printLine` calls added around it confirms this is #27 (the `URI`
prebuilt-artifact staging issue) firing before `Chat.Room` is ever reached
— same failure, same point, on a debug build with no `Room` involved at
all. `Chat.Room`'s own dispatch is not what's blocking a live run.

**#384 is *not* fixed for `examples/library`'s `Shelf`.** Rewrote it as a
`serving Catalogue` process again, identically to the earlier attempt: `kex
-C` clean, all 13 `spec/shelf.spec.kex` cases pass, and it still fails at
the first real compiled-and-run call exactly the same way —
`runtime error: Undefined method: matching for Server` from
`kex_io:undefined_method`, unchanged by this fix. Reverted again; the
tab-separated file stays. This is the failure mode flagged as unreduced in
kexhq/kex#384's own report — still open.

**#385 is partially fixed.** The path-resolution half is genuinely fixed —
`Kex.embed(...)` inside an imported module now resolves against *that
module's own file*, not the entry file (matching the fix's stated intent:
"each dependency module is now compile-time-expanded against its own path
before being merged into the program"). Confirmed with a from-scratch repro:
a template co-located with its module now embeds correctly by a bare
filename, where before this fix the entry file's directory was the only one
that worked.

The wrong-output half is not fixed. The exact minimal case from this file's
own 2026-09-20 section above — `let greet = Template.html(Kex.embed(...))`
in a module other than the entry file — still produces empty output at
runtime with no error (`IO.printLine("${Greet.Views.greet("Ada")}")` prints
a bare newline), and a version going through an extra wrapper function still
type-errors the same way (`Result<String, TemplateError>`, an extra
parameter). `examples/chat/src/chat/views.kex` keeps `html$`; the `.ket`
migration stays blocked.

Net effect on this branch: `examples/chat`'s `Room` moved back into its own
`Chat.Room` module and `Connection` is now imported explicitly.
`examples/library`'s `Shelf` and `examples/chat`'s `.ket` migration are
unaffected — both workarounds noted in the section below stay, pending
further upstream work.

## Re-verified 2026-09-20, against `kex 0.4.0-beta.3 (aecf378)`

`../kex` moved from `b913dac` to `main`'s tip (`aecf378`), landing three
fixes: `58be7b7` (module alias records, closing kexhq/kex#377), `430c272`
(closing kexhq/kex#378 and kexhq/kex#379), and `b99d275` ("Add explicit
timeouts to `receiveMessage`", closing kexhq/kex#381). Built locally as
`/home/akos/kex/kex/build/kex` (`make build-tey`) and re-verified each
workaround these were expected to retire.

**#28 is fixed**, and its workaround is gone. `examples/chat/src/main.kex`'s
`ws "/chat"` handler now matches `socket.receiveMessage` with no special case
for `Timeout` — a bare `receiveMessage` blocks for as long as the peer stays
connected, which #381's fix made true. Verified against the rebuilt compiler:
`kex -C` reports nothing new, and both spec files (`spec/views.spec.kex`,
`spec/protocol.spec.kex`, 22 examples) pass unchanged. Also switched
`Room.users` from `[(String, Connection)]` to `{String: Connection}` while in
there — `taken?`/`join` no longer scan the list, `leave` no longer filters it
by hand — at the cost of roster order: a `Map`'s `keys` come back in
canonical (alphabetical) order, not insertion order, so the roster no longer
shows the newest arrival first. Nothing downstream assumed the old order.

**#2 (kexhq/kex#377) is fixed only for the shape its own regression test
covers** — a single slot taking a real argument. Retried both places
Rodolfo has a workaround for it and reverted both:

- `examples/chat`: pulling `Room`'s `serving` block out of `main.kex` into
  its own `Chat.Room` module type-checked clean and all specs passed, but
  specs never actually exercise `Process.spawn`/a live slot call, and a
  *live, compiled* run of `main.kex` couldn't be produced to confirm it at
  all — `socket.close` fails to compile for an unrelated reason (see kex#383
  below), blocking the whole example's BEAM build regardless of this change.
  Given `examples/library`'s identical-in-spirit attempt (below) demonstrably
  broke at runtime despite passing the same level of static verification,
  `Room` stays in the entrypoint rather than shipping something unverified.
- `examples/library`: rewrote `Shelf` as a `serving Catalogue` process (kept
  file-backed, so a restart still doesn't lose the catalogue — the process
  just serializes access to it instead of racing the file directly). Passed
  `kex -C` and all 13 of `spec/shelf.spec.kex`'s cases under the interpreter,
  then failed at the first real compiled-and-run call — `shelf.matching("")`
  from `main`, an arity-1 slot, the same shape #377's own fix targets —
  with `runtime error: Undefined method: matching for Server`, a different
  error and a different code path (`kex_io:undefined_method`) than #377's
  own `'function not exported'` signature. Reverted; `examples/library`
  keeps the tab-separated file.

Filed upstream as kexhq/kex#384, with a clean, minimal, reliably-reproducing
zero-argument-slot variant of the same underlying defect (`#377`'s own fix
doesn't cover a slot with no arguments either) plus a description of the
`examples/library`-shaped failure above, which resisted a minutes-scale
attempt to reduce to something small the way the zero-arg case did.

**#25 (kexhq/kex#379) is fixed for the exact defect it named** — confirmed
by reading `430c272`'s diff to `src/stdlib/template.kex`: `scanLine`,
`scanText`, and `scanTagBody` all replace their old one-`Char`-at-a-time
`push!` (quadratic, since pushing to a `var` list rebinds it to a freshly
copied list every call) with tracking a run's start position and slicing it
out once. Retried `.ket` for `examples/chat`'s views and hit a **different,
still-open blocker**: `Kex.embed`/`Template.html` inside `Chat.Views` (an
imported module, not the entry file) compiled clean but returned
`None`/empty output at runtime with no error — silently wrong, not merely
slow. The exact same call, inlined into the entry file, rendered correctly.
Filed upstream as kexhq/kex#385, with a minimal repro that turns the same
root cause into a compile-time type error instead (extra parameter,
`Result`-wrapped return) rather than the harder-to-demonstrate silent-`None`
shape actually hit here. `examples/chat/src/chat/views.kex` keeps `html$`.

**kexhq/kex#383**, a new, unrelated finding made while re-verifying #2 above:
`socket.close` in `examples/chat/src/main.kex`'s `ws "/chat"` handler fails
`kex -C`/`kex --compile` — the checker resolves `close` to `FileHandle`'s
version instead of `Connection`'s own, then rejects the call for a receiver
type mismatch. Confirmed reproducing on unmodified `main` (not something
today's changes caused) and on kex commits well before today's three fixes
(`b913dac`, `58be7b7`), so it's longstanding, not a regression — just never
hit by a repro this exact shape before. Only the compiled path is affected;
`kex -R` runs straight past it. This blocks a full compiled-and-run
verification of `examples/chat` end to end; every check above that needed a
live server used a throwaway copy with `socket.close` stubbed out to get
past it, since it's unrelated to what was being verified. No workaround
applied to the shipped example — the two `socket.close` call sites are
unchanged and still there, waiting on kex#383.

## Re-verified 2026-09-19, against `kex 0.4.0-beta.3 (b913dac)`

`../kex` moved from `3c4152e` to `main`'s tip (`b913dac`, PR #374
"fix-atoms" and its follow-ups). Checked via a separate `git worktree`
rather than the shared `../kex` checkout, which had unrelated work in
progress on its own branch at the time.

**#17 is fixed**, closing kexhq/kex#347 — see its own entry below for the
migration. This is the significant one: `Rodolfo.respond` is genuine
multi-clause style again, matching the shape the bug originally forced it
away from.

Also fixed upstream in this range, neither touching `src/rodolfo.kex`:
kexhq/kex#366 (re-verified again, still holds), kexhq/kex#370 (the
WebSocket idle-push bug — re-verified with its own repro, now answers in
~3s instead of hanging ~30s and failing), kexhq/kex#343, kexhq/kex#337, and
kexhq/kex#90, none of which Rodolfo ever had a workaround for.

Checked every remaining workaround still active in `src/rodolfo.kex` and
`examples/library` against this build, to answer "is anything left to
migrate" directly rather than just re-testing the last few findings:

- **#1/#2 (serving + Net.HTTP) still both block**, confirmed with Rodolfo's
  actual shape (`using Rodolfo` in the entrypoint, not a narrower stand-in) —
  see #2's own entry for the correction; a synthetic test that looked fixed
  at first turned out not to represent the real import surface.
  `examples/library`'s tab-separated-file catalogue stays.
- **#21 still blocks**, in a new, narrower shape now that #366 landed — see
  its own entry and the new kexhq/kex#375. Plugs stay closure literals.
- **#5's `set`-fine-name-and-arity finding is moot for current code**: no
  Rodolfo code has called `.set` since the module structure this repo tracks
  today; the entry stays for the record but names no live workaround.
- **#16 confirmed unaffected** either way, as its own entry already said —
  no Rodolfo code performs unannotated constant arithmetic.
- Every other numbered entry with a migration to make (#4, #6, #7, #8, #9,
  #13, #14, #15, #17, #18, #22) has already had its workaround removed in
  past sessions; #3, #10, #11, #12, #19 never left one in code to remove.

## Re-verified 2026-09-17, against `kex 0.4.0-beta.3 (3ee1b81)`

`../kex` moved from `293a0b5` to `main`'s tip (`3ee1b81`), pulling in `304b92f`
("Fix curried typing info", kexhq/kex#350), `986d28e`/`90120f3`/`cc5c195`
(already covered below as #20/#22), and `a4f7330` (merged as `kexhq/kex#365`,
"Fix websocket close issues, add specs", closing kexhq/kex#360 — see #23).
Built locally with `make build` and re-run the same way as prior entries: a
standalone repro per item, then the full `spec/rodolfo.spec.kex` (45 examples)
and `examples/library`'s five spec files (67 examples) through `--source-root`
against the BEAM backend, plus a `kex -R` smoke test where relevant.

**#18 is fixed** — re-verified with the exact `Definition`/`Flat` repro from
its own entry, both field-declaration orders, and reading back every field on
both records (not just the one that happened to work before). All correct on
this build; no bisection was run to name the exact fixing commit, since
rebuilding at each candidate commit is expensive and nothing in the visible
commit range names #18 or kexhq/kex#348 directly. `src/rodolfo.kex` dropped
the tuple workaround: `Flat` is a real record again (`method`, `path`,
`plugs`, `handler`), `flattened` returns `[Flat]`, and `compileFlat` pattern-
matches it directly. Full spec suite (45 + 67 examples) passes unchanged.

**#23 is fixed**, closing kexhq/kex#360 — see its own entry below.

**#21 still reproduces**, in a third shape. Re-ran the exact `plug(~poweredBy)`
case this entry's "partially retracted" note left open, plus a from-scratch
minimal repro with no Rodolfo involved at all
(`mk : (Integer -> Integer) -> (Integer -> Integer)`, called both bare and via
`~`). Both now fail before ever reaching the "wrong reconstructed type" error
this entry originally reported: `kex -C` emits a **warning** that the
annotation "declares 2 parameter(s) but definition has 1" — the arity check
that produces this warning flattens the parenthesized `(A -> B) -> (C -> D)`
into a naive arrow count instead of respecting the grouping — and then a real
type error follows from the same miscount (`` `mk` declared to return Integer
but body returns T0 -> Integer ``). `304b92f` fixed the two paths it targeted
(printing a curried result type, and typing a bare function reference used as
a value) but not this one: the arity-declaration check is evidently a third,
separate code path over the same signature shape. Net effect for Rodolfo is
unchanged — a plug still has to be written as a closure literal
(`let name = do |inner| do |env| ... end end`), never as a named function
passed by name or by `~`. Nothing in `src/rodolfo.kex` changed for this entry.
Filed upstream as kexhq/kex#366 (split from #350 at that issue's own request).

**#1/#2 (serving) and #17 (multi-clause abstract-union dispatch) are
unchanged** — re-run against their own standalone repros, still reproduce
exactly as described, and no commit in `293a0b5..3ee1b81` touches `serving`,
process export, or multi-clause lowering. No workaround in `src/rodolfo.kex`
or `examples/library` changed for either.

## Re-verified 2026-09-15, against `kex 0.4.0-beta.3 (293a0b5)`

`../kex` moved well past `9ecd0f6` — built locally as `/home/akos/kex/kex/build/kex`.
Two findings, in opposite directions.

**#1/#2 still reproduce**, now against the rewritten `serving` API (a
`serving` block is declared on a record and its methods are now `slot`s
returning `Reply<T>`/`Void`; a process is started with `Process.spawn`, not
`Counter.start`). A minimal repro: a `Store` module with a `serving Counter`
process, imported by a `main.kex` that also `using Rodolfo` and calls
`counter.add(n)` from inside a `get "/add/:n" do |env| ... end` route. Calling
the same slot directly from `main` works (`5`, then `8`); calling it from
inside the route handler crashes the server process on the first request:

```
** {'function not exported',
       [{'Kex.Store',add,[{'Store.Counter',0},5,#{}],[]},
        {kex_intrinsic_process,handle_call,3, ...
```

Exactly the shape the original entries describe, just with the new `serving`
spelling. `examples/library` keeps `src/shelf.kex`'s tab-separated-file
workaround rather than a real process store.

**New: #17, multi-clause overloaded functions silently drop clauses when the
call site's argument type is an abstract union rather than a concrete type**
— see its own entry below. Found while converting `respond` (in this repo's
`src/rodolfo.kex`) from one function with an internal `match` to Kex's
multi-clause `let f(Pattern1) = ...; let f(Pattern2) = ...` style: every
direct call from `main` with a literal record dispatched correctly, but the
exact same function called from inside the route-handler closure — where the
argument's static type is `Reply`, not any one variant — always ran the
*first* clause's body regardless of the value's actual shape. `--emit-core`
confirms only one of nine clauses reached the compiled module at all.
Reverted to a single `foul respond(reply: Reply, route: String) do match
reply do ... end end` in `src/rodolfo.kex`, which is unaffected and passes.

## Re-verified 2026-09-13, against `kex 0.4.0-beta.2 (9ecd0f6)`

`../kex` moved well past `331cbb5` — the one item this checks, #272, was fixed
by `7d227b0` ("Fix imports": `pureFnArities` now also records a function's
qualified name at the same registration site that records its bare one, so
`callNeedsContext` matches a `using`-imported pure call under either
spelling). Re-run against the exact upstream repro rather than a trimmed
standalone one this time: `spec/rodolfo.spec.kex` itself (`using Rodolfo` +
`using Net.HTTP, only: [Client, Server, ServerOptions, Headers, Context,
Request, Status]`, the same shape the issue was filed from) now passes in
full — 36 passed, 0 failed, `get`/`post` included — on BEAM, where the
`erlc`-time failure actually lived (the tree-walk backend never reproduced
this one, since capability-context lowering is a BEAM-codegen concern).
`examples/library`'s five spec files (67 examples total, matching the count
above) still pass unchanged. **#272 is fixed — closing upstream.**

## Re-verified 2026-09-05, against `kex 0.4.0-beta.2 (331cbb5)`

`../kex` moved 6 commits past `5a088fe` — `1908e23` (free-function overloads),
`2120598` (`Comparable`, `Bool.not`), `c129086` (module constants), `8322c2f`
and `c01e80f` (visibilities), `331cbb5` (serving slots) — built with `make
build` and re-run the same way: a standalone repro per item, not through
`examples/library`. The build needs OTP 29 (`KEX_ERL=/opt/homebrew/opt/erlang/bin/erl`
here; the `kex` on `PATH` is still the old `c5f3f6d`).

Newly fixed: #1, #9, #13, #14, #15. Still reproduces: #2 (narrowed — see its
entry) and #5's diagnostics finding (narrowed to a precise trigger). #16 is
new, found while writing the #14 repro.

`examples/library` dropped the workarounds for #13, #14 and #15: `Book` now
carries `implement: Comparable` and `[Book].sorted` is a plain `this.sort`,
`Catalog.Draft`'s constants are unqualified inside their own module, and the
make-only helpers in `book.kex` and `draft.kex` moved into their `make`
blocks' `private do` sections. Its `spec/` suite (67 examples across five
files) and a `kex -R` smoke test (listing order, POST + 303 redirect, the
same-year title tie-break, validation messages) all pass.

One workaround was kept deliberately: `books.kex`'s `rewritten` stays in the
module-level `private do` block. `make [Book]`'s `:>` prepends the `[Book]`
receiver, and that helper takes a single `Book`, so it is not a make-block
member to begin with — its module-level home is the right shape, not a
leftover.

## Re-verified 2026-09-04, against `kex 0.4.0-beta.2 (5a088fe)`

`../kex` moved 25 commits past `c5f3f6d`, built from `make build` /
`make build-tey`, and every item below was re-run against that build with a
standalone repro (not through `examples/library`, so the result is about the
compiler, not about whether the example's workaround happens to still work).
`examples/library` itself was then updated to drop the workarounds for
whatever came back fixed; its `spec/` suite (62 examples) and a manual
`tey run` smoke test (GET, POST, redirect) still pass.

Fixed: #3, #4, #6, #7, #8, #10, #12, and Ctrl+C. Still reproduces: #1, #2, #9.
#5 is moot and #11 is intended behavior rather than a defect — see their
entries. Each entry below is marked inline.

## Feature requests

### 20. No server-side WebSocket upgrade — `Net.HTTP.WebSocket` is client-only

**Fixed** on `cc5c195` (merged via kexhq/kex#355). `WebSocket.upgrade`
shipped matching the `net-plan.md` sketch quoted below almost exactly —
confirmed by running kex's own `examples/websocket_chat.kex` against a
clean, isolated build of `main`: a real `serving`-backed chat session
answers over an actual upgraded connection, no mocks. Rodolfo route-level
support (`ws "/path" do |socket| ... end`) is unblocked and, as of
2026-09-18 and #23's fix, built — see `ws` in `src/rodolfo.kex` and the
"WebSocket routes" section of `README.md`.

Found on `293a0b5` while scoping WebSocket route support for Rodolfo (the
kind of thing Sinatra and Kemal both offer, and Rodolfo already borrows its
shape from both).

`src/stdlib/net/http/websocket.kex` implements exactly one side of RFC 6455:
`WebSocket.connect(url)` opens an outbound connection and gives back a
`Connection` with `send`, `receiveMessage`, `session`, `close`, `closed?`.
There is nothing to *accept* an incoming handshake — no upgrade response
type, no way for a `Net.HTTP.Server` route handler to take over the
connection. `Net.HTTP.Response` only builds `binary`/`text`/`empty`, and the
server-side intrinsic (`runtime/src/kex_intrinsic_nethttpserver.erl`) has no
upgrade path at all; the WebSocket intrinsic
(`kex_intrinsic_netwebsocket.erl`) is the client handshake exclusively
(computing `Sec-WebSocket-Key`, validating `Sec-WebSocket-Accept`).

This isn't a surprise gap — `docs/net-plan.md` already designs it and lists
it as missing:

```
| WebSocket | Partial | Verified ws/wss client handshake, ... | Server
upgrades, raw frames, heartbeat, reconnecting client, scripted mock, browser
implementation |
```

with a sketch of the intended shape (`docs/net-plan.md:670-687`):

```kex
router.get("/socket") do |request, context|
  authenticate(request).map do |principal|
    WebSocket.upgrade(request) do |handshake|
      if handshake.subprotocols.contains?("chat.v2") then
        Accept({ |socket| serveChat(principal, socket) }, headers: Headers.empty, subprotocol: Just("chat.v2"))
      else
        Reject(Response.text(426, "chat.v2 required"))
      end
    end
  end
end
```

No workaround from the Rodolfo side: `Net.Socket.TCP.listen`/`accept` does
give raw byte-level access, so a hand-rolled RFC 6455 server (handshake,
masking, fragmentation, close codes) is technically reachable, but only as
its own listener on a separate port — there is no way to peek at a
connection before `Net.HTTP.Server` claims it, so sharing one port with
ordinary HTTP routes would mean reimplementing HTTP/1.1 request parsing from
scratch too. Given `net-plan.md` already designs the real thing, duplicating
a partial version in Rodolfo now would need to be thrown away once
`WebSocket.upgrade` ships. Rodolfo route-level support (`ws "/path" do |socket| ... end`, mirroring `get`/`post`)
is blocked on this landing in Kex first.

## Blocking

### 1. `serving` slots are not exported once the program depends on `Net.HTTP`

Filed upstream as kexhq/kex#376 (closed on file — already fixed, kept for
the historical record and as somewhere to reopen from if it regresses).

**Fixed** on `331cbb5`. The exact repro the `5a088fe` note describes — a bare
`serving Counter do ... end` in the entrypoint, `using Net.HTTP, only:
[Headers]`, and one `foul` function taking a `Server<Counter>` — now runs
through: `add 5 -> 5`, `add 3 -> 8`, `current -> 8`, with `Headers` still
importable alongside. Verified in a multi-module layout too, so it is not an
artifact of a single-file program.

The `serving`-in-the-entrypoint case is what this entry covered, and it is
clear. `serving` in an *imported* module still fails when `Net.HTTP` is in
the program — that is now the whole of #2, which see.

A `serving` process whose slots are called from a Rodolfo route fails at the
first call:

```
** exception error: {'function not exported', {Library, add, 3}}
```

The process starts, and the same slot works in a program that does not touch
`Net.HTTP`. Adding the dependency — directly, through `using Net.HTTP`, or
transitively through `using Rodolfo` — is enough to break it, whether the
call site spells the module qualified or not.

The runtime dispatches slots in `runtime/src/kex_intrinsic_process.erl`
(`invoke_slot`): it checks `erlang:function_exported/3` for the declared
arity and otherwise retries at arity + 1 with an extra `#{}`. Both lookups
miss, which points at the code generator not emitting the slot exports for
this compilation unit rather than at the dispatcher.

This is the defect that decided the example's architecture. There is no
Kex-level workaround, so `examples/library` keeps its catalogue in a
tab-separated file (`src/shelf.kex`) instead of in a process.

### 2. `serving` declared in an imported module never resolves

Filed upstream as kexhq/kex#377. **Fixed** on `58be7b7`, but only for the
shape its own regression test covers (one slot, a real argument) — retried
2026-09-20 for both `examples/chat`'s `Room` and `examples/library`'s
`Shelf`, and both broke in new ways (a zero-argument slot; a realistic
multi-module app's first call). See this file's own 2026-09-20 section up
top and kexhq/kex#384.

kexhq/kex#386 (open, not yet merged as of 2026-09-20) fixes the
zero-argument-slot shape — confirmed against `examples/chat`'s actual `Room`,
moved back into its own module — but **not** `examples/library`'s `Shelf`,
which fails the identical way, unchanged. `Room`'s workaround is gone;
`Shelf`'s stays. See the newer 2026-09-20 section (against `kexhq/kex#386`)
above the one this paragraph is appended to.

**Still reproduces** on `main` (`b913dac`, 2026-09-19) for Rodolfo's actual
shape — `using Rodolfo` in the entrypoint, a `serving` block in a plain
imported module that itself touches nothing HTTP-related, called from a
route handler. A narrower synthetic version (`using Net.HTTP, only:
[Headers]` in the entrypoint instead of `using Rodolfo`) now works, which
looked like progress at first — but swapping in the real import brings back
the identical `'function not exported'` crash, matching this entry's own
note that the trigger is the dependency's *presence* in the compilation
unit, not any specific use of it, and #23's established pattern that this
class of defect is fragile and depends on what else is compiled alongside
it. `examples/library`'s tab-separated-file workaround is unaffected and
stays.

**Still reproduces** on `331cbb5`, but much narrower, and the failure has
changed shape. A `serving` block in an imported module now works on its own —
the original `{unknown_serving_slot, add}` is gone, and slot resolution finds
the right module. What still breaks is the *combination* with `Net.HTTP`:

```
** {'function not exported',
       [{'Kex.Store',add,[{'Store.Counter',0},5,#{}],[]},
        {kex_intrinsic_process,handle_call,3, ...
```

So the error is now #1's original shape, moved to module scope: the slot is
dispatched to the right module and that module has no such export. A four-cell
matrix, identical but for where the `serving` block and the import sit:

| `serving` block in | `Net.HTTP` imported | result |
| --- | --- | --- |
| entrypoint | — | works |
| entrypoint | anywhere | works |
| imported module | — | works |
| imported module | anywhere | `'Kex.Store':add/3` not exported |

The import breaks it from either side: `using Net.HTTP` in the `serving`
module itself, or in the entrypoint only, fails the same way — and a bare
`using Net.HTTP` that the module never references is enough, so it is the
dependency's presence in the compilation unit, not any use of it. The
remaining defect is that the code generator does not emit the slot exports for
a non-entrypoint module once `Net.HTTP` is part of the program.

Note that the call returns a `Result`, so a caller writing `.or(-1)` sees only
the fallback; the crash is visible in the error report, not the return value.

This still blocks the shape #1 blocked, so `examples/library` keeps its
catalogue in a tab-separated file (`src/shelf.kex`) rather than a process: a
store in its own module is exactly the failing cell.

### 24. A server-side WebSocket `Connection` can't be sent to from another process while it's idle

**Fixed** on `kexhq/kex` `main` (merged as PR #371, "Fix WebSocket server_loop
blocking its mailbox on an idle client"), closing kexhq/kex#370. Re-verified
2026-09-19 against `main` @ `b913dac` with the exact repro filed upstream: the
push now succeeds in ~3s instead of hanging ~30s and reporting the connection
closed. This unblocks a broadcast chat room example — see #20/#23's own
entries for the DSL support this depends on. Nothing in `src/rodolfo.kex`
needed migrating for this fix itself (there was no workaround, only the
reverted example); a real `examples/chat` is now buildable.

2026-09-19, second pass: the first `examples/chat` only proved the fix — a
plain-text prompt, no real interface. `ws`'s own signature grew a `Context`
parameter (`type SocketHandler = Connection -> Void` became `Context ->
Connection -> Void`) so a handler can read the query string the handshake
request carried, which a `ws` route needs for anything beyond an anonymous
echo: a display name, a room token, anything `WebSocket.upgrade`'s own
`decide` callback would see if Rodolfo called it directly. `examples/chat`
now serves a real HTML/JS chat page, a shared room password checked from
`env.query("token")`, and a distinct display name per connection — verified
with a live server and real WebSocket clients: a wrong password gets the
connection closed immediately, and two correctly-authenticated connections
see each other's joins and messages, correctly attributed by name.

Filed upstream as kexhq/kex#370.

Found on `3ee1b81` (2026-09-18) while building Rodolfo's own `ws` route
support on top of #23's fix — trying to write a broadcast chat room example:
a `serving Room` holding every connected `Connection` and pushing to all of
them whenever any one client sends a message.

A `Connection`, `.send()`-to from a process other than the one running its
own handler, hangs for ~30s and then reports the connection closed — even
though the client is still connected and simply hasn't sent anything since
upgrading. `runtime/src/kex_intrinsic_netwebsocket.erl`'s `server_loop`
processes a `receive_message` request with a **blocking** `gen_tcp:recv`
(the module's 30000ms `?TIMEOUT`), during which it cannot service any other
message in its mailbox — including a `{send, ...}` request queued by another
process. If the client stays quiet past that window, the recv times out,
`server_loop` marks itself closed (any transport hiccup, timeout or genuine
close, is reported with `kind: Closed`), and only then drains its mailbox to
answer the queued send — with an error, since it now considers itself dead.
Confirmed with a minimal, Rodolfo-free repro: registering a connection with
a separate `serving` process and pushing to it from a plain HTTP route takes
~32.5 wall-clock seconds to fail, matching the internal timeout exactly.

Same-connection request/reply — the handler calling `send`/`receiveMessage`
on its own connection, including from a per-session `serving` actor it
spawned itself (see kex's own `examples/websocket_chat.kex`) — is unaffected,
since that process is never the one stuck in the blocking recv when the send
happens. It is specifically a *different* process sending to an *idle*
connection that hits this.

Workaround: none found. This blocks the shape #1/#2 blocked, one level up —
a single connection's own request/reply loop works fine, but Rodolfo's `ws`
route can't be used to build anything that pushes to a connection from
outside its own handler (a broadcast chat room, a shared notification
channel, pub/sub) reliably, since the target is normally idle exactly when a
push would matter. An `examples/chat` broadcast demo was built, confirmed
broken by this, and reverted rather than shipped; `ws`'s own single-connection
request/reply shape (the "Rodolfo serves WebSocket routes" specs) is
unaffected and stays in `src/rodolfo.kex`.

### 25. `Template.scan` is severely super-linear — a `.ket` template of ordinary page size times out

Filed upstream as kexhq/kex#379. **Fixed** on `430c272`. Retried
2026-09-20 for `examples/chat`'s views and hit a different, still-open
blocker on the way back to `.ket` — `Kex.embed`/`Template.html` from a
non-entry module, kexhq/kex#385. See this file's own 2026-09-20 section up
top. `html$` stays.

kexhq/kex#386 (open, not yet merged as of 2026-09-20) fixes half of #385 —
`Kex.embed` now resolves against the declaring module's own file rather
than the entry file's — but not the other half: the same call still
silently returns wrong/empty output at runtime from a non-entry module. See
the newer 2026-09-20 section (against `kexhq/kex#386`) above. `html$`
stays.

Found 2026-09-19 while separating `examples/chat`'s two pages (a login form
and the chat UI, both with ordinary CSS/JS, a few KB each) into `.ket`
templates (`Kex.embed` + `Template.html`, kexhq/kex#171) as requested,
instead of writing them as Rodolfo `html$` literals inline.

`Template.scan` runs interpreted at compile time (`scanTemplateSource`'s own
comment: "via the same sandboxed Evaluator"), against a hardcoded 2000ms
budget. Three data points, `kex -C` wall clock, `main` @ `b913dac`:

| Content | Size | Result |
| --- | --- | --- |
| A single character | 1 byte | compiles, **1.5s** |
| A handful of ordinary CSS rules, no tags | ~220 bytes | compiles, **~2.0s** — right at the edge |
| A real login page: doctype, head, `<style>` (~50 lines of CSS), a form | ~2KB | **times out** |

The 1-byte case rules out "just split it into smaller files": there's a
large *fixed* cost per `Kex.embed`/`Template.html`/`Template.text` call
(consistent with spinning up a fresh sandboxed interpreter + prelude each
time), so decomposing one large template into several smaller ones makes
total compile time *worse* (N × ~1.5–2s), not better — and any individual
piece with a modest amount of real content still risks tipping past 2000ms
on its own, as the 220-byte data point shows.

Workaround: `examples/chat`'s two pages are Rodolfo `html$`/`rawHTML$`
tagged literals in `chat/views.kex` instead — same visual result, same
escaping guarantees, compiles instantly since it never goes through the
interpreted scanner. Worth retrying `.ket` once kexhq/kex#379 is fixed; the
views are already isolated in their own file, so switching back later is a
contained change.

### 26. Every example needs a namespaced top-level module name — `tey` builds the whole workspace, not just the package you asked for

Found 2026-09-19 running `tey build`/`tey run` inside `examples/chat`
specifically (not from the workspace root): `tey`'s own resolution of the
workspace `rodolfo` dependency pulls in every sibling example under
`examples/*`, not just the one package actually being built. `warning:
shadowed module definition for Views: examples/library/src/views.kex`
surfaced because `examples/chat` had *also* declared a plain `module
Views` — the two collided, one silently lost, and the loser's functions
became undefined at the call sites that needed them: a wrong password
literally rendered the template source (`<%= error %>`, from unrelated
copy-paste — see below) rather than the error text, and a *correct* login
crashed with a bare `Internal Server Error` reaching the chat page, since
the `Views.chat`/`Views.login` calls resolved to whichever module won and
that module has no such functions.

Every module `.kex` file's declared name has to be unique across the
*entire* workspace, not just within the package that declares it — a bare
`module Views`, `module Config`, anything a second example might also
reach for, is a latent collision waiting for a sibling example to pick the
same name. Fixed by namespacing every example's own module names to the
example itself: `examples/chat`'s `Views` became `Chat.Views` (moved to
`chat/views.kex`, since a nested module name has to live at a matching
path — `chat/views.kex`, not `views.kex`, the same convention
`examples/library`'s own `catalog/book.kex` already follows for
`Catalog.Book`), and `examples/library`'s own `Views` became
`Library.Views` for the same reason, even though it was there first —
belt and suspenders against the next example that wants a `Views` too.

Separately, but found at the same time: `<%= error %>` (ERB syntax, from
when this file was still a `.ket` template attempt — see #25) was left in
one `html$` literal instead of being converted to `${error}`; a real bug
of my own, unrelated to the module collision, fixed alongside it.

### 27. A `using` of a stdlib module stages the toolchain's prebuilt beam over the one the build just compiled — every extended method on that name becomes `undef`

Found 2026-09-19 in `examples/chat`, which answered a plain `GET /` with
`500 Internal Server Error` and logged

```
Rodolfo: GET / returned a value that is not a Reply: Error(:undef)
```

while the `ws "/chat"` handler, reaching the same call one line in, crashed
and closed every connection the instant it opened — and both symptoms came
and went across builds that differed only in comments, which is what made it
look random rather than reproducible.

The call was `env.query("token")`, `query` being a method Rodolfo adds to its
own `Context` record. Kex compiles a method call whose receiver type it can't
pin statically into a call on the *dispatcher* for that method name, which
lives in the module that already owns the name — here `Kex.URI`, since `URI`
has a `query` of its own. Compiling this program emits a fresh `Kex.URI.beam`
carrying a dispatcher clause for the new receiver:

```erlang
'query'/2 = fun (_a0, _a1) ->
  case _a0 of
    _gv when call 'erlang':'is_record'(_gv, 'Rodolfo.Context', 3) ->
      call 'Kex.Rodolfo':'query/Context'(_a0, _a1)
    _Wc4 when 'true' -> call 'kex_prelude':'query'(_a0, _a1)
  end
```

That beam reaches `ebin/` correctly. It is the *run* that loses it: the temp
directory `kex --run` stages gets the toolchain's own prebuilt
`Kex.URI.beam` instead, which has no `query/2` at all, and the call dies as
`undef` at the first request.

Caught with a tracer on `error_handler:undefined_function/3`
(`ERL_AFLAGS="-pa … -eval tracer_start:go()"`, so it installs before
`kex_main:main/0`), which names the MFA that failed to resolve rather than
the `Error(:undef)` value the failure eventually becomes:

```
*** UNRESOLVED {'Kex.URI',query,2} error:undef
```

and confirmed from both sides:

| `Kex.URI.beam` | `query/2` | Size |
| --- | --- | --- |
| `examples/chat/ebin/` (compiled from this program) | yes | 3968 |
| the staged `/tmp/kex_*/` run directory | **no** | 9852 |
| `~/.local/share/tey/toolchains/0.4.0-beta.2/share/kex/runtime/` | no | 9852 |

A direct import is one trigger, and the use is irrelevant to it: `using URI,
only: [Form]` in `examples/chat`'s entrypoint is enough, and the program
never mentions `URI.query`. Drop the `using` and the same `URI.Form.from(...)`
call written out in full stages the compiled beam instead, `query/2`
resolves, and every request succeeds. Running the same `ebin/` directly
(`erl -pa ebin -eval 'kex_main:main()'`) also works, since nothing shadows
the compiled module there — the staging step is the whole of the defect.

It is **not** only the direct import, though, and this is the part that has
no workaround: `spec/rodolfo.spec.kex` has no `using URI` anywhere and its
"decodes a query field the way a browser submits a GET form" case fails on
this toolchain with the same traced `{'Kex.URI',query,2} error:undef`
(49 passed, 1 failed), reaching `Kex.URI` only through `Net.HTTP`. That case
tests `env.query` itself, so there is nothing to rewrite around it; it stays
red until this is fixed upstream. It is the one failing case in the suite,
and it fails for this reason and not for anything the spec or `src/` does.

Workaround where there is one, and what `examples/chat` ships: no `using
URI`; `URI.Form.from` fully qualified at the one call site that needs it.
Anything that extends a method name the stdlib already owns — which is most
of what a framework does to a request context — is exposed to this, so the
general shape is worth fixing upstream rather than naming module by module.

### 28. A WebSocket receive gives up after 31 seconds and reports a live, idle client as closed

Filed upstream as kexhq/kex#381. **Fixed** on `b99d275` ("Add explicit
timeouts to `receiveMessage`") — the workaround below is gone from
`examples/chat/src/main.kex` as of 2026-09-20; see this file's own
2026-09-20 section up top for what changed and how it was verified.

Found 2026-09-19 in `examples/chat`, and the reason a room drops people at
random: anyone who hasn't typed in half a minute is disconnected, which in a
chat room is nearly everyone nearly all of the time. A client sitting idle is
closed at **31.0s**, every time:

```
   0.0 connected
   0.0 op=1 b'* alice joined'
   0.0 op=1 b'$users:alice'
  31.0 op=8 b'\x03\xe8'
```

`runtime/src/kex_intrinsic_netwebsocket.erl`'s `call/2` waits `after 31000`
for any reply and answers a `Timeout` `NetError` when the budget passes. For
`send` that is a real budget; for `receive_message` there is nothing to time
out — the call is *supposed* to block until the peer says something, and
since PR #371 the connection process no longer imposes a deadline of its own
(#24), so the 31s cap is now the only thing ending an idle receive. The
connection is still open and the client still there; only the caller has been
told otherwise, and a handler that treats a failed receive as a disconnect —
the obvious reading, and what the example did — hangs up on a live client.

A client-side heartbeat hides it, but that is a workaround written into every
page rather than a fix: a receive with no deadline is the normal way to serve
a WebSocket, and `receiveMessage` should either wait indefinitely or take an
explicit timeout from the caller. kexhq/kex#381 asks for the latter —
`receiveMessage(timeout: Duration?)`, `None` meaning "as long as the peer
stays connected" and the no-argument form defaulting to it — and for
`call/2` to stop lending the receive a budget meant for `send`. The upstream
report carries a dependency-free 27-line repro; a copy lives in this
session's notes rather than in the tree, since it exercises `Net.HTTP`
directly and has nothing to do with Rodolfo.

Workaround, and what `examples/chat` ships: match `receiveMessage` as the
`Result` it is instead of `.try`-ing it, and tell the two failures apart —
`Error(NetError { kind: Timeout })` goes back around the loop, everything
else is a real disconnect and leaves it:

```rb
loop do
  match socket.receiveMessage do
    Ok(Text(text)) => room.broadcast(Chat.Protocol.chatLine(name, text))
    Ok(CloseMessage(_, _)) => break
    Ok(_) => Void
    Error(NetError { kind: Timeout }) => Void
    Error(_) => break
  end
end
```

Verified with two raw WebSocket clients against a live server: an idle
connection now survives well past the old cap and still receives and sends
after 70s, a clean close still announces `* name left` and redraws the
roster, and an abrupt drop (RST, no close handshake) still runs the same
cleanup — the `Closed` error reaches the `Error(_)` arm.

### 3. `tey install` refuses the toolchain it needs

**Fixed** on `5a088fe` (Tey side, built from `../kex`'s `make build-tey`).
`tey --version` now reports the `kex` it actually runs (`Kex 0.4.0-beta.2,
5a088fe`) instead of a bundled 0.3.4, and `tey install`/`tey run`/`tey test`
all work against `examples/library` without the hand-copied lockfile. This
release also shipped the `workspace` feature the examples now use — see
`package.kex`, which declares `workspace do members(["examples/*"]) end`, and
each example's `tey("rodolfo", workspace: true)` — so a plain `tey install`
resolves Rodolfo from this checkout instead of a tagged release.

`tey` on `PATH` bundles Kex 0.3.4, and it compares that bundled version — not
the `kex` on `PATH` — against `package.kex`:

```
tey: Kex 0.3.4 (86c221b) does not satisfy >= 0.4.0-beta
```

Rodolfo requires `>= 0.4.0-beta`, so no example can be installed, built, run,
or tested through Tey. `tey kex install` does not change the comparison.

Workaround: `examples/library/tey.lock` was copied by hand from
`examples/website` (all four existing example lockfiles are byte-identical),
and every verification in this repo was done with the compiler directly:

```sh
kex -R --source-root src src/main.kex          # run
kex -R --source-root src spec/catalog.spec.kex # specs
```

## Correctness

### 4. `Map#get(key, default)` returns `Just(value)` instead of `value`

**Fixed** on `5a088fe`. `{}.put("title", "Dune").get("title", "")` now
returns `"Dune"` directly. `examples/library`'s `firstValue` helper was kept
as-is rather than rebuilt onto a `Map` — it already preserves first-occurrence
semantics for a repeated form field via `.find`, which a `reduce`-into-`Map`
version would need extra care to match, for no clear benefit.

For a map built with `reduce`, the two-argument `get` — documented as
returning the value or the default — returns an `Option`:

```kex
let values = entries.reduce({}) { |acc, (name, value)| acc.put(name, value.or("")) }
values.get("title", "")   # => Just("Dune"), not "Dune"
```

The wrong type flows onward silently until something calls a `String` method
on it. In the example it surfaced as every `POST` route answering 500, from
`Catalog.validate` calling `.trim` on an `Option`.

Workaround: the example does not build a map. `src/main.kex` reads form
fields straight out of the parsed entry list with its own
`firstValue(entries, name)`.

### 5. `Headers.empty.set(...)` does not dispatch from a top-level function

**Moot on `5a088fe`** — `Net.HTTP.Headers` no longer has a `set` method at
all (`add`, `remove`, `get`, `getAll` are what `src/stdlib/net/http.kex`
exports now), so the original repro no longer type-checks, inline or lifted.
The pattern the bug was actually about — building a value with a chained
UFCS call inside a plain top-level function, not a route block — works fine
today with `.add(...).try`, checked directly.

New finding hit while re-checking this, **still reproducing on `331cbb5`** and
now pinned to an exact trigger. The checker does not miss undefined methods in
general — it is specifically a method whose *name* exists on some unrelated
type at the matching arity that slips through unchecked against the receiver:

| call | `kex -C` |
| --- | --- |
| `Headers.empty.frobnicate` | caught: ``Undefined method `frobnicate` for `Headers` `` |
| `Headers.empty.frobnicate("a", "b")` | caught, same |
| `Headers.empty.set(3)` | caught: ``` `set` expects 3 argument(s), got 2 ``` |
| `Headers.empty.set("a", "b")` | **"No errors found."** — dies at runtime |

The one name that gets through is `set`, and the only `set` in the stdlib is
`Bits#set(n, index)` in `src/stdlib/bits.kex:122` — receiver plus two
arguments, the arity the passing call has. Change the arity and the arity
check fires; change the name to one nothing defines and the undefined-method
check fires. So a name-and-arity match somewhere in scope satisfies the
checker without the receiver type ever being tested, and the call fails at
runtime with `Undefined method: set for Net.HTTP.Headers`.

`examples/library` never calls `.set`, so this affects no example code, but it
is worth its own report upstream.

Inline in a route block, `set` resolves. Lifted into a top-level helper, the
same expression fails to compile:

```
Undefined method: set for Net.HTTP.Headers
```

Workaround: build headers in one call —
`Net.HTTP.Headers.from([("Content-Type", "text/html; charset=utf-8")]).try`.
Both `markup` and `seeOther` in `src/main.kex` do this.

### 6. Importing `Net.HTTP` shadows the HTTP verbs

**Fixed** on `5a088fe`. `using Net.HTTP, only: [Headers, Response]` alongside
a `Map#get` call no longer drags `Router.get` into the candidate set — the
original three-way `Draft.title expects String, but got Net.HTTP.Router`
error is gone. `src/main.kex` now imports `using Net.HTTP, only: [Headers,
Response]` and spells `Response<Binary>`, `Headers.from`, `Response.binary`,
and `Response.empty` unqualified instead of fully qualifying every use.
kexhq/kex#272 (filed from this entry) is now confirmed fixed too — see the
2026-09-13 re-verification above.

`using Net.HTTP, only: [Headers, Response]` alongside `using Rodolfo` makes
`values.get(...)` resolve to `Net.HTTP.Router`'s `get` make-method, producing
three type errors of the form

```
Draft.title expects String, but got Net.HTTP.Router
```

`only:` did not keep `Router` out of scope. Filed upstream as kexhq/kex#272.

Workaround: `src/main.kex` never imports `Net.HTTP`; it spells every use
fully qualified.

### 7. Record patterns matched through `Any` fail silently

**Fixed** on `5a088fe`. A record pattern arm now matches correctly against a
value statically typed `Any` — `match (p : Any) do Cat { name } => ... Dog {
name } => ... end` picks the right arm instead of always falling through.
`src/views.kex`'s private `render` now does `match value do Safe { markup }
=> markup _ => escape("${value}") end` instead of comparing `Type.of`.

Matching a record pattern against a value whose static type is `Any` takes
the fallback arm rather than the record arm, with no error at compile time or
run time. `src/views.kex` compares `Type.of` in its private `render` instead
of pattern-matching the tagged-literal values.

### 8. Module-level nullary bindings need the module prefix inside their own module

**Fixed** on `5a088fe`, checked with both a `module X do ... end` block and
the bare `module X` header-then-rest-of-file form `catalog.kex` and
`shelf.kex` actually use. `src/catalog.kex` (`earliestYear`, `latestYear`)
and `src/shelf.kex` (`catalogueFile`, `books`, `stocked`, `kept`) now refer to
their own module's bindings unqualified; the comments warning not to "clean
up" the prefixes are gone along with the prefixes.

A module's own value bindings do not resolve unqualified from within that
module — they are unresolved at run time. `src/catalog.kex` refers to
`Catalog.earliestYear` and `Catalog.latestYear` even in its own private
functions, and `src/shelf.kex` calls `Shelf.catalogueFile` and `Shelf.books`
the same way. This is noted in a comment in `catalog.kex` so the prefixes are
not "cleaned up" into a broken build.

## Papercuts

### 9. `Bool#not` does not exist

**Fixed** on `331cbb5`, by `2120598`. `Bool#not` exists: `true.not` is
`false` and `false.not` is `true`, checked and run. Negating an arbitrary
`Bool` now has a direct spelling, so `falsy?` and `set?` are a choice rather
than the only route.

The runtime-instead-of-compile-time behaviour this entry noted is gone as a
general pattern too — `true.frobnicate` is caught by `kex -C` again. What
remains of it is the much narrower trigger documented under #5.

```
Undefined method: not for Bool
```

`Truthyable`'s `falsy?` and `Option`'s `set?` cover the cases the example
needed (`FS.File.exists?(path).falsy?`, `Catalog.withId(books, id).set?`),
but negating an arbitrary `Bool` has no direct spelling.

### 10. `let f() -> T do ... end` is reported as returning `Void`

**Fixed** on `5a088fe`. `let f() -> Int do 42 end` now compiles and runs; the
parenthesised zero-argument form is no longer treated differently from `let
f = ...`. Nothing in `examples/library` used the dropped-parens workaround,
so no example code changed for this one.

A parenthesised zero-argument definition with an explicit return type and a
`do` body is rejected with a "body returns Void" error even when the last
expression has type `T`. Dropping the parameter list (`let f = ...`) works.

### 11. Multi-line `then`/`else` bodies do not parse

**Retracted** — this is the design, not a defect. `then`/`else` is
deliberately the conditional whose branches are each one expression
(`<cond> then <a> else <b>`); the moment a branch needs its own line, the
spelling is `if` / `elif` / `else` / `end` (STYLE.md §11). The original entry
below misread that as a parser gap.

`cond then` / `else` accepts single-expression arms only; splitting an arm
across lines is a parse error. Longer branches have to become a `match` or a
helper.

### 12. `kex -C` does not resolve external modules

**Fixed** on `5a088fe`. A `kex -C --source-root src src/main.kex` against a
two-module package (`main.kex` using an external `Helper` module) now says
"No errors found." instead of reporting the import unresolved. `kex -C` is
usable again as the fast feedback loop the original entry wanted.

For a multi-module package, `kex -C` reports missing modules that `kex -R`
resolves from the same `--source-root`. Compile-only checking is therefore
not usable as a fast feedback loop; the reliable check is a full `kex -R`
run, which costs about 40–45 seconds of BEAM startup per invocation.

### 13. `private` methods in a `make` block cannot be called from sibling methods

**Fixed** on `331cbb5`, by `8322c2f` and `c01e80f` — both directions, and
kexhq/kex#281 can be closed. A `private do ... end` section inside a `make`
block is now callable from that block's other methods and runs; reaching into
it from another module's make block is rejected at compile time with a
diagnostic that names the boundary:

```
`decorate` is private to `make Thing.Widget` in `Thing` — it is only callable
inside that block
```

which is the documented rule in `docs/modules.md`, stated in both directions
for the first time.

`examples/library` moved the helpers that serve only make-methods back inside
their `make` blocks: `oneLine` and `byTitle` in `src/catalog/book.kex`, and
`yearErrors` and `inRange?` in `draft.kex`. `books.kex`'s `rewritten` stayed
at module level on purpose — `make [Book]`'s `:>` prepends the `[Book]`
receiver and that helper takes a single `Book`, so it was never a make-block
member; likewise `parsed` and `restored`, which serve the module-level
`decoded`.

Note the spelling: `private` introduces a block (`private do ... end`), not a
per-method modifier — `private decorate :> ...` is a parse error.

Found on `6ccdf35` while splitting `catalog.kex` into `catalog/`. Filed
upstream as kexhq/kex#281.

A helper declared `private` inside a `make` block is unreachable from the
other methods of the same block: the call passes the type checker and dies at
Core Erlang lint.

```
error: could not compile Kex.Thing: {error,
  [{"Kex.Thing", [{none, core_lint,
    {undefined_function, {decorate,1}, {shouted,1}}}]}], []}
```

Invertedly, the same private method *is* callable from another module's make
block, which `docs/modules.md` says it should not be — the visibility is the
opposite of the documented rule in both directions.

Workaround: the helpers a make-method needs are declared in a module-level
`private do ... end` block instead (module-private functions are callable
from make-methods in the same module), which is how `src/catalog/book.kex`,
`draft.kex`, and `books.kex` are written.

### 14. Capitalized module constants resolve as Variants unless qualified

**Fixed** on `331cbb5`, by `c129086` — kexhq/kex#282 can be closed. Both
shapes the entry reported now work unqualified from inside the defining
module: an interpolation hole (`"between ${EARLIEST_YEAR} and ${LATEST_YEAR}"`
prints `between 1450 and 2100`) and arithmetic (`LATEST_YEAR - EARLIEST_YEAR`
is `650`). The knock-on failure is gone too — a module that references its own
constants unqualified still exports normally, and importers see everything.

`src/catalog/draft.kex` dropped the `Catalog.Draft.` prefixes inside its own
module, along with the comment warning against removing them. References from
*other* modules (`books.kex`, the specs) stay qualified — that is ordinary
cross-module access, not a leftover workaround.

See #16 for a separate limit these constants run into.

Found on `6ccdf35` while splitting `catalog.kex` into `catalog/`. Filed
upstream as kexhq/kex#282.

`let EARLIEST_YEAR = 1450` referenced unqualified — in an interpolation hole
or in arithmetic — passes the type checker and fails at run time:

```
Internal error: ... runtime error: Undefined function: EARLIEST_YEAR.showValue
Internal error: ... runtime error: Cannot add Variant and Integer
```

Worse, once a function in the defining module references its own constant
unqualified, that module's exports stop importing: the failure is reported as
`Undefined identifier` at the use site, with nothing pointing at the
definition. Qualified access — `Catalog.Draft.EARLIEST_YEAR`, the same shape
the stdlib's `Console.RED` always takes — works.

Workaround: every reference in `src/catalog/draft.kex`, `books.kex`, and the
specs is qualified, and the constants carry a comment saying why.

### 15. `[Book].sort` ignores `Comparable`

**Fixed** on `331cbb5`, by `2120598` — kexhq/kex#283 can be closed. The
no-argument `sort` now dispatches through `Comparable`: for a record whose
`compare` orders by year descending with a title tie-break, `books.sort` and
the explicit-comparator sort return the same list, and it is the declared
order rather than term order over the fields.

`examples/library` dropped the workaround. `Book` carries `implement:
Comparable` in `src/catalog/book.kex`, `[Book].sorted` in `books.kex` is a
plain `this.sort`, and the `before?` comparator is gone. Confirmed in the
running app as well as the specs: the listing comes back newest-first, and a
book added in a year that already has one sorts by title within that year.

One wrinkle for anyone writing `compare`: `String` does not implement
`Comparable`, so a title tie-break cannot be `@title.compare(other.title)` —
`book.kex` spells the three cases out in a `byTitle` helper over `<` and `>`.
A bare `then`/`else` returning `Less`/`Greater` does not type-check either
("'then' returns Less but 'else' returns Greater"); the helper's `-> Ordering`
annotation is what unifies them.

Found on `c5f3f6d` (and still on `6ccdf35`) while splitting `catalog.kex` into
`catalog/`. Filed upstream as kexhq/kex#283.

A record that `implement: Comparable` gets nothing from it in the no-argument
`sort`: "ascending natural order" is Erlang term order over the record's
fields, not the declared order. The trait machinery itself is sound — `compare`
and `thenBy` work, and the comparator form of `sort` produces the declared
order — so the gap is precisely the natural sort's dispatch. The term order
even looks plausible whenever the first field happens to be the one being
sorted by, which is how it slipped past a casual glance.

```
["A", "Alpha", "B", "C", "Zeta"]   # books.sort       — term order (title is the first field)
["B", "C", "A", "Alpha", "Zeta"]   # sort via compare — the declared order, thenBy included
```

Workaround: `src/catalog/books.kex` sorts with an explicit comparator —
`this.sort(~before?)` — rather than implementing `Comparable` and trusting
`.sort`.

### 16. Arithmetic on unannotated numeric constants stays `N`

Found on `331cbb5` while writing the #14 repro.

Two module constants bound to integer literals, subtracted, do not satisfy an
`Integer` annotation — the result keeps the unresolved numeric type variable
`N`:

```kex
let LOW = 1450
let HIGH = 2100

span : Integer
let span = HIGH - LOW      # error: Type mismatch: expected Integer, got N
```

The same arithmetic on the literals themselves is fine, so it is the trip
through the bindings that loses the resolution:

```kex
span : Integer
let span = 2100 - 1450     # No errors found.
```

There is no way to pin it at the definition either: a constant cannot carry a
type annotation, and `LOW : Integer` above `let LOW = 1450` is a parse error
("Unexpected token at top level: :").

Workaround: drop the annotation from the function that does the arithmetic and
let it infer — `let span = HIGH - LOW` alone compiles and prints `650`.
`examples/library` is unaffected: its constants are compared and interpolated,
never subtracted under an annotation.

### 17. Multi-clause functions silently drop clauses when the argument's static type is an abstract union

**Fixed**, closing kexhq/kex#347 — merged 2026-09-19 (`kexhq/kex` `main` @
`b913dac`, PR #374's "Even more fixes" commit, alongside its own new
regression spec `spec/multiclause_record_pattern_dispatch.kex`, which mirrors
this entry's exact `respond`/`dispatchGeneric` shape and passes). Re-verified
against that build and migrated `src/rodolfo.kex`: `Rodolfo.respond` is genuine
multi-clause style again — one `let`/`foul respond(...)` declaration per
`Reply` variant, ending in a catch-all `respond(other: Any, route: String)`
for #7's "not actually a Reply" case — instead of one function with an
internal `match`. Full spec suite (48 examples in `spec/rodolfo.spec.kex`,
including every case that specifically exercises `respond` from inside a
served request's closure, plus all 67 across `examples/library`) passes
unchanged.

Filed upstream as kexhq/kex#347.

Found on `293a0b5` while converting `Rodolfo.respond` (this repo's
`src/rodolfo.kex`) from one function with an internal `match` to Kex's other
documented style for the same thing — separate `let f(Pattern1) = ...`
declarations, one per shape, checked top-to-bottom (`docs/pattern-matching.md`
§ Multi-Clause Functions).

Called directly, every clause worked:

```kex
foul respond(reply: String, route: String) -> ... = ...
foul respond(Response.JSON { status, body, headers }, route: String) -> ... = ...
foul respond(Response.Text { status, body, headers }, route: String) -> ... = ...
# ... Response.HTML, Response.Raw, Response.Empty, Response.Redirect, Any — nine clauses total

respond(Response.JSON { body: "{}" }, "r")   # => the JSON clause's body, correctly
respond("hi", "r")                           # => the String clause's body, correctly
```

`Rodolfo`'s router compiles each route to a closure that calls `respond` on
whatever the application's handler returned — a value statically typed as
the seven-way union `Reply`, not any one variant, because which variant it is
is only known once the handler actually runs:

```kex
handler: do |request, context|
  respond(definition.handler(Context { request: request, context: context }), route)
end
```

Every route that returned anything other than a bare `String` crashed the
server on its first request — 10 of `spec/rodolfo.spec.kex`'s 36 cases,
every one of them returning a `Response.*` record. `--emit-core` on the
module shows why: the nine declared clauses compiled down to *one* function
clause, keeping only the first declaration's body —

```erlang
'respond'/3 =
  fun (Reply, Route, _ir_Ctx279) ->
    call 'Kex.Net.HTTP.Response':'text'(200, Reply, _ir_Ctx279)
```

— the `String` clause's body, called unconditionally regardless of the
argument's actual shape. So multi-clause dispatch is resolved per call
site at compile time from the argument's *static* type, not by a runtime
tag check: a call site that already knows the concrete type (a literal
`Response.JSON { ... }` in `main`) picks the right clause and looks
correct; a call site that only knows the argument as the wider union
compiles to something else entirely, with no diagnostic pointing at the
gap either at `-C` or at `-r`.

`match` does not have this problem — it dispatches on the value's runtime
tag regardless of the scrutinee's static type, which is exactly why the
original `respond` (one function, an internal `match`) always worked.

Workaround: `Rodolfo.respond` in `src/rodolfo.kex` is one `foul` function with
an internal `match`, not multi-clause overloads — see the comment above it.
Multi-clause style is fine for a function whose caller always supplies a
concretely-typed argument (`redirectTo`, a few lines above it in the same
file, is exactly that: called with a literal `Redirection` variant at every
call site); reach for `match` instead whenever the value being dispatched on
can only be a wider union at the call site that matters, and stack traces
through a handler, callback, or process boundary are exactly where that
tends to happen.

### 18. Two records in one module sharing a field name corrupts the other's accessor at runtime

**Fixed** — re-verified 2026-09-17 against `kex 0.4.0-beta.3 (3ee1b81)`; see
the dated entry above for the exact re-test and what changed in
`src/rodolfo.kex`. kexhq/kex#348 can be closed.

Filed upstream as kexhq/kex#348.

Found on `293a0b5` while adding `Rodolfo.Router`'s scope-flattening step
(`src/rodolfo.kex`). Two records — `Definition` (`method`, `path`, `handler`)
and a second one introduced alongside it, `Flat` (`method`, `path`, `plugs`,
`handler`) — declared in the same module with identical field names. Building
a `Flat` and reading it straight back miscompiles:

```kex
record Definition do
  method : String
  path : String
end

record Flat do
  method : String   # same field name as Definition's
  path : String
  extra : String
end

let toFlat(d: Definition) = Flat { method: d.method, path: d.path, extra: "x" }
```

Calling `.method` on the resulting `Flat` doesn't error and doesn't return
the right thing either — reading it back through the accessor generated for
the OTHER record with that field name returns `Undefined method: method for
Tuple` or silently reads the wrong value at runtime, depending on which
accessor wins; `kex -C` reports nothing. This is a sibling to the
`plug`/`PlugEntry.plug` collision that crashed `erlc` outright earlier in
this file (a top-level function and a record field sharing a name) — here it
is two records' fields sharing a name, and the failure is quieter: a bad
runtime value instead of a compile-time crash.

Workaround: `Flat` was changed to a plain tuple (`(String, String, [Plug],
Handler)`) instead of a record, sidestepping accessor generation entirely —
see `flattened`/`compileFlat` in `src/rodolfo.kex`. More generally: give two
records in the same module distinct field names, or expect a real bug if
they collide, not just a warning.

### 19. A call without a trailing block needs parens — this is the design, not a defect

**Retracted** — filed upstream as kexhq/kex#349, then closed after a
direct nudge (thanks) to re-check the premise. There is no bare
whitespace-juxtaposition call syntax in Kex outside the `verb "literal" do
... end` / `verb "literal" { ... }` trailing-block sugar. The original entry
below claimed `verb someCall(withArgs)` — the argument ending in its own
`)` — parses bare while only a plain reference argument doesn't; that
distinction doesn't exist. Neither parses, and the split I thought I saw was
an artifact of not having tried a same-shaped case without a trailing block:

```kex
let takeOne(x: Integer) -> Integer = x + 1
main do
  let result = takeOne 5   # compiles — but `result` is the *function value*
end                         # `takeOne`, and `5` is a separate, silently
                             # discarded statement, not an argument
```

```kex
get "/hi" helloHandler     # error: Undefined identifier: get
get("/hi", helloHandler)   # fine
```

`get "/hi" helloHandler` — a string argument *and* a bare reference, no
trailing block — fails exactly like `plug errorsPlug` did; `get "/path" do
|_| ... end` only ever worked because of the trailing block, not because its
first argument is a string literal. So: any call without a trailing block
needs full parens around its arguments, full stop, everywhere — not a
`Block<[A]>` quirk, not specific to one argument shape. `plug`, `scope`, and
`mount`'s doc comments in `src/rodolfo.kex` write every example call with
explicit parens because that's simply what a call without a trailing block
requires, not to route around a defect.

### 21. A named function passed as a value loses its type — or its body — when the function returns another function

**Still reproduces**, in a fourth shape — re-verified 2026-09-19 against
`kex main` (`b913dac`), which includes kexhq/kex#366's fix. The explicit,
alias-free signature (`(Context -> Reply) -> (Context -> Reply)`) now
type-checks and runs correctly, confirming #366 really did fix the
parenthesized-arrow-counting bug. But Rodolfo's `Plug`/`Handler` are `type`
aliases (`type Handler = Context -> Reply; type Plug = Handler -> Handler`),
and the exact same annotation spelled through those aliases still hits the
identical "declares 0 parameter(s) but definition has 1" warning followed by
a type error — the checker doesn't resolve an alias to its arrow shape before
counting. Filed as its own issue, kexhq/kex#375, with a minimal alias-only
repro (`type Fn = Integer -> Integer; type Wrap = Fn -> Fn`, no Rodolfo
involved). Workaround unchanged: a plug stays a closure literal — spelling
out `Plug`'s full expansion in every plug's annotation to dodge this would
defeat the point of the alias existing at all.

Filed upstream as kexhq/kex#350. **Partially retracted** — the primary
repro below (`addPair`/`check`) was never a real bug: `addPair`'s honest
type is `Integer -> (Integer -> Integer)`, which never matched what `check`
wanted, and the current build's error message makes that plain by reporting
the correct (no longer flattened) structure — `check(addPair)`, no `~` at
all, fails identically. The `check(~addPair)` half of this entry is
therefore not evidence of anything. What's still real: `plug(~poweredBy)`,
where `Handler`'s return type is Rodolfo's actual multi-variant, cross-module
`Reply`, still fails via `kex -r` (not `-C`) with the type reconstructed as
`... -> Unknown`. A same-shaped same-module 3-variant union does not
reproduce, so the trigger is narrower than "curried functions" — something
about a cross-module and/or larger union specifically, not isolated further.
Re-verified on `cc5c195`; see the correction comment on kexhq/kex#350.

Found on `293a0b5` while answering "why can't a plug be a normal `let
name(inner) = ...` function instead of a `do |inner| do |env| ... end end`
value?" It can be written that way and `kex -C` says nothing is wrong; it
just does not work, in two different ways depending on how it is passed.

Minimal repro, no Rodolfo involved — a function returning a function, passed
by name to something expecting that type:

```kex
let addPair(x: Integer) -> (Integer -> Integer) = do |y| x + y end

check : (Integer -> Integer) -> Integer
let check(f) = f(10)

main do
  IO.printLine("${check(addPair)}")
end
```

**Passed bare** (`check(addPair)`): `kex -C` says "No errors found." — and
`kex -r` crashes the Erlang build instead of running:

```
kex_nf4: unbound variable 'AddPair' in main/0
error: erlc failed
```

The type checker is satisfied that `addPair` is usable as an `Integer ->
Integer`, but codegen never actually captures it as a value at the call
site — `-C` gives false confidence here, the same shape as #17.

**Passed via `~`** (`check(~addPair)`), the operator that exists precisely
for turning a named function into a value: this reaches the type checker,
but the checker has flattened the reference's curried shape into the wrong
arity —

```
error: `check` expects argument 1 to be Integer -> Integer, but got Integer -> Integer -> Integer

check : (Integer -> Integer) -> Integer
```

`~addPair`'s real type is `Integer -> (Integer -> Integer)` — one parameter,
returning a function — but the checker reports it as the 2-ary `Integer ->
Integer -> Integer`. In the `Rodolfo.Plug` case (`Handler -> Handler`,
i.e. `(Context -> Reply) -> (Context -> Reply)`) the same reconstruction
loses more and the reported type is `... -> Unknown` instead of a flattened
arity, but it is the same failure: `~name` does not preserve "my own
parameter list" versus "my return type, which happens to be an arrow" for a
curried/higher-order function.

Workaround: write a plug as a value — `let name = do |inner| do |env| ...
end end` — never as a named function passed by name or by `~`. A closure
literal is never routed through either broken path. See the `Plug` type's
doc comment in `src/rodolfo.kex` for the full shape and rationale.

### 22. A block can't ignore a parameter it doesn't need — `|_|` (or a named, unused binding) is mandatory everywhere

**Fixed** on `cc5c195` (merged via kexhq/kex#359) — but only for stdlib
block-takers. `3.times do IO.printLine("hi") end` runs fine with no `|_|`,
but the fix isn't a general "a zero-arg block satisfies a one-arg function
type" coercion: `.times`' own signature grew a **second overload**,
`times :> Block<Void> -> Void`, alongside the original `(Integer -> Void) ->
Void` — `Block<T>` is a compiler-builtin marker type for exactly this,
`kex -C`'s special-cased in the parser and type system, not something a
library defines itself.

Confirmed the hard way: `get "/" do "Hello from Kex!" end` (no `|_|`) against
`Handler = Context -> Reply` type-checked clean via `kex -C` **and** `--run`,
the server started fine — and crashed with a real `500 Internal Server
Error` the moment an actual request hit that route, since nothing ever
coerced the zero-arg block into a real `Context -> Reply`. This is worse
than the original bug: it compiles and runs right up until a request
actually arrives.

2026-09-19: migrated `src/rodolfo.kex` to the same `Block<T>`-overload
pattern `.times` itself uses — `route`, `get`, `post`, `put`, `patch`,
`delete`, `head`, and `options` each gained a second declaration taking
`Block<Reply>` instead of `Handler`, wrapping it into a real handler that
discards the context (`do |_| block() end`). Verified end to end against a
live server: `get "/" do "Hello from Kex!" end` now answers 200 with the
right body, and a one-arg `do |ctx| ... end` route on the same router still
resolves to the other overload correctly. Speced in `spec/rodolfo.spec.kex`.

The silent-crash gap itself — `kex -C` catches it, `--run` doesn't, and
nothing logs anything when the mismatched handler is actually invoked —
is filed separately as kexhq/kex#378, using `rodolfo.kex` at `41057d7~1`
(before this migration) as the repro. I spent a long time trying to reduce
it to a minimal, Rodolfo-free case and couldn't reliably reproduce the
*silent* part outside Rodolfo's actual module — every trimmed-down version
with the same type shapes got caught correctly by both `-C` and `--run`.
Filed with the real repro rather than continuing to chase an isolated one.

Filed upstream as kexhq/kex#354.

Found on `293a0b5` while asking "does a Rodolfo route handler need to bind
the request context it never uses?" There is no way to write a
zero-parameter block and have it satisfy a function type expecting one
argument — the missing parameter is never implicitly discarded, no matter
how obviously unused it would be. Not a `Handler`/Rodolfo quirk: the same
failure hits the stdlib's own block-taking functions.

```kex
[1, 2, 3].each do
  IO.printLine("tick")
end
# error: `each` expects argument 2 to be A -> Void, but got () -> Void

3.times do
  IO.printLine("hi")
end
# error: `times` expects argument 2 to be Integer -> Void, but got () -> Void

get "/" do
  "Hello from Kex!"
end
# error: `get` expects argument 2 to be Context -> Reply, but got () -> String
```

All three work with an explicit discard — `.each do |_| ... end`, `.times do
|_| ... end`, `get "/" do |_| ... end` — which is exactly why `src/rodolfo.kex`
and `README.md`'s examples all write `|_|` even where the value is never
used. `Integer#times` is the sharpest case: the index is routinely
irrelevant ("do this 3 times"), so this isn't a stretched edge case — it's
the common one.

An overload at the call-site library level — `get` accepting either
`Context -> Reply` or `() -> Reply` — looked like a possible workaround, but
didn't resolve cleanly either (the two candidates didn't unify the way a
manual dispatch would expect), so this isn't something a caller can paper
over on their own.

Workaround: none. Every block argument needs an explicit binding for every
parameter position the function type declares, used or not.

### 23. `Net.Socket` + `Net.HTTP.WebSocket` crash `erlc` — blocks WebSocket routes on a real server

**Fixed** on `a4f7330` (merged via kexhq/kex#365), closing kexhq/kex#360.
Re-verified 2026-09-17 by running kex's own new regression specs
(`spec/net_socket_websocket_close_collision_beam.kex` and
`spec/net_socket_websocket_minimal_beam.kex`) — both pass, including the
real `close`/`closed?` calls on each colliding type.

2026-09-18: built the `ws "/path" do |socket| ... end` route this and #20
unblocked — `WsDefinition`, `SocketHandler`, and `ws` in `src/rodolfo.kex`,
speced in `spec/rodolfo.spec.kex` ("Rodolfo serves WebSocket routes"),
documented in `README.md`. Two things worth recording from building it:

- `Client.close()` (an existing, working call, unrelated to any of this)
  gets misreported by `kex -C` as an arity/overload mismatch the moment
  `Net.HTTP.WebSocket` is anywhere in the compiled program's module graph —
  merely being compiled in is enough, regardless of which names are
  `using`-imported from it, or with what `only:`/`except:` list. This is a
  false positive: `--run` (the real BEAM path) compiles and executes every
  such call correctly, matching #21's already-established pattern of `-C`
  and `-r`/`--run` disagreeing over the same program. No workaround needed
  since nothing is actually broken, but worth knowing `kex -C` on any
  program using both `Rodolfo` and `Net.HTTP.WebSocket` will show this.
- `WebSocket.connect` (and, presumably, any function in a module Rodolfo's
  own code imports but never itself calls) type-checks fine through
  Rodolfo's re-export but is "Undefined function" at runtime unless the
  *calling* module also imports `Net.HTTP.WebSocket` itself — the codegen
  omits an export the entry compilation unit never reaches, the same class
  of bug as #1/#2 (`serving` slots not exported), just for a plain function.
  `spec/rodolfo.spec.kex` works around it with its own direct
  `using Net.HTTP.WebSocket, only: [WebSocket, ...]`, and `README.md`'s
  example does the same for `Message`'s variants.

Filed upstream as kexhq/kex#360.

Found on `cc5c195` immediately after #20 shipped, trying to build a `ws`
(WebSocket route) DSL function on top of it — Rodolfo already `using
Net.Socket` for its ordinary HTTP server, and adding `Net.HTTP.WebSocket`
crashes `erlc` before any code runs, let alone a `ws` route being hit:

```kex
using Net.Socket
using Net.HTTP.WebSocket

main do
  IO.printLine("compiled fine")
end
```

```
exception error: {key_exists,{b_local,{b_literal,close},2}}
  in function  gb_trees:insert_1/4 (gb_trees.erl:363)
  ...
error: erlc failed
```

`Net.Socket.TCP` and `Net.HTTP.WebSocket.Connection` each have their own
`close`/`closed?` methods, and having both in the compiled program's module
graph collides at the `erlc` SSA pass — the same class as #18, except this
time both sides are in kex's own stdlib, so there is no name on the
application side to rename.

Worse than #18: the trigger is fragile and not fixable by adding names to
scope reliably. Pulling `Net.HTTP`'s `Client` into scope alongside the other
two imports makes the 7-line repro above compile and run — but the same
trick, applied to Rodolfo itself (which also touches `Rodolfo.Markup`,
`Rodolfo.Response`, `URI`, ...), did not: same crash, a different colliding
name (`closed?` instead of `close`) depending on exactly what else was
compiled alongside it. And the bug isn't gated on runtime use at all —
merely *declaring* `ws`/`WsDefinition`/`Socket` types and a `compileWs`
function in `src/rodolfo.kex`, with no application anywhere declaring an
actual `ws` route, was enough to crash the entire existing spec suite, none
of which touches WebSocket.

Workaround: none found. A `ws` DSL function was written, type-checked
cleanly, and then reverted out of `src/rodolfo.kex` entirely — its presence
alone breaks the whole framework's build, not just WebSocket-route usage.
Rodolfo has no WebSocket route support until this is fixed upstream; #20
being fixed did not unblock it. Same shape as #1/#2: the defect decided the
architecture, not the other way around.

## Ctrl+C does not stop a running server

**Fixed** on `5a088fe`, by `85be62e` ("Attempt to fix SIGINT" — the name is
no longer accurate). Re-verified with the same kind of pty harness as below
(`os.setsid()` + `TIOCSCTTY`), against a small `Net.HTTP` server run through
`kex -R` directly:

```
before Ctrl+C: port free? True   (checked before the bind, so this is expected)
>>> writing 0x03 (Ctrl+C)
process exited within 10s: True
after Ctrl+C: port free? True
```

The fix is `forwardSignalToChild` now forwarding SIGINT as SIGTERM (which
`erl_signal_server` and `kex_child_guard` can act on, unlike a raw SIGINT to
the BEAM break handler), paired with running the node under `erl +Bi` so the
VM itself ignores the direct SIGINT the terminal also delivers and only the
forwarded SIGTERM does anything. Both halves are in `src/main.cxx`; see that
commit's comments for the full reasoning. The original repro below is kept
for reference.

Reported separately by the user, and the cause is in the `kex` driver rather
than in Rodolfo.

`Rodolfo.run` ends in `Server.serve`, which is `start` + `join`; `join_owner`
blocks in `receive {'DOWN', ...}`. Kex exposes no signal API, so Rodolfo
cannot install a SIGINT handler of its own.

`kex -R` shells out (`src/main.cxx:3758`, via `std::system`) to

```
erl -noshell -pa ... -eval ...
```

with no `+B` flags, so BEAM's break handler owns SIGINT.

Verified with a pty harness (`os.setsid()` plus
`ioctl(slave, TIOCSCTTY, 0)`), i.e. with a real controlling terminal:

```
before Ctrl+C: SERVING (HTTP 200)
>>> writing 0x03 (Ctrl+C) to the terminal
[terminal output] '^C\r\r\n\x1b[JBREAK: (a)bort (A)bort with dump (c)ontinue ...'
kex exit status: None
after Ctrl+C: not serving (TimeoutError)
>>> writing 'a' + Enter (BREAK menu abort)
kex exit status: 0
after abort: not serving (URLError)
```

So Ctrl+C prints the BREAK menu and the VM stops answering requests, but the
OS process stays alive and the port stays bound until `a` + Enter. Also
verified: with stdin not a terminal, SIGINT terminates the node; and
`erl -noshell +Bd` alone makes SIGINT ignored entirely.

The fix belongs in the driver: disable the break handler and let SIGINT
terminate the node — `+Bd` together with `os:set_signal(sigint, default)` in
the `-eval` preamble. **This combination is not verified** — the two harness
runs that would have confirmed it hung and were killed without producing
output.
