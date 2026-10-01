# Plugin API expansion: contribution slots and integration capabilities

Follows API 3 (view tabs, `task/start`, storage). Tracks phase 5 of
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
| 13 | Worktree setup, ports, env and secrets | **Not a plugin.** Repo hooks and run configs already run scripts. |
| 14 | Dev server / port manager | **Not a plugin.** Run tab already owns processes and endpoints. |
| 15 | Database viewer | Out of scope: needs sockets and a table view. |

Rows 13–15 are deliberate gaps: they need to spawn processes or open sockets,
which would end the sandbox. Alas keeps owning processes; a plugin can
*trigger* a run configuration it doesn't own (`run/start`, below).

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

API 3's view tree (`view/render`, `view/event`) already renders natively. A
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
- **Secrets never reach the plugin.** They are stored in the Keychain. A plugin
  refers to one in an HTTP header as `{{secret:token}}`. Alas substitutes it
  only if the request goes to one of that secret's `hosts`. Otherwise the request
  is refused with `-32001`.
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
  Fires `timer/fired {id}` as a normal delivery with the normal fuel budget.
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
  A provider that is slow (over its fuel budget) or errors is skipped for that
  prompt.

### What stays out

- **Spawning processes and opening sockets.** That ends the sandbox. Scripts
  belong in repo hooks and run configs, which plugins can trigger.
- **File access.** Deferred until a plugin needs more than the diff, the
  review comments and run output it can already get. When it lands it is
  read-only, scoped to one worktree, and size-capped.
- **Workspace (multi-repo checkout) slots.** Plugin instances are per project; a
  workspace has no project. Needs an app-scoped instance first.
- **Webviews.** Native slots first, as #1560 says.

## Rollout

Each step ships with a reference plugin in `alas-plugins`, and grows the API
version by one.

| API | Adds | Reference plugin |
|---|---|---|
| 4 | Commands (`palette`, `menubar`, `toolbar`, `worktree.menu`, `repo.menu`), settings and secrets, `network`, `timers`, `notify`, `session.finished` | **Linear bridge**: palette "New worktree from issue", right-pane issue panel, comment on finish |
| 5 | Decorations, Changes and Run slots and panels, `git.changed`, `run.*`, `review.*`, `session/send`, `run/start`, `review/comment` | **GitHub checks**: CI badge on worktree rows, "Fix failing checks" sends the failure to the agent |
| 6 | Message and session menus, slash prompts, context providers | **Prompt library** and **Notion context** |
| — | OAuth PKCE, file read, app-scoped instances | when a plugin needs them |

API 4 also introduces `right` panels because the Linear bridge needs a place to
list issues, and adding the right-pane rail later means changing the same files.

## Compatibility

- Every addition is a new capability, method, manifest field or slot, so API 1–3
  plugins keep loading.
- An Alas that doesn't know a slot ignores commands placed in it rather than
  refusing the plugin, because slots will keep growing. Unknown capabilities are
  still refused, as today.

## Testing

Per the testing policy, tests pin decisions, not views:

- Slot routing: which commands a slot shows, and the target a command receives.
- Decorations: replace and clear semantics, caps, cleanup when a plugin stops.
- Network: allowlist matching (subdomains, ports, redirects), secret substitution
  only for its hosts, in-flight and size limits. Use a fake transport.
- Timers with an injected clock.
- Context provider: size cap, skip on failure.
- One `PluginHostTests` WAT fixture per new host call for the capability check.
