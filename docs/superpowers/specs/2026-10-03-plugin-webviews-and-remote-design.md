# Plugin webview panels and remote execution

Closes the two open design items of phase 5 in
[#1560](https://github.com/mrmans0n/alas/issues/1560):

- custom webview panels with a restricted bridge, "if native contributions
  cannot support a real use case";
- local versus remote execution and capability ownership, "before exposing
  remote workspace operations".

Builds on API 8 and the API 9 work in progress (configure screens,
plugin-scoped storage, runtime prompts, tab visibility). The runtime,
JSON-RPC contract, approval and trust hash are unchanged unless stated here.
New behavior ships as API 10 and later. Each API number ships whole: an Alas that advertises it implements all of it, because the catalog filters on the number alone and manifests ignore unknown fields.

## Decisions in brief

- **Remote comes first (API 10 says where a project runs; API 11 runs files and commands there).** It fixes a gap the full-access archetypes
  hit at once: a worktree-setup plugin is refused on every worktree of an SSH
  project.
- **Plugin JavaScript always runs on this Mac.** Only `process.*` and
  `file/*` move to the remote host, through the SSH plumbing Alas already
  uses. Everything else already goes through host-aware app services.
- **Remote full access is opt-in twice.** The manifest declares
  `"remote": true`, and the approval sheet says that commands run on the SSH
  host.
- **Webviews are designed but not built (API 12)** until a plugin in the
  catalog needs one. Today every catalog plugin is covered by view trees and
  canvases.
- **When webviews ship:** a `web` tab kind; one extra hashed file (`ui.js`)
  loaded into a page shell Alas owns; no network; a non-persistent data store;
  and a bridge that only carries messages between the page and its own plugin.

---

## Part A: remote execution and capability ownership

### Problem

A project is remote when `ProjectConfig.host` is set (an SSH alias). Its
worktrees carry virtual paths (`/.alas-remote/<host><path>`, see
`RemotePath`). One plugin instance serves one project, so an instance is
either entirely local or entirely remote.

Today:

| Plugin call | Remote project | Why |
|---|---|---|
| `workspace/snapshot`, events, `session/*`, `task/start` | works | app services, host-aware git |
| `run/start`, `run/output` | works | `RunScriptStore.discoverScripts(worktreeRoot:remoteHost:)`, `runRecords` |
| `review/comment` | works | `reviewCommentAdd` |
| `http/fetch`, timers, storage, settings | works | runs on the Mac; unrelated to the worktree |
| `process/run`, `process/start`, `file/*` | **refused**, `-32003 "unknown worktree"` | `worktreePath` in `AppState+Plugins.swift` returns nil for remote worktrees |

Two problems follow:

1. **A plugin can't tell.** The snapshot has no remote flag, and the refusal
   says "unknown worktree" for a worktree the snapshot just listed.
2. **Full-access plugins are local-only.** Archetypes 13 and 14 in the API
   expansion spec (worktree setup, dev servers) are exactly what people run on
   a remote devbox: copy `.env`, `pnpm install`, start `pnpm dev`.

### Use cases

| Plugin | Needs on a remote project |
|---|---|
| Worktree setup | `file/read`/`file/write` (copy `.env.example` → `.env`), `process/run pnpm install` |
| Dev server manager | `process/start pnpm dev`, a badge, an "Open preview" command |
| Lockfile / dependency checks | `file/read package.json`, `process/run npm outdated --json` |
| Linear bridge, PR inbox, Prompt Library, Notion context | nothing new: they use network and app services |

### Options

| | Option | Trade-offs |
|---|---|---|
| 1 | **Keep refusing; just say why.** Expose `project.host`, refuse with "remote host". | No new risk, tiny. Full-access plugins stay useless on remote projects. |
| 2 | **Run plugin JS on the remote host** (ship a JS engine with the remote helper). | Exact locality, but a second runtime with no JSC watchdog on Linux, a second approval story, and UI round trips over SSH. Rejected. |
| 3 | **JS stays local; `process.*`/`file/*` execute on the host** through `RemoteHelperClient`, `RemoteExec`, `RemoteFileAccess` and `RemotePathContainment`. | Reuses tested plumbing and keeps one runtime. Commands run as the remote user, so the approval must say so. Remote checks take round trips, so file replies get slower. |

**Recommendation: option 3, shipped after option 1 as its first slice.**

### Which capabilities run where

| Capability | Runs | On a remote project |
|---|---|---|
| Plugin JS, `alas.send`, view trees, canvases, timers, storage, settings, secrets | Mac | unchanged |
| `network` (`http/fetch`) | Mac | unchanged. The plugin can't reach the remote host's `localhost`, as with web previews. |
| `workspace.read`, `session.*`, `tasks.start`, `runs.*`, `review.*` | Mac, through app services | unchanged: these already reach the host |
| `files.read`, `files.write` | **remote host** | same rules, enforced on the host |
| `process.exec` | **remote host** | same argv rules; runs as the SSH user |

Secrets never leave the Mac. They are substituted only into `http/fetch`
headers, which run locally, and processes never receive them, local or remote.

### How a plugin learns where it runs

`alas/activate` gains `project.host`, present only for a remote project:

```json
{ "project": { "id": "9F1C…", "name": "api", "host": "devbox" }, "api": 10, "grants": […] }
```

- Remoteness is per project, so activation is the one place to carry it. The
  snapshot needs no new field.
- A refusal for a remote worktree says so: `-32003 "worktree is on remote host
  devbox and this plugin does not support remote projects"`.

### Opting in: the manifest and the approval sheet

```json
{ "api": 11, "capabilities": ["process.exec", "files.read", "files.write"],
  "remote": true, "processes": [ … ] }
```

- `remote` (bool, default `false`) says the plugin's `process.*` and `file/*`
  calls make sense on an SSH host. Without it, remote projects keep today's
  refusal with the clearer message. `remote` without `process.exec` or
  `files.*` is refused, because it would mean nothing.
- It is part of the manifest bytes, so the trust hash covers it. Adding it in
  an update asks for approval again.
- When `remote` is set, the approval sheet shows its own *On SSH hosts* line,
  outside the *Full access* group, worded for what is requested: "reads files"
  for `files.read`, "changes files" for `files.write`, "runs these commands"
  for `process.exec`, each "on that host, as your user there". A read-only
  plugin is not labelled full access. When full access is also requested, its
  confirmation checkbox text gains "…on this Mac and on SSH hosts".
- The grant stays per plugin (see Decisions).

### Remote `file/*`

Same messages, limits and error codes as API 6. Differences:

- Paths are resolved against the worktree's real remote path
  (`RemotePath.realPath`). The `..`, symlink, and case-folded `.git` checks
  run **on the host**, in the same command or helper call as the operation, so
  a symlink swapped between check and act can't escape. Reuse
  `RemotePathContainment`'s probe, which already excludes `.git`, and the
  guarded replace/mkdir commands in `RemoteFileOps`, rather than writing a
  second checker.
- The helper's existing `fs/read` and `fs/list` are not enough: they take
  only a path, authorize it against the union of every watched root, and do
  not exclude `.git`. A plugin could read `.git` or reach another subscribed
  worktree through them. R2 adds helper operations that take the worktree
  root with the path and enforce containment and the case-folded `.git`
  exclusion in the same call, walking components from a directory descriptor
  with `O_NOFOLLOW` so a swapped symlink can't escape. A symlink met on the way
  is resolved by the helper against the descriptors it holds and followed only
  if it stays inside the worktree, so API 6's contained symlinks keep working
  remotely. A separate `RemotePathContainment` probe before the call would
  bring the race back.
- Remote `file/*` requires the helper, like remote `process.*`. A shell
  script can put the check and the operation in one command but not make them
  atomic: another process can swap a component for a symlink in between, as
  `RemotePathContainment.containedReadScript` already notes. Without the
  helper, file requests answer `-32003` with the reason.
- Replies already arrive in a later delivery. Remote ones also count towards
  the 4 requests in flight, because each one holds an SSH round trip.
- A connection failure answers `-32003 "remote host devbox is unreachable"`.
  It does not stop the plugin.

### Remote `process.*`

- `process/run` and `process/start` require the remote helper and use
  `spawnProc`/`attachProc`/`killProc`. Without the helper they answer `-32003`
  with the reason. One-shot `RemoteExec` can't reliably kill a process tree
  when the plugin stops, and "no daemons left behind" is an API 6 guarantee.
- Helper process ids are opaque and owned: Alas derives each from the plugin,
  the project, the instance's lease and the run, so two instances on one host
  never share one, and the public `pN` run id maps to it only inside the
  instance that started it. A helper call for an id owned by another lease is
  refused rather than attached to.
- The argv is the manifest's exact prefix plus `appendArgs`, sent to the
  helper as a raw JSON array (`spawnProc` already carries `command` and `args`
  as separate strings) and quoted exactly once, inside the helper. Alas does
  not pre-quote it, which would pass literal quotes to the program. The
  working directory is the worktree's real path.
- The executable resolves on the host: absolute paths as is, `./x` relative to
  the worktree, bare names on the remote login shell's `PATH`. Today the
  helper starts through `SSHCommand.remoteScript`, whose prelude adds a fixed
  set of directories and never runs a login shell, so tools that `.profile`,
  nvm, mise or asdf add (`pnpm`) would be missing. R3 captures the login
  environment once per connection by running the user's shell with `-l -c`
  around `env -0` between two sentinels, as `ShellEnvResolver` does locally,
  so banners from startup files and values holding newlines can't corrupt
  it; plugin processes are spawned with it. The environment is the remote
  user's; nothing from the Mac's environment is forwarded.
- The 10-minute limit, `stdin` and the 2-per-instance cap are unchanged. On
  stop, the helper sends `SIGTERM` to the process group, then `SIGKILL` after
  5 s.
- The helper needs two changes for API 6's "no daemons left behind" to hold
  remotely. Today its supervisor only records the root's exit, and
  `killProc` skips signalling once the recorded leader is dead and then
  deletes the process directory, so a backgrounded child survives forever.
  R3 makes the supervisor terminate the group when the root exits on its own
  (`SIGTERM`, then `SIGKILL` after the grace), and makes `killProc` signal the
  recorded process group even when the leader is gone. The group id can't be
  reused while any member is alive, but it can once all have exited, so the
  group is signalled only if at least one tracked process still matches its
  recorded start time and is still in the recorded group; otherwise the group
  signal is skipped. A check followed by `kill(-pgid)` still has a window, so
  the supervisor starts the run under an anchor: a tiny process of its own
  that leads the group, ignores `SIGTERM`, and stays alive until cleanup has
  signalled the group and the kill grace has passed; the supervisor removes
  it last. While it lives the group id can't be reused,
  and the check becomes a safeguard rather than the guarantee. Descendants that left the group are signalled one by
  one.
- Leaving the group doesn't escape cleanup. A child that calls `setsid` or
  daemonizes is out of the recorded group, so R3 adds descendant tracking to
  the helper as the local launcher does: sample the tree while the root runs,
  keep each descendant's pid with its start time, and on stop or root exit
  signal those still matching. On Linux the helper opens a pidfd for each
  descendant when it validates it and signals through `pidfd_send_signal`, so
  a pid reused between the check and the signal is never hit. Sampling alone
  misses a child that double-forks and is orphaned before the first sample.
  On Linux the supervisor makes itself a child subreaper
  (`PR_SET_CHILD_SUBREAPER`), so orphans reparent to it and stay findable.
  Cleanup doesn't stop at one pass: the supervisor keeps enumerating its
  adopted children while it signals, and repeats `SIGTERM` passes, then
  `SIGKILL` passes after the grace, until nothing it owns is left, so a
  descendant that forks again while handling `SIGTERM` is caught too;
  cgroups are not required. The helper probes `pidfd_open` and
  `pidfd_send_signal` (Linux 5.3 and later) before accepting remote
  `process.*`, and refuses older kernels with the reason rather than falling
  back to numeric pids. macOS has no subreaper, so remote `process.*` is
  refused on macOS SSH hosts until a race-free mechanism exists; remote
  `file/*` still works there.
- Processes see EOF. Today `proc/write` only appends to `stdin.log` and
  the child's stdin stays open until it exits, so `cat` or a formatter waits
  for the 10-minute limit. R3 adds a spawn mode that writes the `stdin`
  payload and closes the pipe, and gives runs without `stdin`, and every
  `process/start`, `/dev/null`, as the local launcher does.
- Output is a raw byte stream. `attachProc` was built for newline-framed ACP
  traffic: it strips newlines and drops a final unterminated fragment, so
  `printf result` would come back empty. R3 adds a raw attach mode that
  delivers stdout and stderr bytes exactly as written.
- Output is bounded on the host too. The helper's `stdout.log` and
  `stderr.log` grow without limit today, so a verbose dev server fills the
  remote disk and replays it all on attach. R3 caps each log on the helper
  side, keeping the head for `process/run` and the tail for long-running
  processes, the same limits the plugin host applies. Offsets become logical:
  monotonic byte counts with a retained base that the helper reports, so a
  client whose remembered offset fell below the base resumes at it instead of
  seeking past the end of a shortened file. For plugin processes, stdout and
  stderr go to one journal of tagged chunks with a sequence number rather
  than two files, so a replay after a reconnect keeps their original order,
  as the local Run tab shows it.
- Exit codes match local runs: a process ended by a signal reports 128 plus
  the signal number (143, 137), taken from the exit status's signal, not the
  helper's current `code().unwrap_or(2)`.
- The helper retires what nobody owns. If the SSH connection is gone when a
  plugin stops, or Alas crashes, no `killProc` arrives. One-shot runs carry a
  helper-enforced deadline (the 10-minute limit plus the kill grace), and
  long-running ones a lease the plugin instance renews while it runs; when a
  lease lapses, the helper stops the process and its descendants as on
  `killProc`.
- Long-running processes appear in the remote worktree's Run tab under
  *Plugins*, exactly like local ones, and stop when the plugin stops.

### What stays out

- A plugin git API. `process/run git …` with a declared argv covers it, local
  and remote. Add one only if a plugin needs something the app's status
  scanner already computes.
- Paired peers (`Alas/Sources/Remote/`: the gateway, federation, paired
  devices). That is Alas serving other Alas instances, not SSH workspaces.
  Plugins don't run for peer sessions.
- Remote `localhost` from `http/fetch`. Use a declared `process/run curl …` if
  it is ever needed.

---

## Part B: webview panels

### Problem and use cases

Native view trees (API 3, 8) and canvases (API 2) render everything the
catalog ships today: Kanban, Pixel Office, Linear bridge, PR inbox, Prompt
Library and Notion context. The honest list of gaps:

| Use case | Native today? | Cheapest fix |
|---|---|---|
| Rendered Markdown (issue bodies, PR descriptions in the Linear bridge or PR inbox) | no, plain `text` only | a native `markdown` node: Alas already renders Markdown in transcripts |
| Charts: cost/usage over time (archetype 7), CI duration trends | no; a canvas draws pixels with no text, hover or accessibility | a webview, or a native `chart` node (Swift Charts) |
| Graphs: branch/stack lanes, dependency graphs, Mermaid | no | a webview |
| Drag and drop (Kanban columns) | no; Kanban uses menus | a native `reorder` event on lists |
| Rich editors (JSON schema forms, query builders) | partly; API 9 configure screens cover settings | a webview |
| Embedding a third-party dashboard (Grafana, Sentry, Vercel) | — | **not a webview case.** It needs the network and cookies; use `link` or the web preview tab. |

Only free-form visualization (charts, graphs, diagrams) truly needs a webview.
No catalog plugin needs it yet. The usage/cost tracker would be the first one,
once `session.usage` events exist.

### Prior art

| Tool | Model | Takeaway |
|---|---|---|
| VS Code | Webviews in iframes with their own origin. The extension and the page talk only through `postMessage`. `localResourceRoots` limits files; CSP is recommended but not enforced. `retainContextWhenHidden` is discouraged for memory. | Same bridge shape, but Alas **enforces** the CSP and the file set. |
| Zed | No webviews. GPUI only; extensions add languages, themes, slash commands, MCP. | Native-first is a valid end state. |
| Raycast | Native components only (a React reconciler), no webviews. | A rich native vocabulary covers a lot. |
| Obsidian | Plugins run unsandboxed in the Electron renderer, with DOM and Node. | The failure mode to avoid: the page is never the plugin's privileged half. |

### Options

| | Option | Trade-offs |
|---|---|---|
| A | **Native only.** Add `markdown`, `chart` and `reorder` as plugins ask for them. | Accessible, themed and safe, but each visual need grows the contract, and graphs or diagrams never fit. |
| B | **Page as a view.** The plugin's JS stays in JSC; a WKWebView renders a page shipped in the bundle and talks only to its own plugin. | Covers any visualization. It is a second UI stack to secure, and accessibility becomes the author's job. Each page costs a WebContent process (roughly tens of MB). |
| C | **Plugin runs in the webview** (drop JSC for web plugins). | Loses the CPU watchdog and the empty global. The page would hold capabilities. Rejected. |
| D | **Load remote URLs.** | That is the web preview. It would bypass the network allowlist. Rejected. |

**Recommendation: A now, B when a plugin needs it.** Ship a `markdown` node
when the Linear bridge or PR inbox asks for it; it is small and covers the most
common gap. Approve B's design below so it is ready, but build it only with a
reference plugin committed (likely a usage dashboard or a stack graph).

### Design (option B)

**The bundle.** One optional extra file, a classic script like `plugin.js`:

```json
{ "api": 12, "entry": "plugin.js", "web": "ui.js",
  "contributes": { "tabs": [{ "id": "usage", "title": "Usage", "kind": "web" }] } }
```

- `web` names a file inside the folder, with the same rules as `entry`: no
  `..`, not a symlink, UTF-8, at most 8 MiB. A `kind: "web"` tab without
  `web`, or `web` with no web tab, is refused.
- The plugin doesn't ship HTML. Alas serves a fixed shell: the CSP, theme
  variables, then `<script src="ui.js">`. Authors bundle React, Svelte,
  Chart.js or D3 into one IIFE with esbuild, the same toolchain as
  `plugin.js`. Images and fonts are inlined as `data:` URLs.
- The trust hash covers `ui.js`, so changing the page asks for approval again.
  Today's hash separates manifest and entry with one NUL, which is safe only
  because the JSON manifest can't hold a raw NUL; two JavaScript files can, so
  bytes could move across their boundary without changing the digest. The
  hash gets a new version that frames each field with its name and length
  (`alas-plugin-trust-v2`), used only for releases that ship `ui.js`. Releases
  without one keep v1, so existing catalog records and approvals stay valid in
  older and newer Alas alike; a record says which version it carries. The catalog publishes `ui.js` as a third asset and
  verifies it like the other two. The repository spec's "two files" rule
  becomes "two or three".

**Loading.**

- The page loads from `alas-plugin://<plugin-id>/` through a
  `WKURLSchemeHandler` that serves exactly two resources, the shell and
  `ui.js`. Everything else is a 404.
- Each tab gets its own `WKWebViewConfiguration` with
  `websiteDataStore = .nonPersistent()`, like `WebPreviewBrowser`. The page
  shares no cookies, storage or cache with Alas, web previews or other plugins,
  and loses them when the tab closes. Persistent state goes through the plugin
  (`storage/set`).
- The page lives while its tab is open, hidden or not. It reloads after a
  WebContent crash (`webViewWebContentProcessDidTerminate`) and shows the
  standard unavailable placeholder when the plugin stops, fails or is
  disabled. Tab restoration recreates it.

### Security model

**Threats, in order:**

1. A malicious plugin uses its page to bypass the `network` allowlist.
2. Untrusted data rendered in the page (an issue body) injects script.
3. The page reaches Alas: its state, cookies, files or other plugins.

**Process isolation.** WebKit runs page content in a WebContent process,
outside Alas. A crash there kills only the page, and a page spinning in
`for (;;) {}` blocks only that process, never Alas's main thread. Alas doesn't
rely on one process per plugin, because WebKit may share WebContent processes.
The plugin's own JS keeps the JSC watchdog.

**No network, enforced three ways**, because the network allowlist means
nothing if the page can talk to any host:

- CSP, sent by the scheme handler as a response header, which the page can't
  remove:
  `default-src 'none'; script-src alas-plugin://<id>/ui.js; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'`.
  No `unsafe-inline` or `unsafe-eval` for scripts, so injected `<script>` tags
  and `onerror=` handlers don't run (threat 2).
- A `WKContentRuleList` that blocks every network load: anything outside
  `alas-plugin:`, except the `data:` images and fonts and `blob:` images the
  CSP allows.
- `decidePolicyFor navigationAction` cancels everything except the shell,
  external links included: `WKNavigationAction` has no trustworthy
  user-activation flag, and page script can activate an anchor to leak data
  in its URL. A listener in an isolated content world accepts only trusted
  (`isTrusted`) clicks on `https` anchors and asks Alas to open them in the
  default browser, like the `link` node. `createWebViewWith` returns nil, downloads are cancelled, and
  file pickers, media capture and geolocation are denied. JS dialogs are
  unimplemented, so they return at once.
- WebRTC escapes CSP, so a document-start user script deletes
  `RTCPeerConnection` and its relatives before page scripts run. Frames are
  blocked, so the page can't recover them from a fresh realm.
- DNS prefetch is off. CSP doesn't cover it, and `<link rel="dns-prefetch">`
  to a crafted hostname would leak data to whoever runs its DNS. The shell is
  served with `X-DNS-Prefetch-Control: off` and the matching `<meta>` before
  any page script; WebKit doesn't let a document turn it back on, and frames
  are blocked, so no fresh document can either. W1 verifies it against a test
  page with a resolver that records lookups, and doesn't ship if any leak.
- Residual: timing side channels, accepted and listed on the approval sheet's
  line for web content (Q6).

**The bridge carries messages to the plugin and nothing else** (threat 3):

- Alas installs its script message handler in an isolated content world, not
  the page's, so `ui.js` can't reach `window.webkit.messageHandlers` and skip
  the checks. A relay in that world takes `alas.post` calls, enforces the
  size and queue limits, and only then forwards; Alas checks the same bounds
  again before a message enters the plugin's delivery queue. Scripts and
  handlers are scoped to their world, so the two halves meet through the DOM,
  which both worlds share: a page-world shim defines `window.alas`, and
  `alas.post` serializes the value to a JSON string and dispatches a
  `CustomEvent` with an unguessable per-tab name on `document`. The
  isolated-world relay listens for it, checks the string's size and the queue,
  and posts to the handler. Messages to the page go the other way: Alas
  evaluates a call to the shim's dispatcher in the page world with the JSON
  string as an argument, never as code. The page sees only `window.alas`,
  defined by that document-start shim:

  ```js
  alas.post(value)            // any JSON value; the whole web/message it becomes must fit in 1 MiB
  alas.onmessage = (value) => { … }
  alas.context                // { tab, theme: "light" | "dark" }
  ```

- The page can't call Alas methods (`storage/get`, `http/fetch`, …), even with
  the plugin's grants. Everything goes to the plugin as a notification, and
  the plugin decides what to do. A script injected into the page therefore
  gets no more than the ability to send the plugin messages, which the plugin
  must already treat as untrusted input.
- Messages use the plugin's existing JSON-RPC framing, validation and size
  cap:

  | Direction | Message |
  |---|---|
  | plugin → Alas | `web/post {tab, message}` notification: Alas delivers `message` to the page's `onmessage` |
  | Alas → plugin | `web/message {tab, message}` notification: the page called `alas.post` |

- Alas delivers messages to the page with `callAsyncJavaScript` and a JSON
  argument, never by splicing strings into source.

**Limits.**

| Limit | Value | When exceeded |
|---|---|---|
| `ui.js` size | 8 MiB | The manifest is refused. |
| A message, either direction | 1 MiB for the whole encoded JSON-RPC message, envelope included | Page: `alas.post` throws when the `web/message` it would become exceeds it. Plugin: the plugin stops, as for any oversized send. |
| Page → plugin queue | 32 undelivered messages per tab | `alas.post` throws `"busy"`. Each delivery is a normal call under the 250 ms limit. |
| Plugin → page | counts towards the 64 sends per call | as today |
| `web/post` to a tab with no live page | dropped | The page posts its own "ready" on load. |
| Live web tabs per plugin | 4 | Opening another shows a placeholder (Q5). |

The page can't hold more than the plugin gives it. A malicious plugin can still
draw a convincing fake dialog inside its own tab. That is no worse than a
canvas, and the tab chrome always names the plugin.

**Approval.** `web` is not a capability: it grants no new power. The approval
sheet adds one *Sandboxed* line, "Shows its own web content, with no network
access", so the user knows the tab isn't native.

**Developer tools.** `isInspectable` is on in Debug builds, and for plugins
loaded from a folder rather than the catalog (Q7).

### Theme, keyboard, accessibility

- The shell sets `color-scheme: light dark`, the system font and CSS variables
  (`--alas-text`, `--alas-dim`, `--alas-accent`, `--alas-background`,
  `--alas-tone-danger`, …). It updates them when the appearance changes.
- App menu shortcuts keep working. Copy, paste and select-all go to the page
  while it has focus.
- VoiceOver reads the page through WebKit. Semantics are the author's job, and
  the authoring guide says to prefer native nodes when they fit.

### Later

- Web panels (`right`, `changes.section`) with the same bridge, when a plugin
  needs a page outside a tab.
- `img-src` for the plugin's declared `network` hosts (avatars), if Q6 allows.

---

## Rollout

Each row is one PR in Alas plus, where marked, one in `alas-plugins`.

| # | API | Slice | Size |
|---|---|---|---|
| R1 | 10 | `project.host` in `alas/activate`; remote refusals say "remote host" instead of "unknown worktree"; docs `api-v10.md`; SDK type. | S |
| R2 | 11 | Manifest `remote`, approval-sheet wording, trust hash; worktree-scoped helper file operations with `.git` exclusion and `O_NOFOLLOW` walks; remote `file/read`/`file/list`/`file/write` over them, refused without the helper. | M |
| R3 | 11 | Helper: raw output mode, stdin with EOF (`/dev/null` for starts and runs without input), a framed login environment, descendant tracking with start-time identity, terminate the group and descendants when the root exits, `killProc` after the leader dies, capped logs with logical offsets, signal exit codes, deadlines and ownership leases. Remote `process/run` over it; executable resolution on the host. | L |
| R4 | 11 | Remote `process/start`: plugin-owned runs in the remote Run tab, stop on plugin stop. A worktree-setup reference plugin with `"remote": true` (alas-plugins). | M |
| N1 | 9 or 10 | Native `markdown` node, when the Linear bridge or PR inbox needs it. | S |
| W1 | 12 | `web` tab kind: scheme handler, shell, CSP, content rules, non-persistent store, bridge (`web/post`, `web/message`), trust hash plus third catalog asset, limits. Ships with its reference plugin. | L |
| W2 | 12 | Inspector for folder-loaded plugins; `jsc-run`-style smoke test for `ui.js` in alas-plugins CI (load the shell in a headless WKWebView). | S |

R1 is worth landing on its own even if R2–R4 wait. W1 waits for a committed
consumer.

## Compatibility

- `project.host`, `remote`, `web` and `kind: "web"` are additions. An API 4–9
  plugin keeps loading. On a remote project it gets the clearer refusal and the
  same `-32003` code.
- A manifest using `remote` below API 11, or `web` below API 12, is refused,
  like `opens` below API 8.
- R2, R3 and R4 ship together as API 11; until all three are in, Alas keeps
  advertising 10, so no client accepts a `remote` manifest it can't serve.
- An Alas that predates API 12 refuses `kind: "web"` as an unknown tab kind.
  That is already the rule.

## Testing

Per the testing policy, pin the decisions:

- Remote routing: which calls go to the host, which are refused, and the
  message for each case (pure function over project host, `remote` and
  capability).
- Host-side containment, in the helper's own Rust tests, calling each new
  worktree-scoped operation directly: `..`, absolute paths, symlink escape, a
  symlink swapped mid-walk, `.git` aliases in any case, and a contained
  symlink that must keep working. `ACPRemoteFileServerTests` covers the Swift
  shell paths, not these operations, so it is not the place.
- Host-side containment keeps a symlink that resolves inside the worktree
  working (API 6's `inner/c.txt` through `inner -> a`), next to the escape
  cases.
- Remote argv reaches the program unchanged: `appendArgs` with spaces and
  quotes arrive as the same strings, quoted only once, in the helper.
- Helper lifecycle, in the helper's own Rust tests: a long-running start sees
  EOF on stdin; the login environment survives a noisy profile and a value
  with a newline; a backgrounded child is
  stopped when the root exits; a `setsid` descendant is stopped by identity;
  a descendant that forks a new detached child during the `SIGTERM` grace is
  stopped too;
  the group is not signalled once no member matches; the anchor ignores the
  group's `SIGTERM` and outlives it, and is removed only after the final
  `SIGKILL` pass; a lapsed lease and the
  one-shot deadline stop the run; a signal exit reports 128 + n; replay after
  log truncation resumes at the retained base, in the original stdout/stderr
  order.
- Webviews: the scheme handler serves exactly the shell and `ui.js`; the
  navigation policy decision; the CSP header string; bridge size and queue
  caps; the trust hash including `web`. One focused headless `WKWebView` test
  loads hostile page code and proves it can't see the raw message handler,
  that inline script and network loads are blocked, and that DNS prefetch is
  off. That is sandbox policy, not view composition; no other rendering
  tests.

## Decisions (2026-10-03)

- **Order:** remote first, as APIs 10 and 11. Webviews (API 12) wait for a plugin that
  needs them.
- **`markdown` node:** goes into API 9.
- **Remote trust:** one `remote: true` approval per plugin covers every SSH
  host its projects use. No per-host grants.
- **No helper:** remote `process.*` and `file/*` are refused when the remote
  helper is not installed; there is no `RemoteExec` fallback.

## Open questions

Questions 1, 2, 4 and 8 are settled above; the rest stay open until webviews
are built.


1. **Order.** Remote (APIs 10–11) before webviews (API 12)? This spec assumes yes.
2. **`markdown` node first?** Should N1 go into API 9, which is still open,
   since it closes the most common native gap at low cost?
3. **First webview consumer.** Is there a plugin you want soon that needs
   charts or graphs (usage dashboard, stack graph)? Without one, W1 stays on
   paper.
4. **Per-host grants.** Is one `remote: true` approval per plugin enough, or
   should full access be granted per SSH host (e.g. "devbox yes, prod-bastion
   no")?
5. **Webview memory.** Is a cap of 4 live web tabs per plugin right, or should
   hidden pages be discarded and reloaded (VS Code's default) to save the
   WebContent process?
6. **Page images from declared hosts.** Allow `img-src` for the plugin's
   `network` hosts (avatars, CI badges), or keep the page fully offline and
   make plugins fetch and inline images?
7. **Inspector in Release.** Web Inspector only in Debug builds, or also for
   folder-loaded plugins in Release, so authors can debug without building
   Alas?
8. **Helper requirement.** Is refusing remote `process.*` when the remote
   helper is missing acceptable, or must the `RemoteExec` fallback be
   supported even though it can't guarantee process-tree cleanup?
