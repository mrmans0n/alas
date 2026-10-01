# Plugin API v3

API 3 is API 2 plus native view tabs, task starting and plugin storage.
Everything in the [API v1 reference](api-v1.md) and [API v2 additions](api-v2.md)
still applies.

## What's new in API 3

Declare `"api": 3` in `plugin.json` to use anything on this page. An Alas that
only supports an older API refuses the plugin with
`requires plugin API 3; this Alas supports ...`. API 1 and 2 plugins are
unchanged.

## Manifest: tab `kind`

```json
{
  "api": 3,
  "capabilities": ["workspace.read", "session.focus", "session.read", "tasks.start"],
  "contributes": { "tabs": [{ "id": "board", "title": "Board", "kind": "view" }] }
}
```

- `kind` is `"canvas"` (the default) or `"view"`. Any other value is an invalid
  tab, and so is `kind` in a manifest with `"api"` below 3.
- View tabs open from **View → Plugins** like canvas tabs, and are restored the
  same way. They never receive `tick`.
- `tasks.start` and `session.read` are API 3 capabilities; a manifest that
  requests either with a lower `api` is rejected. `session.focus` stays an API 2 capability.

## `view/render`

Plugin to host notification `view/render {tab, root}`. `tab` is the index into
`contributes.tabs` and must be a view tab. `root` replaces the tab's whole tree.
Send the complete tree every time; there are no patches. Alas keeps the last
tree per tab and renders it with native SwiftUI controls, diffing by node `id`,
so focus, scroll position and text being typed survive a re-render.

Every node has `id` (a string, unique within the tree, 1 to 64 bytes) and `kind`:

| Kind | Fields | Events |
|---|---|---|
| `vstack`, `hstack` | `children`, `spacing?` (0 to 32), `width?` (vstack only) | none |
| `scroll` | `child`, `axis`: `"vertical"` or `"horizontal"` | none |
| `text` | `text`, `style?`: `body`, `caption`, `title`, `monospaced`; `tone?`: `normal`, `dim`, `accent`, `warn`, `danger` | none |
| `badge` | `text`, `tone?` | none |
| `button` | `label`, `icon?` (SF Symbol name), `style?`: `normal`, `primary`, `plain`; `disabled?` | `click` |
| `textField` | `value`, `placeholder?`, `multiline?` | `submit` with `value` |
| `menu` | `label`, `items`: `[{id, label}]` | `select` with the item's `id` as `value` |
| `card` | `children`, `tone?`, `clickable?`, `width?` | `click` when clickable |
| `divider`, `spacer` | none | none |

- `width` is an optional integer number of points, 40 to 1000, that fixes the
  width of a `vstack` or `card`. It is ignored on every other kind.
- Colours, fonts and spacing come from the Alas theme. A plugin picks only the
  semantic `style` and `tone`.
- `textField` keeps its editing state on the host. `value` is the initial text,
  applied when the node first appears or when its `value` changes between two
  renders; a re-render with the same `value` does not overwrite typing.
  `submit` is Return, or Command-Return when `multiline`. The submitted text is
  capped at 64 KiB (cut on a character boundary).
- Unknown optional fields are ignored, so newer plugins still render on this
  host. An unknown `kind` is an error.
- Numbers in a tree (and in stored values) are re-serialised by the host, so
  `1.0` reaches the tree as `1`. Do not rely on a number keeping its written form.
- Buttons, menus and clickable cards take their accessibility label from their
  visible text. A clickable card is a keyboard stop like a button; Space or
  Return clicks it.

### Limits and what stops the plugin

| Limit | Value |
|---|---|
| Nodes per tree | 2,000 |
| Depth | 16 levels |
| String fields | 4,000 Unicode scalars |
| Node and menu item ids | 1 to 64 bytes |
| Menu items | 64 |
| `spacing` | 0 to 32 |
| `width` | 40 to 1000 |

The host stops the plugin, with the reason, on: a duplicate id, an unknown
`kind`, `tone` or `style`, a missing required field, a field of the wrong type
or out of range, a tree over the limits, or a `tab` that is not a view tab.
Sending `alas.present` or `canvas/regions` for a view tab, or `view/render` for
a canvas tab, also stops the plugin.

### Lifecycle

A plugin's trees are dropped when it activates, so a restarting plugin shows
the loading state until it renders its first new tree. With nothing to show the
tab displays the usual placeholders: unavailable, stopped (with Restart), or
loading. A failed or stopped plugin drops its trees.

## `view/event`

Host to plugin notification `view/event {tab, id, kind, value?}`. `kind` is
`click`, `submit` or `select`; `value` is the text for `submit` and the item id
for `select`. Events are only delivered for nodes in the tree the host is
currently showing.

