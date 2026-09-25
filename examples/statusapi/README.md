# StatusAPI

A JSON health and catalog API: a `/health` check, a `/api/books/:id`
route that rescues a bad id into a 400, and an echo that returns its
request body.

## Running it

```sh
tey install
tey run        # http://localhost:4000/
```

Note the port: this one serves `4000`, not `3000`.

| Route | Try |
| --- | --- |
| `GET /health` | `curl http://localhost:4000/health` |
| `GET /api/books/:id` | `curl http://localhost:4000/api/books/7` |
| `GET /api/books/oops` | `curl http://localhost:4000/api/books/oops` — answers 400 |
| `POST /api/echo` | `curl -d "repeat me" http://localhost:4000/api/echo` |

## It is part of the Rodolfo monorepo

This example is a member of the checkout's Tey workspace (see the root
`package.kex`), so it resolves Rodolfo from this checkout rather than
from a published release. Copied out of the monorepo, point its
`package.kex` at a release instead:

```rb
tey("rodolfo", git: "https://github.com/kexhq/rodolfo", tag: "~> 0.2")
```

then `tey install` again.
