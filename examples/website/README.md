# Website

Server-rendered HTML responses: a shared `layout.html.ket` wrapping each
route's page, compiled in with `Kex.embed` and `Template.html`, sent back as
`Response.HTML`, and styled by a stylesheet `publicFolder` serves from
`public/`.

## Running it

```sh
tey install
tey run        # http://localhost:3000/
```

| Route | Try |
| --- | --- |
| `GET /` | open http://localhost:3000/ in a browser |
| `GET /authors/:name` | open http://localhost:3000/authors/ada in a browser |
| `GET /site.css` | `curl -i http://localhost:3000/site.css` — `public/site.css`, as `text/css` |

`public/` is found relative to the working directory, so run the example from
this directory.

## In a browser

`spec/browser/website.spec.kex` drives the example in Chrome through
[Shakespeare](https://github.com/kexhq/shakespeare): both pages, the nav link
between them, and the stylesheet `publicFolder` serves. Each case serves the
routes in `src/website/site.kex` on a port of its own.

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
