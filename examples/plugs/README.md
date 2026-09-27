# Plugs

Composable request/response plugs: code that runs around every route in a
router or scope, without repeating it inside each handler. A logging plug,
a response-header plug, and a token-gated `/admin` scope built with
`Plug.around`.

## Running it

```sh
tey install
tey run        # http://localhost:3000/
```

| Route | Try |
| --- | --- |
| `GET /` | `curl http://localhost:3000/` |
| `GET /admin/stats?token=let-me-in` | `curl "http://localhost:3000/admin/stats?token=let-me-in"` |
| `GET /admin/stats` (no token) | `curl -i http://localhost:3000/admin/stats` — answers 401 |

Watch the server's own output: every request logs a `--> method path`
line before the handler runs and a `<-- method path` line after.

## It is part of the Rodolfo monorepo

This example is a member of the checkout's Tey workspace (see the root
`package.kex`), so it resolves Rodolfo from this checkout rather than
from a published release. Copied out of the monorepo, point its
`package.kex` at a release instead:

```rb
tey("rodolfo", git: "https://github.com/kexhq/rodolfo", tag: "~> 0.2")
```

then `tey install` again.
