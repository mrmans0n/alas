# Plugin API v6

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and API 5's commands, events, settings, web requests,
> timers and panels in [api-v5.md](api-v5.md); everything there still applies.

API 6 puts plugins next to the work: commands in the Changes, Run and agent
session menus, badges on rows, panels inside the Changes tab and run reports,
events for git, worktrees, focus, runs and pull requests, and requests that
send to agent sessions, start runs, read their output and add review comments.
For plugins that need more, it adds two high-trust capabilities: running the
commands a plugin declares, and reading and writing files in the project's
worktrees. See [Processes and files](#processes-and-files).

## The `api` field

Alas loads plugins with `"api": 4`, `5` or `6`. Everything below needs
`"api": 6`:

- The capabilities `session.write`, `runs.read`, `runs.start`, `review.read`,
  `review.write`, `process.exec`, `files.read` and `files.write`, the
  `processes` field, and the events of [Events](#events). An older manifest
  that asks for them is refused.
- The new command slots and panel locations. An older manifest that names them
  has them skipped, not refused, as an older Alas would.
- `decorations/set` and the [requests](#requests). From an older plugin,
  `decorations/set` is ignored and the requests answer `-32601`.

`alas/activate` carries the manifest's `api`.

## Command slots

API 6 adds these slots to the five of [API 5](api-v5.md#commands). Each
command's `target` names what the user acted on:

| Slot | Where | Target |
|---|---|---|
| `changes.toolbar` | A puzzle-piece menu in the right pane's header on the Changes tab | `{"kind": "worktree", "worktree"}` |
| `changes.file.menu` | A changed file's context menu in the Changes tab | `{"kind": "file", "worktree", "path"}` |
| `changes.commit.menu` | A commit's context menu in the Changes tab | `{"kind": "commit", "worktree", "sha"}` |
| `run.menu` | A run script's "…" menu in the Run tab | `{"kind": "run", "worktree", "script"}` |
| `run.report` | A puzzle-piece menu in a run report's header | `{"kind": "runReport", "worktree", "run"}` |
| `session.menu` | An agent session tab's context menu, and a puzzle-piece menu in its toolbar | `{"kind": "session", "session"}` |

`path` is relative to the worktree. `script` is the run script's key, such as
`repo:dev.sh` or `global:test.sh`. `run` is the run id that `run.*` events and
`run/output` use. `session` is the session id of `workspace/snapshot`.

```json
{ "jsonrpc": "2.0", "method": "command/run",
  "params": { "command": "explain", "target": { "kind": "runReport", "worktree": "wt-3", "run": "4F2…" } } }
```

## Decorations

A plugin puts short badges on rows with the notification `decorations/set`. It
needs no capability.

```json
{ "jsonrpc": "2.0", "method": "decorations/set",
  "params": { "slot": "worktree.row", "target": "wt-3",
              "items": [{ "text": "CI ✗", "tone": "danger", "tooltip": "2 checks failed", "command": "fix-ci" }] } }
```

| Slot | Where | `target` | `worktree` |
|---|---|---|---|
| `repo.row` | The project's header in the sidebar | the project id (`alas/activate`'s `project.id`) | omitted |
| `worktree.row` | A worktree row in the sidebar, after its stack summary | the worktree id | omitted |
| `run.row` | A run script's row in the Run tab, after its name | the run script key | required |
| `changes.file` | A changed file's row in the Changes tab, after its name | the path, relative to the worktree | required |

Each item has `text`, and optionally `tone`, `tooltip` and `command`:

- At most 2 items per plugin per row; the rest are dropped. `text` is cut to 24
  Unicode scalars, `tooltip` to 200, and an item with empty text is skipped.
- `tone` is one of the view tree's: `normal`, `dim`, `accent`, `warn`,
  `danger`. Without it the badge is dim.
- An item with `command`, which must be one of the manifest's commands, is a
  button. Clicking it sends `command/run` with the target the row's own menu
  would send: `project` for `repo.row`, `worktree`, `run` or `file`.

Each `decorations/set` replaces the plugin's items for that slot and row;
`"items": []` clears them. A plugin decorates at most 256 rows per project.
Alas drops all of a plugin's decorations when it stops, fails, restarts or is
disabled, so set them again on activation.

A row outside the plugin's project and an unknown slot are ignored with a
warning in the plugin's log, since a worktree may have just been removed. An
unknown tone, an undeclared command, or a `worktree` given to the wrong slot
stops the plugin, as any malformed message does.

## Panels in the Changes tab and run reports

[Panels](api-v5.md#panels) take two more `location`s. Up to 4 panels at
`"api": 6`.

| Location | Where | Rendered for |
|---|---|---|
| `changes.section` | A section of the Changes tab, after the commit and review card | a worktree |
| `run.report.section` | Under a run report's header | a run |

The section shows the panel's `title` over its tree. It is hidden until the
plugin renders a tree for the worktree or run being shown, and while that tree
is empty: a `vstack`, `hstack` or `scroll` holding nothing else.

`view/render` for one of these panels names its worktree or run, and the other
messages carry it too:

```json
{ "jsonrpc": "2.0", "method": "view/render",
  "params": { "panel": "checks", "worktree": "wt-3", "root": { "id": "root", "kind": "vstack", "children": [] } } }
{ "jsonrpc": "2.0", "method": "panel/visible", "params": { "panel": "explain", "run": "4F2…", "visible": true } }
{ "jsonrpc": "2.0", "method": "view/event",
  "params": { "panel": "checks", "worktree": "wt-3", "id": "rerun", "kind": "click" } }
```

A panel keeps one tree, for the worktree or run it was last rendered for. When
the user moves to another worktree or run, `panel/visible` says so, and the
section stays hidden until the plugin renders for it. `panel/visible` is
counted per worktree or run, so showing a second run report sends
`visible: true` for it while the first is still open. A `view/render` with the
wrong context for its location (no `worktree` for `changes.section`, a `run`
for `right`) stops the plugin.

## Events

```json
{ "api": 6, "capabilities": ["workspace.read", "runs.read"], "events": ["git.changed", "run.finished"] }
```

| Event | Capability | Notification | Sent when |
|---|---|---|---|
| `worktree.created` | `workspace.read` | `worktree/created {worktree}` | A worktree joins the project. |
| `worktree.removed` | `workspace.read` | `worktree/removed {worktree}` | A worktree leaves the project. |
| `git.changed` | `workspace.read` | `git/changed {worktree}` | A worktree's dirty file or conflict count changes. |
| `focus.changed` | `workspace.read` | `focus/changed {worktree}` | The user selects a worktree of the project. |
| `run.started` | `runs.read` | `run/started {worktree, script, run}` | A run script starts. |
| `run.finished` | `runs.read` | `run/finished {worktree, script, run, outcome, exitCode?}` | It finishes. |
| `review.changed` | `review.read` | `review/changed {worktree, state, number?, checks?}` | A worktree's pull request, its state or its checks change. |

Like the session events of API 5, these come from comparing the project every
half second, so each worktree's `git.changed` fires at most that often and a
change that is undone within it is not seen. The first comparison after the
plugin starts is the baseline and sends nothing. `git.changed` follows the
counts in `workspace/snapshot`'s `dirty`: editing a file that is already
modified does not change them.

`outcome` is `succeeded`, `failed`, `stopped` or `unknown` (Alas lost sight of
the command). `exitCode` is 0 for `succeeded`, the command's code for `failed`,
and omitted otherwise. A run that starts and finishes between two comparisons
sends both events.

`review.changed`'s `state` is `open`, `closed`, `merged`, or `none` when the
branch has no pull request. `checks` is `{passed, failed, pending}`; cancelled
checks count as failed. Pull request state is read by the Changes tab's review
loop, so only worktrees whose Changes tab has loaded report it.

## Requests

| Request | Capability | Result |
|---|---|---|
| `session/send {session, text}` | `session.write` | `{}` |
| `run/start {worktree, script}` | `runs.start` | `{}`, in a later delivery |
| `run/output {run}` | `runs.read` | `{output, truncated}`, in a later delivery |
| `review/comment {worktree, path, line, body}` | `review.write` | `{}`, in a later delivery |

Without the capability each answers `-32001`. Params that break the rules below
answer `-32602`, and something that does not exist in the project answers
`-32003`. At most 4 of the requests answered later are in flight per instance;
more answer `-32003`. A plugin that stops before its answer arrives never gets
it, but what it asked for still happens: a run it started keeps running.

- `session/send` queues `text`, 1 byte to 32 KiB and not only whitespace, as a
  prompt for an agent session of the project, as if the user typed it. Only
  live agent chat sessions take prompts; terminal sessions answer `-32003`.
- `run/start` starts the run script whose key is `script` in a worktree of the
  project, as the Run tab's start button does: in a terminal tab of that
  worktree. A script that is already running answers `-32003` instead of
  restarting it. Listen for `run.started` to learn its run id.
- `run/output` answers with the last 64 KiB of a finished run's output, cut on
  a character boundary, and `truncated: true` when it was cut. `output` is
  `null` when Alas did not keep it. A run still going answers `-32003`.
- `review/comment` adds a draft review comment on `line` (from 1) of `path`,
  relative to the worktree and not leaving it, with `body` of 1 byte to 16 KiB
  of Markdown. It goes to the worktree's review of local changes, where the
  user sees it like an agent's comment, with the plugin's name as its author.

## Capabilities

| Capability | Approval sheet says |
|---|---|
| `session.write` | Send messages to agent sessions in this project |
| `runs.read` | Read when run scripts start and finish in this project, and their output |
| `runs.start` | Start run scripts in this project |
| `review.read` | Read the pull request state and checks of this project's worktrees |
| `review.write` | Add review comments to changes in this project |
| `process.exec` | Run the commands listed below in this project's worktrees (full access) |
| `files.read` | Read files in this project's worktrees |
| `files.write` | Create and change files in this project's worktrees (full access) |

## Processes and files

**These run with your permissions, outside the sandbox.** A command a plugin
runs can do anything you can do from a terminal, and a file it writes is
written as you. Everything else about the plugin stays sandboxed, and a call
without the grant answers `-32001` whatever the plugin's code does.

The approval sheet groups capabilities into *Sandboxed* and *Full access*
(`process.exec` and `files.write`), lists every declared command, and enables
Approve only once the user ticks "I understand this plugin can run these
commands and change files in my worktrees". The catalog marks plugins that ask
for full access. The approval covers the manifest's exact bytes, so a plugin
that adds or changes a command in an update is approved again.

### `process.exec`

The manifest lists every command the plugin may run, as an exact argv prefix:

```json
"capabilities": ["process.exec"],
"processes": [
  { "id": "install", "command": ["pnpm", "install"] },
  { "id": "op", "command": ["op", "read"], "appendArgs": true },
  { "id": "dev", "command": ["pnpm", "dev"], "longRunning": true }
]
```

At most 16 entries. `id` follows the command id rules, `command` is not empty
and each of its arguments is at most 1 KiB. `processes` without `process.exec`,
or `process.exec` without `processes`, is refused.

| Request | Result |
|---|---|
| `process/run {id, worktree, args?, stdin?}` | `{exit, stdout, stderr, truncated, timedOut}`, in a later delivery |
| `process/start {id, worktree, args?}` | `{run}` |
| `process/stop {run}` | `{}` |

- The process runs in `worktree`, a local worktree of the project; any other
  id, or a worktree on a remote host, answers `-32003`.
- `args` are appended only when the entry has `appendArgs`, at most 32 of up to
  1 KiB each; otherwise the argv is exactly the manifest's and `args` answers
  `-32602`. `process/run` takes entries without `longRunning`, `process/start`
  entries with it.
- Alas resolves the executable: an absolute path as it is, a path with a slash
  (`./bin/x`) relative to the worktree, and a bare name on the `PATH` of your
  login shell. A command it cannot find answers `-32003`.
- The environment is Alas's own, with your login shell's `PATH`, so a command
  sees what your other tools see, as it can read your files. A plugin cannot
  set variables: ones like `PATH` or `NODE_OPTIONS` would change what the
  approved command runs. The plugin's own secrets are never passed to
  processes; commands that need credentials use their own login
  (`op signin`, `gh auth login`).
- `stdin`, up to 256 KiB of text, is written to `process/run`'s input, which is
  then closed. Long-running processes get no input.
- `process/run` keeps the first 512 KiB of output, stdout and stderr together,
  and cuts it further when the escaped answer would not fit in a message, so
  the answer always carries the exit status; `truncated` is `true` when
  output was dropped. Output is decoded as UTF-8, invalid bytes replaced. After 10 minutes
  Alas stops the process, kills it 5 seconds later if it is still there, and
  answers with `timedOut: true`. `exit` is the exit code, or 128 plus the
  signal number when a signal ended it.
- An instance has at most 2 processes running, of both kinds; more answer
  `-32003`. `process/run` also counts towards the 4 requests answered later.
- A long-running process shows in the Run tab of its worktree, under
  *Plugins*, named after the plugin and the process id, with its latest output
  and a Stop button. When it exits the plugin gets
  `process/exited {run, exit}`. `process/stop` stops one by its `run`.
- When the plugin stops, is disabled or fails, Alas stops all its processes,
  and nothing it started answers the next instance. Stopping sends `SIGTERM` to
  the process and every process it started, then `SIGKILL` after 5 seconds.
  When a process exits on its own, whatever it left running gets `SIGTERM`, then
  `SIGKILL` a second later: a declared command cannot leave a daemon behind.

### `files.read` and `files.write`

| Request | Capability | Result |
|---|---|---|
| `file/read {worktree, path}` | `files.read` | `{content}` |
| `file/list {worktree, dir}` | `files.read` | `{entries: [{name, kind}], truncated}` |
| `file/write {worktree, path, content}` | `files.write` | `{}` |

- Paths are relative to a local worktree of the project; `dir` may be `""` for
  the worktree itself. Alas refuses absolute paths, `..`, and anything that
  resolves outside the worktree, through symlinks too, including symlinks that
  lead nowhere.
- Nothing named `.git`, compared case-insensitively, can be read, listed or
  written at any depth, checked on the resolved path: in a linked worktree
  `.git` points git at the repository, so `.GIT/config` and a symlink into
  `.git` are refused too. `file/list` leaves `.git` out.
- `file/read` answers with UTF-8 text of up to 512 KiB; a larger file, one that
  is not UTF-8, or a reply that does not fit in a message answers `-32003`.
- `file/list` answers with up to 2000 entries sorted by name, fewer when their
  names would not fit in one reply, with `kind` `file`, `directory` or
  `symlink`, and `truncated: true` when there were more.
- `file/write` writes `content`, up to 512 KiB and within the message limit,
  replacing the file and creating missing folders inside the worktree. Writes
  show up in the Changes tab like any other edit.
- Refusals answer `-32003` with the reason.
