# Rodolfo

Rodolfo is a tiny Kemal- and Sinatra-inspired web framework for Kex. Routes
use top-level HTTP verbs inside a `run` block — Kex's `Block<[A]>` collection
blocks turn the route list into a plain do...end body instead of an explicit
array, and paren-less DSL calls keep the declarations reading like prose:

```kex
using Rodolfo

main do
  run do
    get "/" do |_|
      "Hello from Kex!"
    end

    get "/hello/:name" do |env|
      "Hello, ${env.param("name").try}!"
    end
  end.try
end
```

`get`, `post`, `put`, `patch`, and `delete` return text by default. Use
`respond "METHOD", path` when a route needs custom status, headers, or binary
content, and `route "METHOD", path` for any other HTTP method. Pass a port as
`run 8080 do ... end`; it defaults to `3000`. `build` compiles the same block
into a router without opening a socket, and `start` runs it asynchronously for
tests — see `spec/rodolfo.spec.kex`.

## Use it as a package

Rodolfo is a Tey package, published by tagging this repository. In your own
package's `package.kex`:

```kex
tey("rodolfo", git: "https://github.com/kexhq/rodolfo", tag: "~> 0.1")
```

or let `tey add` write the line and the lockfile:

```sh
tey add rodolfo --git https://github.com/kexhq/rodolfo --tag "~> 0.1"
tey install
```

The tag is the release, and `~> 0.1` takes the newest `0.1.x`; Tey resolves it
against this repository's tags and records the exact commit in `tey.lock`.

With the dependency installed, `using Rodolfo` brings the whole DSL into
scope: the verbs, `run`, `build`, and `start` are plain functions, so a route
list is just a block of calls:

```kex
using Rodolfo

main do
  run do
    get "/" do |_| "home" end

    respond "GET", "/health" do |_|
      Net.HTTP.Response.text(200, "ok")
    end
  end.try
end
```

## Examples

Each example is itself a Kex package that depends on this library the way an
outside consumer would — through Tey, resolved from the Git repository, not
from this checkout:

- `examples/hello` — dynamic parameters and request bodies
- `examples/statusapi` — JSON health and catalog API
- `examples/website` — server-rendered HTML responses
- `examples/requestinfo` — reusable route-handler wrapping

```sh
cd examples/hello
tey install   # fetches rodolfo into the Tey cache, per tey.lock
tey run       # serves http://localhost:3000
```

`tey test` in an example runs its `spec/` directory; there are none yet. The
examples' `tey.lock` pins the `main` branch's tip commit, so after changing
the library, refresh them with `tey update` in each example directory.

## Develop

```sh
tey install   # fetch dependencies
tey build     # compile src/ into ebin/
tey test      # run spec/*.spec.kex on the BEAM
```

Rodolfo needs Kex `>= 0.4.0-beta`; pick a toolchain with `tey kex install`.

## Release it

```sh
git tag -a v0.1.1 -m "Rodolfo 0.1.1" && git push origin v0.1.1
```

The tag is the release — `tey add ... --tag "~> 0.1"` resolves against it.
Keep the tag in step with `version` in `package.kex`.
