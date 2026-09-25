# Website

Server-rendered HTML responses: a shared `page` layout wrapping each
route's content, sent back as `Response.HTML`.

## Running it

```sh
tey install
tey run        # http://localhost:3000/
```

| Route | Try |
| --- | --- |
| `GET /` | open http://localhost:3000/ in a browser |
| `GET /authors/:name` | open http://localhost:3000/authors/ada in a browser |

## It is part of the Rodolfo monorepo

This example is a member of the checkout's Tey workspace (see the root
`package.kex`), so it resolves Rodolfo from this checkout rather than
from a published release. Copied out of the monorepo, point its
`package.kex` at a release instead:

```rb
tey("rodolfo", git: "https://github.com/kexhq/rodolfo", tag: "~> 0.2")
```

then `tey install` again.
