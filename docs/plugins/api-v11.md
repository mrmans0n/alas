# Plugin API v11

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 10 in [api-v5.md](api-v5.md),
> [api-v6.md](api-v6.md), [api-v7.md](api-v7.md), [api-v8.md](api-v8.md),
> [api-v9.md](api-v9.md) and [api-v10.md](api-v10.md); everything there still
> applies.

API 11 lets a plugin use files in the worktrees of a remote project, on the
SSH host the project runs on. The plugin's JavaScript still runs on this Mac;
only the file work moves to the host.

## The `remote` field

```json
{ "api": 11, "capabilities": ["files.read", "files.write"], "remote": true }
```

`remote` (bool, default `false`) says the plugin's `file/*` calls make sense
on an SSH host. Without it, a remote worktree keeps API 10's refusal.

- It needs `"api": 11`; below that the manifest is refused.
- It needs `files.read`, `files.write` or `process.exec`; without any of them
  it would mean nothing, so the manifest is refused.
- It is part of the manifest's bytes, so the approval covers it: adding it in
  an update asks for approval again. One approval covers every SSH host the
  plugin's projects use.

The approval sheet shows it on its own *On SSH hosts* line, outside *Full
access*, saying what the plugin does there: it reads files, changes files or
runs commands on that host, as your user there. A plugin that only reads is
not labelled full access. When full access is also requested, the
confirmation reads "…in my worktrees, on this Mac and on SSH hosts".

## Remote `file/*`

`file/read`, `file/list` and `file/write` work on a worktree of a remote
project with the same messages, limits and error codes as API 6. The
differences:

- The path is resolved and checked on the host by the Alas helper, in the same
  call as the read, list or write. The helper walks the path one component at
  a time from the folders it already opened, never letting the system follow a
  symlink for it, so a symlink swapped in during the call cannot lead outside
  the worktree. A symlink that stays inside the worktree is followed as on
  this Mac; one that leads out is refused, and so is anything named `.git` in
  any case.
- The Alas helper must be installed on the host. Without it, the request
  answers `-32003`:

  ```
  the Alas helper is not installed on remote host devbox; plugins need it to use files there
  ```

  An older helper that predates API 11 answers that it is out of date.
- A host that can't be reached answers `-32003 "remote host devbox is
  unreachable"`. The plugin keeps running.
- Answers come in a later delivery, as for local files, and count towards
  the 4 requests in flight.

`process/*` on a remote worktree still answers API 10's refusal.
