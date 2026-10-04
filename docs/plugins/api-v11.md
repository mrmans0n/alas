# Plugin API v11

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 10 in [api-v5.md](api-v5.md),
> [api-v6.md](api-v6.md), [api-v7.md](api-v7.md), [api-v8.md](api-v8.md),
> [api-v9.md](api-v9.md) and [api-v10.md](api-v10.md); everything there still
> applies.

API 11 lets a plugin use files and run its declared commands in the worktrees
of a remote project, on the SSH host the project runs on. The plugin's
JavaScript still runs on this Mac; only the file work and the commands move to
the host.

## The `remote` field

```json
{ "api": 11, "capabilities": ["files.read", "files.write"], "remote": true }
```

`remote` (bool, default `false`) says the plugin's `file/*` and `process/run`
calls make sense on an SSH host. Without it, a remote worktree keeps API 10's refusal.

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

## Remote `process/run`

`process/run` works on a worktree of a remote project with the same message,
limits and reply as API 6: `{exit, stdout, stderr, truncated, timedOut}`, in a
later delivery. The differences:

- The command runs on the host, as your user there, in the worktree. The argv
  is exactly the manifest's plus `args`, passed as separate strings to the
  Alas helper, which starts the program without a shell: spaces, quotes and
  `$` in `args` reach it unchanged.
- The executable is resolved on the host: an absolute path as it is, a path
  with a slash relative to the worktree, and a bare name on the `PATH` of your
  login shell there. The environment is your login shell's on the host,
  captured once per connection; nothing from this Mac's environment is passed.
  A command the host can't find answers `-32003 "could not start install:
  command not found: pnpm"`.
- `stdin` is written, then closed, so the command sees its end; without
  `stdin` the command reads from `/dev/null`.
- Stopping works as on this Mac: after 10 minutes, or when the plugin stops,
  the process and everything it started get `SIGTERM`, then `SIGKILL` 5
  seconds later; whatever it leaves running when it exits on its own gets
  `SIGTERM`, then `SIGKILL` a second later. On the host the helper does it,
  and it keeps track of every process the command starts, including ones that
  detach into their own session, so none is left behind. If Alas loses the
  connection or quits, the helper still stops the run: Alas renews a lease on
  it while it runs, and the helper also enforces the 10 minutes, plus the
  grace, itself.
- It counts towards the 2 processes and the 4 requests in flight, like a local
  run.
- The host must be Linux 5.3 or later, with the Alas helper installed. These
  answer `-32003` with the reason, after `could not start <id>: `:

  ```
  the Alas helper is not installed on remote host devbox; plugins need it to run commands there
  plugin commands can't run on macOS SSH hosts: macOS can't guarantee that everything a command starts is stopped
  this host's Linux kernel lacks pidfd_open and pidfd_send_signal (Linux 5.3 or later is required to stop everything a command starts)
  remote host devbox is unreachable
  ```

  Remote `file/*` works on macOS hosts.

`process/start` on a remote worktree answers `-32003 "process/start can't run
on remote hosts yet; process/run can"`.
