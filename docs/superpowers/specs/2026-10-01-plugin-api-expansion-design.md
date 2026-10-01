# Plugin API expansion: contribution slots and integration capabilities

Follows API 4, the JavaScript runtime switch, which carries the API 3 surface
(view tabs, `task/start`, storage) unchanged. Tracks phase 5 of
[#1560](https://github.com/mrmans0n/alas/issues/1560). Distribution is covered
separately in `2026-10-01-plugin-repository-design.md`.

## Why

Today a plugin can only live in a tab. The plugins people actually build for
tools like Alas sit next to the work: a CI badge on a worktree row, "Fix this
failure" on a run report, "New worktree from Linear issue" in the palette, a
Slack ping when an agent finishes. Most of them also need things a plugin can't
have today: the network, an API token, and a way to wake up without a user
action.

## What comparable tools do

| Tool | Extension model | Takeaway for Alas |
|---|---|---|
| Paseo | Full plugin system (React Native UI + Node server): sidebar items, workspace/agent panels, header buttons, command center, slash commands, composer attachments, `agent.*`/`workspace.*` events, before-hooks on agent creation. **Unsandboxed.** | The closest feature set. We want the same slots, rendered natively, sandboxed. |
| Claude Code | Plugins bundle skills, commands, hooks, MCP servers, monitors. `userConfig` prompts for settings on enable; `sensitive` values go to the keychain. Marketplaces are git repos. | Settings declared in the manifest, secrets in the Keychain, git-repo catalog. |
| Codex app | Per-repo setup scripts and top-bar actions; automations on a schedule or webhook land in a triage queue; Slack/Linear start tasks. | Timers plus `task/start` cover automations. |
| Supacode, T3 Code, super.engineering, Conductor | No plugins. Per-repo config with setup/run/archive scripts, quick-action buttons, PR/CI state in the sidebar, agent-state badges. | Alas already has run configs and repo hooks; plugins should not re-do script running. |
| Arbor | Worktrees from GitHub/GitLab issues, PR cards in the changes pane, cron tasks with prompt templates, webhook notifications on `agent_finished`. | Issue → worktree, PR data in Changes, finish events. |
| Linear agents, Codex@Linear | Assign an issue to an agent; the agent works and reports back on the issue. | The Linear bridge is the flagship integration. |
| Zed | Wasm extensions with user-granted capabilities (`process:exec`, `download_file` by host); calls without a grant return errors. | Same model as ours: grants checked at the call. |

## Plugin archetypes we want to support

Ranked by how often they show up across these ecosystems.

| # | Archetype | Needs |
|---|---|---|
| 1 | Issue tracker bridge (Linear, Jira, GitHub Issues): pick an issue, start an agent in a new worktree, post back on finish | net, secrets, palette command, right-pane panel, `session.finished`, `task/start` |
| 2 | PR and CI status, "fix failing checks" | net, secrets, timer, worktree badges, worktree menu, Changes section, `session/send` |
| 3 | Notification relay (Slack, Discord, ntfy, webhook) | net, secrets, settings, session and run events |
| 4 | Deploy previews (Vercel, Netlify, Cloudflare) | net, secrets, timer, worktree badge, "Open preview" command |
| 5 | Prompt and template library | slash commands, settings |
| 6 | Docs and context (Notion, Confluence) attached to a prompt | net, secrets, prompt context provider |
| 7 | Cost and usage tracker | usage events, panel, toolbar item |
| 8 | Review checklist / AI reviewer on hunks | Changes file menu, review comments, `git.changed` |
| 9 | Run failure helpers ("explain", "file an issue", "rerun with…") | Run report section, run events, `session/send` |
| 10 | Scheduled agent tasks (nightly triage, dependency bumps) | timer, `task/start` |
| 11 | Error tracking (Sentry, Datadog) → worktree with stack trace | net, secrets, palette command, `task/start` |
| 12 | Time tracking (Toggl, Harvest) | focus events, net, toolbar item |
| 13 | Worktree setup: copy `.env`, install dependencies, pull secrets from 1Password or Doppler | `worktree.created` event, `process.exec`, `files.write`, secrets |
| 14 | Dev server / port manager | `process.exec` (long-running, shown in the Run tab), worktree badge, "Open preview" command |
| 15 | Database viewer | Out of scope: needs sockets and a table view. A CLI client through `process.exec` covers simple queries. |

Rows 13 and 14 need to run processes and touch files, which the sandbox
forbids by default. They get it through two high-trust capabilities
(section 10) rather than by dropping the sandbox for everyone.

## Design

### 1. One action model: commands

A plugin declares commands in its manifest and says where each one may appear.
Alas renders them without waking the plugin, so menus stay instant and a busy
or failed plugin never blocks the UI.

```json
"contributes": {
  "commands": [
    { "id": "fix-ci", "title": "Fix failing checks", "icon": "wrench",
      "slots": ["worktree.menu", "changes.toolbar"] },
    { "id": "from-issue", "title": "New worktree from Linear issue…",
      "slots": ["palette", "repo.menu", "toolbar"] }
  ]
}
```

Running one sends a notification with the target the user acted on:

```json
{ "method": "command/run",
  "params": { "command": "fix-ci",
              "target": { "kind": "worktree", "worktree": "wt-3" } } }
```

| Slot | Where (seam) | Target |
|---|---|---|
| `palette` | Repo selector actions (`RepoSelectorRow.Action`) | current project |
| `menubar` | View → Plugins menu | current project |
| `toolbar` | Puzzle-piece menu button in the center tab bar, between Run and the right-sidebar button | current worktree |
| `repo.menu` | Repo row context menu, before Remove | project |
| `worktree.menu` | Worktree row context menu, before Archive/Delete | worktree |
| `changes.toolbar` | Right pane toolbar overflow on the Changes tab | worktree |
| `changes.file.menu` | `ChangedRow` context menu | worktree + path |
| `changes.commit.menu` | `CommitRow` context menu | worktree + sha |
| `run.menu` | Run row "…" menu | worktree + run script |
| `run.report` | Run report header actions | worktree + run id |
| `session.menu` | ACP tab context menu and ACP toolbar | session |
| `message.menu` | ACP message gutter "…" menu (AppKit `NSMenu`) | session + message (markdown) |

Plugin items appear as one flat, labelled group per plugin: no data-driven
submenus, which render empty in SwiftUI context menus on macOS.

Commands are always enabled. A plugin that can't act answers with
`notify` explaining why. Per-target enablement waits for a real case.

### 2. Decorations: dynamic data on existing rows

Badges change with remote state, so the plugin pushes them instead of declaring
them:

```json
{ "method": "decorations/set",
  "params": { "slot": "worktree.row", "target": "wt-3",
              "items": [{ "text": "CI ✗", "tone": "danger",
                          "tooltip": "2 checks failed", "command": "fix-ci" }] } }
```

- Slots: `repo.row`, `worktree.row` (after the gg stack summary), `run.row`,
  `changes.file` (next to the file name), `toolbar` (a short status text on the
  plugin's toolbar button).
- At most 2 items per plugin per target, text capped at 24 characters. `tone`
  reuses the view tree's badge tones. An item with `command` is clickable.
- Setting replaces that plugin's items for that slot and target. Alas drops a
  plugin's decorations when it stops, fails or is disabled.

### 3. Panels: the view tree outside tabs

The view tree (`view/render`, `view/event`) already renders natively. A
panel is a view tree hosted somewhere other than a tab:

```json
"panels": [
  { "id": "issues", "title": "Linear", "icon": "checklist", "location": "right" },
  { "id": "checks", "location": "changes.section" },
  { "id": "explain", "location": "run.report.section" }
]
```

- `right`: a rail button in the right pane next to Changes/Files/Agent/Run. The
  rail already takes a list of tabs and badges.
- `changes.section`: one row in the Changes scroll plan, after the preparation
  row. Hidden while its tree is empty.
- `run.report.section`: under the run report header. Rendered with the run id in
  context.
- Panels reuse `view/render` with `"panel": "<id>"` (plus the worktree or run id
  where the location has one) instead of a tab id.

### 4. Settings and secrets

A plugin declares its settings; Alas draws the form in Settings → Plugins under
the plugin, and stores the values app-wide, not per project:

```json
"settings": [
  { "key": "team", "title": "Linear team", "type": "string" },
  { "key": "token", "title": "API key", "type": "secret",
    "hosts": ["api.linear.app"] },
  { "key": "notifyOnFinish", "title": "Comment when the agent finishes",
    "type": "bool", "default": true }
]
```

- `settings/get` returns every non-secret value; `settings/changed` is sent when
  the user edits them.
- **Secrets are not readable, but they are usable.** They are stored in the
  Keychain and `settings/get` never returns them. A plugin refers to one in an
  HTTP header as `{{secret:token}}`, and Alas substitutes it only if the request
  goes to one of that secret's `hosts`; otherwise the request is refused with
  `-32001`. An endpoint can still echo a header back, so this keeps the secret
  out of plugin storage and logs, not out of reach: the approval sheet says the
  plugin **can use** the credential with the listed hosts, and a user should
  approve that only for a plugin they trust with it.
- OAuth (PKCE run by Alas, token stored as a secret) is a follow-up. API keys
  cover Linear, Notion, GitHub, Sentry, Vercel and Slack webhooks today.

### 5. Network

```json
"network": ["api.linear.app", "hooks.slack.com"]
```

- Capability `network`. `http/fetch {method, url, headers, body}` answers in a
  later delivery with `{status, headers, body}`, like any other reply.
- HTTPS only. The host must be listed in the manifest, which the approval sheet
  shows next to the capabilities. Changing the list changes the manifest hash,
  so it asks for approval again.
- Limits: 4 requests in flight per instance, 1 MiB response body (the existing
  message cap), 30 s timeout, no redirects to unlisted hosts, no cookies.
- Alas makes the request with `URLSession`. The plugin never gets a socket.

### 6. Timers

- Capability `timers`. `timer/set {id, seconds, repeat}` and `timer/cancel {id}`.
  Fires `timer/fired {id}` as a normal delivery under the normal per-call time limit.
- Minimum 60 s. At most 8 timers per instance. Timers die with the instance.
  They don't survive a restart: the plugin sets them again on activation.

### 7. Events

Plugins subscribe by listing them; each needs a capability:

```json
"events": ["session.finished", "run.finished", "git.changed"]
```

| Event | Capability | Source (choke point) |
|---|---|---|
| `worktree.created`, `worktree.removed` | `workspace.read` | today's snapshot diff, made explicit |
| `session.state` (running, awaiting input, permission, idle) | `session.read` | `observeHarnessAttention` |
| `session.finished` (with last message) | `session.read` | the same, on the transition to idle after a turn |
| `git.changed` (debounced, per worktree) | `workspace.read` | `WorktreeStatusStore.apply` |
| `run.started`, `run.finished` (exit status, run id) | `runs.read` | `AppState+RunScripts` begin/finish |
| `review.changed` (PR state, checks, readiness) | `review.read` | `RightPaneState.refreshReviewLoop` |
| `focus.changed` (worktree) | `workspace.read` | worktree focus |

Events are notifications. If more than 64 are queued for an instance, Alas
drops the oldest.

### 8. Acting on sessions, runs and reviews

New requests that forward to code that already exists (mostly `AlasActionService`):

| Request | Capability | Uses |
|---|---|---|
| `session/send {session, text}` | `session.write` | `sessionSend` |
| `run/start {worktree, script}` | `runs.start` | run tab start action |
| `run/output {run}` (tail, capped) | `runs.read` | `RunRecordStore` |
| `review/comment {worktree, path, line, body}` | `review.write` | `reviewCommentAdd` |
| `notify {title, body, command?}` | `notify` | `inAppNotifications.post` / Attention inbox |
| `open/url {url}` | `notify` | opens in the browser after the user clicks; never automatically |

### 9. Agent context

- **Slash commands.** `contributes.prompts: [{name, description}]` appear in the
  composer's slash picker as `ACPPromptSuggestion`s. Picking one sends
  `prompt/expand {name, session}`; the plugin answers with the text that replaces
  it. Works for a prompt library and for "/linear ENG-123".
- **Context providers.** A plugin with `session.context` can answer
  `context/provide {session, worktree}` before each prompt with up to 16 KiB of
  text. Alas adds it to the wire-only `privateBlocks` in `ACPSessionRunner`, so
  the agent sees it and the transcript doesn't. The composer shows a chip naming
  the plugin while a provider is active, so this is never invisible to the user.
  A provider that is slow (over the per-call time limit) or errors is skipped for that
  prompt.

### 10. High-trust capabilities: processes and files

The sandbox stays the default. A plugin that needs more asks for it by name, the
user grants it per plugin, and everything else about the plugin stays sandboxed.
This is Zed's model: a call without the grant fails, whatever the code does.

**`process.exec`.** The manifest lists every command the plugin may run, as an
exact argv prefix:

```json
"processes": [
  { "id": "install", "command": ["pnpm", "install"] },
  { "id": "op", "command": ["op", "read"], "appendArgs": true },
  { "id": "dev", "command": ["pnpm", "dev"], "longRunning": true }
]
```

- `process/run {id, worktree, args?, stdin?}` runs it with the worktree as
  the working directory and answers in a later delivery with
  `{exit, stdout, stderr}`. Output is capped at 1 MiB, the run at 10 minutes, and
  an instance may have 2 running at once.
- `args` is accepted only when the entry has `appendArgs`; otherwise the argv is
  exactly what the manifest says. Alas resolves the executable and runs it with
  its own environment; a plugin cannot set environment variables, because ones
  like `PATH` or `NODE_OPTIONS` would change what the approved command runs.
  Secrets never go to processes: their output returns to the plugin. Commands
  that need credentials use their own login (`op signin`, `gh auth`).
- `longRunning` processes are started with `process/start` and show up in the
  Run tab as runs owned by the plugin: visible, with output, and stoppable by the
  user. Alas stops them when the plugin stops. There are no invisible processes.
- A worktree must belong to the plugin's project. The process runs with the
  user's permissions, outside any sandbox, and the approval sheet says so in
  those words, listing each command.

**`files.read` and `files.write`.** Scoped to the project's worktrees:

- `file/read {worktree, path}` (≤ 1 MiB), `file/list {worktree, dir}`,
  `file/write {worktree, path, content}`.
- Paths are relative. Alas resolves them and refuses anything that leaves the
  worktree, including through symlinks. Nothing named `.git` is writable at any
  depth: in a linked worktree `.git` is a file pointing at the repository, and
  writing it would redirect git. The check runs on the resolved destination and
  compares case-folded components, so `.GIT/config` on a case-insensitive volume
  and a symlink that resolves into `.git` are refused too.
- Writes show up in the Changes tab like any other edit.

**How the user sees the risk.**

- The approval sheet groups capabilities into *sandboxed* and *full access*
  (`process.exec`, `files.write`), and full-access ones need a separate checkbox.
- The catalog marks plugins that ask for full access, and the alas-plugins
  review checks that each declared command is needed.
- Changing `processes` changes the manifest hash, so a plugin can't add a
  command in an update without asking again.

### What stays out

- **Sockets.** Plugins talk to the network only through `http/fetch`.
- **Running arbitrary commands.** Only commands declared in the manifest.
- **A fully trusted native plugin tier.** Not until a real plugin can't be built
  with the capabilities above.
- **Workspace (multi-repo checkout) slots.** Plugin instances are per project; a
  workspace has no project. Needs an app-scoped instance first.
- **Webviews.** Native slots first, as #1560 says.

## Rollout

Each step ships with a reference plugin in `alas-plugins`, and grows the API
version by one.

| API | Adds | Reference plugin |
|---|---|---|
| 5 | Commands (`palette`, `menubar`, `toolbar`, `worktree.menu`, `repo.menu`), settings and secrets, `network`, `timers`, `notify`, `session.state`, `session.finished` | **Linear bridge**: palette "New worktree from issue", right-pane issue panel, comment on finish |
| 6 | Decorations, Changes and Run slots and panels, `git.changed`, `run.*`, `review.*`, `worktree.created`, `worktree.removed`, `focus.changed`, `session/send`, `run/start`, `review/comment`, `process.exec`, `files.*` | **GitHub checks**: CI badge on worktree rows, "Fix failing checks" sends the failure to the agent. **Worktree setup**: copies `.env`, installs dependencies, starts the dev server |
| 7 | Message and session menus, slash prompts, context providers | **Prompt library** and **Notion context** |
| — | OAuth PKCE, app-scoped instances | when a plugin needs them |

API 5 also introduces `right` panels because the Linear bridge needs a place to
list issues, and adding the right-pane rail later means changing the same files.

## Compatibility

- Every addition is a new capability, method, manifest field or slot, so API 4
  plugins keep loading on an Alas that supports API 5 and later. (API 1–3 were
  the WebAssembly runtime and are refused since the JavaScript switch.)
- An Alas that doesn't know a slot ignores commands placed in it rather than
  refusing the plugin, because slots will keep growing. Unknown capabilities are
  still refused, as today.

## Testing

Per the testing policy, tests pin decisions, not views:

- Slot routing: which commands a slot shows, and the target a command receives.
- Decorations: replace and clear semantics, caps, cleanup when a plugin stops.
- Process and files: argv matching (`appendArgs` on and off), path escapes
  (`..`, absolute paths, symlinks), `.git` writes refused (the linked-worktree file, any `.git` directory, `.GIT` and symlink aliases), output and time caps.
- Network: allowlist matching (subdomains, ports, redirects), secret substitution
  only for its hosts, in-flight and size limits. Use a fake transport.
- Timers with an injected clock.
- Context provider: size cap, skip on failure.
- One `PluginHostTests` case per new host call for the capability check, using
  the JavaScript fixture (`PluginJSFixture`) that replaced the WAT one.
