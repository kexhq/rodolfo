# Hello

Dynamic parameters and request bodies: a static greeting, a `:name`
segment, and an echo that returns its request body.

## Running it

```sh
tey install
tey run        # http://localhost:3000/
```

| Route | Try |
| --- | --- |
| `GET /` | `curl http://localhost:3000/` |
| `GET /hello/:name` | `curl http://localhost:3000/hello/ada` |
| `POST /echo` | `curl -d "repeat me" http://localhost:3000/echo` |

## It is part of the Rodolfo monorepo

This example is a member of the checkout's Tey workspace (see the root
`package.kex`), so it resolves Rodolfo from this checkout rather than
from a published release. Copied out of the monorepo, point its
`package.kex` at a release instead:

```rb
tey("rodolfo", git: "https://github.com/kexhq/rodolfo", tag: "~> 0.2")
```

then `tey install` again.
