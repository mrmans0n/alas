# Plugin API v10

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 9 in [api-v5.md](api-v5.md),
> [api-v6.md](api-v6.md), [api-v7.md](api-v7.md), [api-v8.md](api-v8.md) and
> [api-v9.md](api-v9.md); everything there still applies.

API 10 tells a plugin which SSH host its project runs on, and says so when a
command or file request can't reach a worktree on that host.

## The `api` field

Alas loads plugins with `"api": 4` to `10`. API 10 adds nothing to the
manifest. A plugin that declares it can rely on everything below; older
plugins get the same messages.

## Where the project runs

`alas/activate`'s `project` carries `host`, the project's SSH host, when the
project is remote. A local project has no `host`.

```json
{ "project": { "id": "9F1C…", "name": "api", "host": "devbox" }, "api": 10, "grants": [] }
```

Remoteness is per project, so the snapshot has no new field.

## Remote worktrees

`process/*` and `file/*` run on this Mac, so they can't use a worktree of a
remote project yet. They answer `-32003` with a message that names the host:

```
worktree wt is on remote host devbox; plugins can't run commands or use files there yet
```

A worktree id the project doesn't have still answers `-32003 "unknown worktree
…"`. Every other method, snapshots, sessions, tasks, runs and reviews, works on
remote projects as before.
