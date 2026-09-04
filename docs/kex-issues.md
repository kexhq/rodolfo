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

## Re-verified 2026-09-04, against `kex 0.4.0-beta.2 (5a088fe)`

`../kex` moved 25 commits past `c5f3f6d`, built from `make build` /
`make build-tey`, and every item below was re-run against that build with a
standalone repro (not through `examples/library`, so the result is about the
compiler, not about whether the example's workaround happens to still work).
`examples/library` itself was then updated to drop the workarounds for
whatever came back fixed; its `spec/` suite (62 examples) and a manual
`tey run` smoke test (GET, POST, redirect) still pass.

Fixed: #3, #4, #6, #7, #8, #10, #12, and Ctrl+C. Still reproduces: #1, #2, #9,
#11. #5 is moot — see its entry. Each entry below is marked inline.

## Blocking

### 1. `serving` slots are not exported once the program depends on `Net.HTTP`

**Still reproduces** on `5a088fe`. Same repro, same `{'function not exported', ...}`,
whether or not the route-handler wiring goes through `Net.HTTP` at all — a
bare `serving Counter do ... end` plus `using Net.HTTP` and one `foul`
function taking a `Server<Counter>` is enough. The `kex_child_guard.erl` and
process-related work in this range (`eb9cc34`, `8e633a1`) did not touch this
path.

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

**Still reproduces** on `5a088fe`. Same `{unknown_serving_slot, get}`, with a
`module Store do ... serving Counter do ... end ... end` in one file and
`using Store` from `main.kex` in another, `--source-root`-visible to it.

Independently of (1): a `serving` block in a module other than the entrypoint
fails on every call with

```
{unknown_serving_slot, add}
```

Moving the identical `serving` block into the entrypoint file resolves the
slot. So a process cannot be encapsulated in its own module at all, which is
the natural shape for a store.

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

New finding hit while re-checking this: calling a method that plainly does
not exist (`Headers.empty.set(...)`, still spelled that way on purpose) is no
longer a compile-time type error. It passes the checker and fails at runtime
with `Internal error: ... runtime error: Undefined method: set for
Net.HTTP.Headers` — both called inline in `main` and lifted into a top-level
function. `examples/library` never called `.set`, so this doesn't affect it,
but it's a regression in diagnostics worth its own report upstream: an
undefined-method call used to be caught before running.

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
kexhq/kex#272 can likely be closed once this is confirmed upstream.

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

**Still reproduces** on `5a088fe`, though the failure moved: `true.not` now
type-checks (no compile error) and fails at run time with `Internal error:
... runtime error: Undefined method: not for Bool`, instead of the earlier
compile-time "Undefined method" error. Net effect for a caller is the same —
there is still no direct spelling for negating an arbitrary `Bool` — but see
#5's new finding, which is the same runtime-instead-of-compile-time pattern
on a different undefined method.

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

**Still reproduces** on `5a088fe`. `cond do x > 3 then <multi-line> else 0
end end` is still a parse error at the first newline inside the `then` arm.
The helper functions in `catalog.kex` and `views.kex` that exist only to keep
`then`/`else` arms to one expression are all still needed.

`cond then` / `else` accepts single-expression arms only; splitting an arm
across lines is a parse error. Longer branches have to become a `match` or a
helper. Several helpers in `catalog.kex` and `views.kex` exist only for this.

### 12. `kex -C` does not resolve external modules

**Fixed** on `5a088fe`. A `kex -C --source-root src src/main.kex` against a
two-module package (`main.kex` using an external `Helper` module) now says
"No errors found." instead of reporting the import unresolved. `kex -C` is
usable again as the fast feedback loop the original entry wanted.

For a multi-module package, `kex -C` reports missing modules that `kex -R`
resolves from the same `--source-root`. Compile-only checking is therefore
not usable as a fast feedback loop; the reliable check is a full `kex -R`
run, which costs about 40–45 seconds of BEAM startup per invocation.

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