## Capability: `tasks.start`

Approval text: "Create worktrees and start agents in this project".

## Capability: `session.read`

Approval text: "Read agents' final replies in this project". It covers
`session/last_message`, which exposes what an agent wrote, so it is a separate
approval from `workspace.read`.

## `task/start`

Request `task/start {title, prompt, branch?, agent?}` returns
`{sessionId, branch}`.

- `title` and `prompt` are required and non-empty; `prompt` is at most 32 KiB.
- `agent` is an ACP agent id. Without it, the project's default agent is used.
- `branch` is optional; an empty string counts as not given. Alas uses it when
  it is a valid branch name. Otherwise, and when it is absent, the name is
  `task/<slug>`, where the slug is derived from the given name or the title
  (ASCII letters and digits, dash separated, at most 48 characters, `task` if
  nothing is left).
- The reply carries the requested (normalised) branch. If that branch or its
  folder is taken, Alas creates a suffixed one instead, and the real name shows
  up in the workspace snapshot for the new worktree.
- The reply comes at once with a new `sessionId`. Alas then creates a worktree
  from the project's default base branch and starts the agent with the prompt
  in the background, the way scheduled runs do.
- Starting a task neither changes the selected worktree nor the selection.
  The agent's chat tab opens inside the new worktree, so the user's current
  view is not moved.
- Follow the session through `workspace/changed`, and open it with
  `session/focus`.
- If the background launch fails, the plugin gets a `task/failed {sessionId,
  reason}` notification and Alas shows the reason as an in-app error for that
  worktree.
- Only one start can be in flight per plugin and project.

| Error | When |
|---|---|
| `-32001` | `tasks.start` not granted |
| `-32602` | missing or empty `title` or `prompt`, prompt over 32 KiB, or an agent that is unknown or "cannot take a prompt" (also when the project's default agent is not a chat agent) |
| `-32003` | "a task is already starting", or the project has no default agent at all |

## Storage

Each plugin has a private key-value store per project. No capability is needed,
because the data is the plugin's own. It is API 3 only.

| Request | Reply |
|---|---|
| `storage/get {key}` | `{value}`; `null` when the key is not set |
| `storage/set {key, value}` | `{}`; a `null` value deletes the key |
| `storage/keys` | `{keys: [String]}`, sorted |

- Keys are 1 to 128 bytes. Values are any valid JSON (UTF-8).
- The total size of keys and values per plugin and project is at most 1 MiB.
- Numbers are re-serialised by the host, so `1.0` is read back as `1`.
- `storage/set` replies once the value is readable; the file is written off the
  main thread right after. A write that fails is retried with the next change.
- A reply larger than the message limit (1 MiB), such as a very large stored
  value or many keys, is answered with `-32003` "the result of <method> is too
  large" and the plugin keeps running.

| Error | When |
|---|---|
| `-32602` | invalid key (empty or over 128 bytes, for `storage/get` too) or an invalid value |
| `-32003` | "storage full" (nothing is written), or "storage unavailable" on any request when the stored file cannot be read and could not be moved aside |

The data is one JSON file per plugin and project at
`PluginData/<pluginID>/<projectID>.json` under Alas's application support
folder, written atomically on every change. It survives disabling, revoking
approval and removing the plugin, so a reinstall keeps its data. Deleting the
folder resets it. A file that cannot be read is moved aside as `.corrupt`
rather than overwritten.

## Reading sessions and agents

Two read-only requests, both API 3 (below API 3 they answer `-32601`).
`session/last_message` needs `session.read`; `agent/list` needs `workspace.read`.

| Request | Reply |
|---|---|
| `session/last_message {id}` | `{message}`: the session's last agent reply, trimmed, or `null` |
| `agent/list` | `{agents: [{id, name}]}`: the agents that can be started, in the order Alas lists them |

- `message` is cut to at most 4,096 UTF-8 bytes, on a character boundary.
  It is `null` when the session has not produced a reply yet and for terminal
  sessions.
- `id` is a session id from `workspace/snapshot`.

| Error | When |
|---|---|
| `-32001` | the request's capability was not granted |
| `-32003` | "unknown session <id>": not an active session of this project |
| `-32602` | invalid params |

## Reference plugin

[`plugins/kanban`](../../plugins/kanban) is a small ticket tracker built on all
of the above. Tickets live in storage as a `meta` key, an `index` and one
`ticket-<n>` key per body, so drawing the board reads only the index. **Start**
runs `task/start` with the ticket in the prompt and the assignee picked from
`agent/list`; the ticket then follows its session through `workspace/changed`,
and when the session goes idle the plugin fetches `session/last_message` and
adds it as a comment. Its README records how its caps were sized against the
per-call fuel budget.
