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

## Blocking

### 1. `serving` slots are not exported once the program depends on `Net.HTTP`

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
