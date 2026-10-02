# Plugin API v5

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md); everything there still applies.

API 5 adds commands, notifications, session events, settings and secrets, web
requests and timers. It is being built in steps, so this page lists only what
Alas already does.

## The `api` field

Alas loads plugins with `"api": 4` or `"api": 5`. A plugin keeps working at
API 4 until it uses something below: `contributes.commands`, `events`,
`settings`, `network` and the `notify`, `network` and `timers` capabilities need
`"api": 5`. An API 4 manifest that uses them is
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

## Settings and secrets

```json
{
  "api": 5,
  "capabilities": ["network"],
  "network": ["api.linear.app"],
  "settings": [
    { "key": "team", "title": "Linear team", "type": "string" },
    { "key": "token", "title": "API key", "type": "secret", "hosts": ["api.linear.app"] },
    { "key": "notifyOnFinish", "title": "Comment when the agent finishes", "type": "bool", "default": true }
  ]
}
```

| Field | Rule |
|---|---|
| `key` | 1 to 64 of `A-Z a-z 0-9 _ -`, unique within the plugin. |
| `title` | 1 to 40 characters after trimming. |
| `type` | `string`, `bool` or `secret`. |
| `default` | Optional; a string for `string`, a boolean for `bool`. Secrets have none. |
| `hosts` | Secrets only, and required: the hosts the secret may be sent to. Each must also be in `network`. |

Up to 16 settings. Alas draws the form under the plugin in Settings → Plugins
once it is approved. Values belong to the plugin, not to a project: every
project the plugin runs in sees the same ones.

Request `settings/get` (no capability) answers `{values}`: every `string` and
`bool` setting, with its default when the user has not set it (`""` and `false`
when there is no default). Secrets are never in it. When the user changes a
setting, each running instance gets the notification `settings/changed {values}`,
the same shape. Text fields change when the user presses Return or leaves the
field.

### Secrets are usable, not readable

Alas keeps secrets in the Keychain and never sends them to the plugin. A plugin
uses one by writing `{{secret:key}}` in a header value of `http/fetch`:

```json
{ "method": "POST", "url": "https://api.linear.app/graphql",
  "headers": { "Authorization": "{{secret:token}}" }, "body": "..." }
```

Alas substitutes it only when the request's host is one of the secret's
`hosts`. Otherwise it answers `-32001` "secret token is not allowed for <host>".
An unknown key, or a secret the user has not set, answers `-32602`. Only
headers are substituted, not the URL or the body.

This keeps the key out of the plugin's memory and limits where it can be sent.
It does not keep it from a plugin that wants it: an endpoint on an allowed host
that echoes request headers back would hand it over. The approval sheet lists
each secret with its hosts ("Can use API key with api.linear.app") so the user
can judge that.

## Web requests

Capability `network`, shown as "Make web requests to the hosts it lists". The
manifest's `network` lists the hosts: exact, lowercase names such as
`api.linear.app`, with no scheme, port or wildcard. It must be non-empty when the
capability is requested, and is refused without it. The approval sheet shows
the list, and changing it asks for approval again.

Request `http/fetch {method, url, headers?, body?}`. `method` is one of `GET`,
`HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`; `body` is a UTF-8 string. Unlike other
requests, the reply does not come back in the same delivery: Alas answers
once the request finishes, in a later delivery, with

```json
{ "jsonrpc": "2.0", "id": 7, "result": { "status": 200, "headers": { "content-type": "application/json" }, "body": "..." } }
```

Header names in the reply are lowercase. A reply only reaches the instance that
made the request; if the plugin was restarted or stopped meanwhile, it is
dropped.

| Rule | Refusal |
|---|---|
| `https` only, on the default port | `-32602` (`http`), `-32001` (another port) |
| The host must be in `network` | `-32001` |
| Request body up to 1 MiB | `-32602` |
| 4 requests in flight per instance | `-32003` "too many requests in flight" |
| Response body up to 1 MiB, UTF-8 text | `-32003`; binary bodies are not supported yet |
| 30 seconds | `-32003` "request failed: …", as for any network error |

Redirects are followed only to `https` hosts in `network`, and when a header
carries a secret, only to that secret's hosts; any other redirect comes back as
the 3xx response itself. Requests carry no cookies and store none, and nothing
is cached.

## Timers

Capability `timers`, shown as "Run on a schedule".

| Request | Result |
|---|---|
| `timer/set {id, seconds, repeat?}` | `{}`. Replaces a timer with the same `id`. |
| `timer/cancel {id}` | `{}`, also when there is no such timer. |

`id` is 1 to 64 bytes; `seconds` is 60 to 86,400; `repeat` defaults to `false`.
At most 8 timers per instance (`-32003`). When one is due Alas sends the
notification `timer/fired {id}` as a normal delivery, with the normal time
limit. Timers belong to the instance: stopping, failing or restarting the plugin
clears them, so set them again on `alas/activate`.
