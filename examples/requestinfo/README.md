# RequestInfo

Reusable route-handler wrapping without hidden global state: a plain
function takes a handler and returns a handler that prefixes the reply
with the request's method and path.

## Running it

```sh
tey install
tey run        # http://localhost:3000/
```

| Route | Try |
| --- | --- |
| `GET /` | `curl http://localhost:3000/` |
| `GET /orders/:id` | `curl http://localhost:3000/orders/42` |

## In a browser

`spec/browser/requestinfo.spec.kex` drives the example in Chrome through
[Shakespeare](https://github.com/kexhq/shakespeare): the home page and the
wrapped order route. Each case serves the routes in
`src/request_info/site.kex` on a port of its own.

```sh
tey test:browser   # headless, in the background
tey test:watch     # a visible Chrome, each action highlighted and paced
```

`tey test` leaves them out: it runs `spec/*.spec.kex` alone.

## It is part of the Rodolfo monorepo

This example is a member of the checkout's Tey workspace (see the root
`package.kex`), so it resolves Rodolfo from this checkout rather than
from a published release. Copied out of the monorepo, point its
`package.kex` at a release instead:

```rb
tey("rodolfo", git: "https://github.com/kexhq/rodolfo", tag: "~> 0.2")
```

then `tey install` again.
