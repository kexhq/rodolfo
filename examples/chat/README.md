# Chat

A broadcast WebSocket chat room: a shared room password, a display name per
connection, and every message sent to everyone currently joined. It is the
smallest example that touches `ws`, `serving`, and `Plug`'s newer
`Plug.around` style together.

![The chat room](screenshot.png)

## Running it

```sh
tey install
tey run        # http://localhost:3000/
```

Open that URL in two or more browser tabs (or two different browsers), enter
`let-me-in` as the room password and a different name in each, and chat
between them.

## It is part of the Rodolfo monorepo

This example is a member of the checkout's Tey workspace (see the root
`package.kex`), so its own `package.kex` resolves Rodolfo from this checkout
rather than from a published release:

```rb
tey("rodolfo", workspace: true)
```

That line only works inside the workspace. Copied out of the monorepo, the
example stops installing until `package.kex` points at a release instead, the
way any other package would:

```rb
tey("rodolfo", git: "https://github.com/kexhq/rodolfo", tag: "~> 0.2")
```

or `tey add rodolfo --git https://github.com/kexhq/rodolfo --tag "~> 0.2"`,
then `tey install` again.

## Layout

| File | Owns |
| --- | --- |
| `src/main.kex` | the room password, the `serving Room` connection registry, and the routes |
| `src/chat/views.kex` | the login form and the chat page (module `Chat.Views`), escaped through Rodolfo's markup tags |

Both `Chat.Views` and `examples/library`'s own `Library.Views` are
namespaced to the example they belong to on purpose: `tey` resolves the
workspace `rodolfo` dependency by pulling in every sibling example under
`examples/*`, so a bare `module Views` in more than one of them collides —
see `docs/kex-issues.md` #26.

## How the password and name travel

There's no session or cookie here — the room password and display name are
query parameters on the WebSocket URL itself (`/chat?token=...&name=...`),
checked by the `ws` handler after the handshake completes (Rodolfo's `ws`
always accepts the upgrade; closing the connection right away is how it
rejects one after the fact). Good enough to show `ws` reading the request it
was upgraded from — not how real auth should work.
