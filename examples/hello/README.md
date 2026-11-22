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

## In a browser

`spec/browser/hello.spec.kex` drives the example in Chrome through
[Shakespeare](https://github.com/kexhq/shakespeare): the greeting pages, and a
body a page script posts to `/echo`. Each case serves the routes in
`src/hello/site.kex` on a port of its own.

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
