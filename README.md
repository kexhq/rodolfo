# Rodolfo

Rodolfo is a tiny Kemal- and Sinatra-inspired web framework for Kex. Routes
use top-level HTTP verbs inside a `Rodolfo.run` block — Kex's `Block<[A]>`
collection blocks turn the route list into a plain do...end body instead of
an explicit array.

```kex
using Rodolfo

main do
  Rodolfo.run do
    get("/") do |_|
      "Hello from Kex!"
    end

    get("/hello/:name") do |env|
      "Hello, ${env.param("name").try}!"
    end
  end.try
end
```

`get`, `post`, `put`, `patch`, and `delete` return text by default. Use
`respond(method, path)` when a route needs custom status, headers, or binary
content. `route(method, path)` handles any other HTTP method. Pass a port
with `Rodolfo.run(8080) do ... end`; it defaults to `3000`.

## Examples

- `examples/hello.kex` — dynamic parameters and request bodies
- `examples/statusapi.kex` — JSON health and catalog API
- `examples/website.kex` — server-rendered HTML responses
- `examples/requestinfo.kex` — reusable route-handler wrapping

## Develop

```sh
tey install
tey test --interpret
kex --source-root src examples/hello.kex
```
