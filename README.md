# Rodolfo

Rodolfo is a tiny Kemal- and Sinatra-inspired microframework for Kex. A router
is a block of HTTP verbs — Kex's `Block<[A]>` collection blocks turn the route
list into a plain do...end body instead of an explicit array, which keeps the
`DSL` comletely immutable:

```rb
using Rodolfo

main do
  let site = Rodolfo.router do
    get "/" do |_|
      "Hello from Kex!"
    end

    get "/hello/:name" do |env|
      let name = env.param("name").or("world")
      "Hello, ${name}!"
    end
  end

  site.start(3000).try
end
```

`router` collects the declarations; nothing binds a socket until you `start`
it. `get`, `post`, `put`, `patch`, `delete`, `head`, and `options` are plain
functions, and `route "METHOD", path` declares anything else.

## Installing as a `Tey` package

Rodolfo is a `Tey` package, published by tagging this repository.

Use the commands:
```sh
tey add rodolfo --git https://github.com/kexhq/rodolfo --tag "~> 0.2"
tey install
```

Or pull it in manually in your own package's `package.kex`:

```rb
tey("rodolfo", git: "https://github.com/kexhq/rodolfo", tag: "~> 0.2")
```

The tag is the release, and `~> 0.2` takes the newest `0.2.x`; Tey resolves it
against this repository's tags and records the exact commit in `tey.lock`.


## Replies

A route block that returns a `String` — or anything else showable — sends it
as a 200 `text/plain` body, which is why `do |_| "hello" end` is a complete
route. Return one of the `Response` records to say more. Each carries a
`status` that defaults to a sensible one and `headers` that default to none,
so the usual case is a body and nothing else:

| Reply | Sends | Default status |
| --- | --- | --- |
| `Response.JSON { body }` | `application/json` | 200 |
| `Response.Text { body }` | `text/plain; charset=utf-8` | 200 |
| `Response.HTML { body }` | `text/html; charset=utf-8` | 200 |
| `Response.Raw { body, contentType }` | bytes, as you say | 200 |
| `Response.Empty {}` | no body | 204 |
| `Response.Redirect { location }` | a `Location` header | 302 |

```rb
get "/health" do |_|
  Response.JSON { body: JSON.stringify({ "status": "ok" }) }
end

post "/things" do |_|
  Response.Text {
    status: 201,
    body: "made",
    headers: Net.HTTP.Headers.empty.set("X-Created-By", "rodolfo")
  }
end
```

A reply's own `Content-Type` wins; the record's kind only fills the gap, so
`Response.Text` with an explicit `application/rss+xml` sends that.

## Failing inside a route

A `.try` that fails unwinds the route block. Catch it where you can answer it,
with `trying`:

```rb
get "/api/books/:id" do |env|
  let id = Integer.parse(env.param("id").try).try
  Response.JSON { body: JSON.stringify({ "id": id }) }

rescue |e|
  Response.JSON { status: 400, body: JSON.stringify({ "error": e.message }) }
end
```

Kex attaches `rescue` to named functions, not to blocks, so a bare
`rescue` directly inside `do |env| ... end` is a syntax error — `trying` is
the form that works there.

## Serving

`start` blocks, which is what a `main` wants; `background` returns a
`Server.Running` you can `stop`, which is what specs and managed lifecycles
want. Given only a port, both bind **loopback** — this machine and nothing
else:

```rb
site.start(3000).try                       # http://localhost:3000
let server = site.background(3000).try     # returns a handle
server.stop().try
```

A port bound on every interface is reachable by every machine on the network,
which is rarely what a program under development means, so widening it is a
written-out address rather than the default:

```rb
site.start("0.0.0.0", 3000).try            # every interface — the network
site.start("192.168.1.20", 3000).try       # one interface
site.start("0.0.0.0", 3000, options).try   # with Net.HTTP.ServerOptions
```

Port 0 asks the operating system for a free port, which is how a spec takes an
ephemeral one — see `spec/rodolfo.spec.kex`:

```rb
let server = site.background("127.0.0.1", 0).try
let port = server.localAddress.port.value
```

`site.httpRouter` is the `Net.HTTP.Router` the declarations compile to, for
serving it by hand or mounting it elsewhere, and `site.routes` is the compiled
route list in declaration order.

## Two names to watch

Kex resolves a method call against every function in scope, so `using Rodolfo`
puts two of its names in the way of stdlib ones (kexhq/kex#272):

- `headers.get("Content-Type")` resolves to Rodolfo's `get` verb. Reach the
  header through `headers.getAll(name).first` instead.
- `using Net.HTTP` unqualified brings in a second `Response` and a `Router`
  whose make-methods share the verbs' names. Import it selectively —
  `using Net.HTTP, only: [Client, Server, ServerOptions, Headers]` — or write
  `Net.HTTP.Response` in full.

Named arguments do not survive a package boundary on a make-method, so it is
`site.start(3000)` rather than `site.start(port: 3000)` from a package that
depends on Rodolfo.

## Examples

Each example is itself a Kex package that depends on this library the way an
outside consumer would — through Tey, resolved from the Git repository, not
from this checkout:

- `examples/hello` — dynamic parameters and request bodies
- `examples/statusapi` — JSON health and catalog API, with a rescued route
- `examples/website` — server-rendered HTML responses
- `examples/requestinfo` — reusable route-handler wrapping
- `examples/library` — a book-management CRUD interface: list, search, add,
  edit, delete, lend, and return, in plain HTML forms

The examples are workspace members, so they resolve Rodolfo from this checkout
rather than from a published tag — one `tey install` at the root covers them:

```sh
tey install
cd examples/hello
tey run       # serves http://localhost:3000
```

The library example reads two variables: `PORT` moves it off `3000`, and
`LIBRARY_FILE` names the tab-separated file its catalogue is kept in
(`books.tsv` by default, written with fourteen books on the first run):

```sh
cd examples/library
PORT=4000 LIBRARY_FILE=/tmp/books.tsv tey run
```

`tey test` in an example runs its `spec/` directory: `examples/library` has
specs for its pure catalogue rules, its pages' escaping, and its file store.

## Develop

```sh
tey install   # fetch dependencies
tey build     # compile src/ into ebin/
tey test      # run spec/*.spec.kex on the BEAM
```

Rodolfo needs Kex `>= 0.4.0-beta.2`; pick a toolchain with `tey kex install`.
The floor is not cosmetic: before that release an application function could
displace a library's `private do` helper of the same name and arity, which
silently disabled the escaping behind `html$`. `spec/rodolfo.spec.kex` defines
`rendered`, `interleave`, and `field` at the top precisely to collide with
Rodolfo's internals, and those cases fail on an older toolchain.

## Release it

```sh
git tag -a v0.2.0 -m "Rodolfo 0.2.0" && git push origin v0.2.0
```

The tag is the release — `tey add ... --tag "~> 0.2"` resolves against it.
Keep the tag in step with `version` in `package.kex`.
