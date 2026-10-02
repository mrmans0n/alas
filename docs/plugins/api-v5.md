# Plugin API v5

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md); everything there still applies.

API 5 adds commands, notifications and session events. It is being built in
steps, so this page lists only what Alas already does.

## The `api` field

Alas loads plugins with `"api": 4` or `"api": 5`. A plugin keeps working at
API 4 until it uses something below: `contributes.commands`, `events` and the
`notify` capability need `"api": 5`. An API 4 manifest that uses them is
refused, and so is an API 5 plugin on an Alas that only knows API 4, so a
plugin never half-works.

`alas/activate` carries the manifest's `api`.

## Commands

```json
{
  "api": 5,
  "contributes": {
    "commands": [
      { "id": "fix-ci", "title": "Fix failing checks", "icon": "wrench", "slots": ["worktree.menu", "toolbar"] },
      { "id": "from-issue", "title": "New worktree from issue…", "slots": ["palette", "repo.menu"] }
    ]
  }
}
```

| Field | Rule |
|---|---|
| `id` | `[a-z0-9-]+(\.[a-z0-9-]+)*`, unique within the plugin. |
| `title` | 1 to 40 characters after trimming. |
| `icon` | Optional SF Symbol name. |
| `slots` | Non-empty. Slot names this Alas does not know are skipped, not refused, so a plugin can name slots newer Alas versions add. |

Up to 16 commands. Alas draws them without calling the plugin, and only while
the plugin is running in that project.

| Slot | Where | Target |
|---|---|---|
| `palette` | The repo selector, after Add project…; typing filters them by title | current project |
| `menubar` | View → Plugins | current project |
| `toolbar` | A puzzle-piece menu in the tab bar, between Run and the right sidebar button | current worktree |
| `repo.menu` | The project's context menu in the sidebar, before Remove Project… | project |
| `worktree.menu` | A worktree's context menu, before Archive and Delete | that worktree |

Choosing one sends the notification `command/run`:

```json
{ "jsonrpc": "2.0", "method": "command/run",
  "params": { "command": "fix-ci", "target": { "kind": "worktree", "worktree": "wt-3" } } }
```

`target` is `{"kind": "project"}` or `{"kind": "worktree", "worktree": <id>}`.
The worktree id is the one in `workspace/snapshot`. Commands are always
enabled; a plugin that cannot act on the target can say why with `notify`.

## `notify`

Capability `notify`, shown as "Show notifications".

Plugin to host notification `notify {title, body?}`. Alas shows it as an in-app
notification on the project's selected worktree, or its first worktree when
another project is selected, prefixed with the plugin's name. `title` is cut to
80 Unicode scalars and `body` to 500.

At most one notification every 2 seconds per plugin and project; the others are
dropped, not queued. Without the capability they are dropped too, and the
plugin's log gets one warning.

## Events

```json
{ "api": 5, "capabilities": ["session.read"], "events": ["session.state", "session.finished"] }
```

| Event | Capability | Notification | Sent when |
|---|---|---|---|
| `session.state` | `session.read` | `session/state {session, worktree, state}` | A session in the project appears, changes state, or leaves. |
| `session.finished` | `session.read` | `session/finished {session, worktree}` | A session goes from `running` to `idle`. |

`state` uses the values of `workspace/snapshot` (`running`, `awaiting_input`,
`permission_request`, `idle`, `unknown`), plus `gone` when a session leaves the
project: it was closed, or it disconnected and is no longer live. Alas compares snapshots
every half second, so a change shorter than that may not be seen. The first
snapshot after the plugin starts is the baseline and sends nothing.

An unknown event name refuses the manifest, as does an event whose capability is
not in `capabilities`. A plugin only receives the events it lists.
