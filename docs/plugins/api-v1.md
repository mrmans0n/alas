# Alas plugin API v1 reference

> Message reference. Plugins target API 4; see [api-v4.md](api-v4.md) for the runtime.

The messages, types and errors API 1 introduced, all still current. For how the
pieces fit together, read [Concepts](concepts.md) first. To build something,
start with [Getting started](getting-started.md).

**Contents**

1. [Plugin folder and manifest](#1-plugin-folder-and-manifest)
2. [The script](#2-the-script)
3. [Messages](#3-messages)
4. [Types](#4-types)
5. [Delivery semantics](#5-delivery-semantics)
6. [Errors](#6-errors)
7. [Limits](#7-limits)

**Conventions.** All messages are UTF-8 JSON. Examples are pretty-printed, but
Alas sends compact JSON and does not guarantee key order, so parse messages
instead of matching their text. Ignore fields and notifications you do not
recognize.

---

## 1. Plugin folder and manifest

### Layout

Alas scans `~/Library/Application Support/Alas/Plugins/`. Every sub-folder is a
candidate plugin. Symlinked folders are followed, which is handy in development.
An instance launched with `ALAS_APP_SUPPORT_DIR` scans `Plugins/` under that
directory instead, and keeps its own approvals; the sample `build.sh` scripts
install there when the variable is set.

```
Plugins/
└── my-plugin/
    ├── plugin.json     required: the manifest
    └── plugin.js       required: the file named by "entry"
```

The folder name does not matter to Alas. Only `id` identifies a plugin.

### Manifest

```json
{
  "id": "com.example.my-plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "api": 4,
  "entry": "plugin.js",
  "capabilities": ["workspace.read", "worktree.switch"]
}
```

| Field | Type | Required | Rule |
|---|---|---|---|
| `id` | string | yes | Reverse-DNS: dot-separated segments of lowercase letters, digits and `-`, at least two segments (`[a-z0-9-]+(\.[a-z0-9-]+)+`). Must be unique across installed plugins. |
| `name` | string | yes | Non-blank. Shown to the user. |
| `version` | string | yes | Non-blank. Shown to the user; not interpreted. |
| `api` | integer | yes | The plugin API version. Must be `4`. |
| `entry` | string | yes | Path to the script, relative to the plugin folder. Must not start with `/` or contain a `..` segment, and must name a regular file that, with symlinks resolved, lies inside the folder. A symlink as the file itself is not accepted. |
| `capabilities` | array of strings | no | Capabilities the plugin wants. Each must be one listed below. May be omitted, but not `null`. |

Unknown fields are ignored. `contributes` declares tabs; see
[API v2](api-v2.md#manifest-contributestabs) and [API v3](api-v3.md#manifest-tab-kind).

### Validation

Alas checks a manifest in this order and reports the first problem:

1. The file is a JSON object.
2. `id`, `name`, `version`, `api` and `entry` are present, and the strings are
   not blank.
3. `id` has the required format.
4. `api` is supported.
5. Every capability is known.
6. `entry` is a relative path that stays inside the folder.

Then the entry file must exist. A folder that fails any check is listed under
**Not loaded** in **Settings → Plugins** with the reason and is never run. See
[Manifest and discovery errors](#manifest-and-discovery-errors) for the messages.

### Capabilities

| Capability | Lets the plugin | Shown to the user as |
|---|---|---|
| `workspace.read` | Call `workspace/snapshot` and receive `workspace/changed`, for its own project. | Read this project's worktrees and what their agent sessions are doing |
| `worktree.switch` | Call `worktree/switch` to select a worktree of its own project. | Switch the selected worktree |

`log` needs no capability. The capabilities added later are listed in
[API v4](api-v4.md#capabilities).

---

## 2. The script

How the plugin's JavaScript is loaded and called, the `handle` function, and the
`alas.send` and `alas.present` host functions are described in
[API v4 → The script](api-v4.md#2-the-script).

A message is one JSON object, passed and sent as a string. There is no framing,
newline, or batch array.

---

## 3. Messages

### Envelope

Every message is a [JSON-RPC 2.0](https://www.jsonrpc.org/specification) object
with `"jsonrpc": "2.0"`. Three shapes exist:

| Shape | Has | Meaning |
|---|---|---|
| Request | `method` and `id` | Expects exactly one response with the same `id`. |
| Notification | `method`, no `id` | No response. |
| Response | `id`, plus `result` or `error`, no `method` | Answers a request. |

- `id` is an integer or a string of at most 256 bytes, because Alas echoes it in
  the reply. A request with a longer string id stops the plugin. `null` ids are
  not supported: a message with a method and a `null` id is treated as a
  notification.
- Alas uses the integer `0` as the id of `alas/activate`. Your own request ids
  are yours to choose, and Alas echoes them back unchanged.
- Batches (JSON arrays) are not supported.

A message that is not valid JSON, lacks `"jsonrpc": "2.0"`, or has neither a
`method` nor an `id`, stops the plugin (`plugin sent a malformed message`).

### Summary

| Direction | Method | Kind | Capability |
|---|---|---|---|
| Alas → plugin | [`alas/activate`](#alasactivate) | request | none |
| Alas → plugin | [`alas/deactivate`](#alasdeactivate) | notification | none |
| Alas → plugin | [`workspace/changed`](#workspacechanged) | notification | `workspace.read` |
| plugin → Alas | [`workspace/snapshot`](#workspacesnapshot) | request | `workspace.read` |
| plugin → Alas | [`worktree/switch`](#worktreeswitch) | request | `worktree.switch` |
| plugin → Alas | [`log`](#log) | notification | none |

A plugin request with an unknown `method` gets error `-32601`. An unknown
notification, in either direction, is ignored.

### Alas → plugin

#### `alas/activate`

The first message a plugin receives. It starts the plugin for one project.

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "alas/activate",
  "params": {
    "api": 4,
    "project": { "id": "9F1C6A0E-5D2B-4C77-8E4A-1B0C2D3E4F50", "name": "my-project" },
    "grants": ["workspace.read"]
  }
}
```

| Param | Type | Meaning |
|---|---|---|
| `api` | integer | The API version Alas is speaking. |
| `project.id` | string | Opaque identifier of the project. |
| `project.name` | string | The project's display name. |
| `grants` | array of strings | The capabilities the user approved, sorted alphabetically. |

**Response.** During the same call, send:

```json
{ "jsonrpc": "2.0", "id": 0, "result": {} }
```

Send it before any request of your own (a `log` notification may come first). Any `result` is accepted. An `error` response stops
the plugin with `plugin rejected activation: <message>`, and no response at all
stops it with `plugin did not respond to alas/activate`.

#### `alas/deactivate`

Sent as a notification, with no params, when Alas is about to discard the
instance. Use it to clean up. Whatever you send in response is ignored, and the
instance is discarded afterwards regardless.

Alas sends it on **Rescan** or **Restart**, when the plugin is disabled or its
approval revoked, when plugins are turned off in settings, and when the plugin's
project is removed. It is not sent when Alas quits.

#### `workspace/changed`

Sent only to plugins granted `workspace.read`, and only while the plugin is
active. It carries the current [snapshot](#snapshot) of the plugin's project.

```json
{
  "jsonrpc": "2.0",
  "method": "workspace/changed",
  "params": { "snapshot": { "worktrees": [] } }
}
```

Alas checks for changes twice a second and sends a message when the snapshot
differs from the last one it sent this instance. Expect one shortly after
activation, then one after any change, at most two per second.

### Plugin → Alas

#### `workspace/snapshot`

Requires `workspace.read`. Asks for the current [snapshot](#snapshot). `params`
may be omitted.

```json
{ "jsonrpc": "2.0", "id": 1, "method": "workspace/snapshot" }
```

Response:

```json
{ "jsonrpc": "2.0", "id": 1, "result": { "snapshot": { "worktrees": [] } } }
```

You do not need this to stay current, because `workspace/changed` arrives on its
own. It is useful for reading the initial state without waiting for the first one.

#### `worktree/switch`

Requires `worktree.switch`. Selects a worktree in Alas.

```json
{ "jsonrpc": "2.0", "id": 2, "method": "worktree/switch", "params": { "id": "a1b2c3" } }
```

| Param | Type | Meaning |
|---|---|---|
| `id` | string | The `id` of a worktree from the [snapshot](#snapshot). It must belong to the plugin's own project. |

Response on success: `{ "jsonrpc": "2.0", "id": 2, "result": {} }`.
Errors: `-32602` if `id` is missing or not a string, `-32003` if no such worktree
exists in the project.

#### `log`

Writes a line to the plugin's log, shown in **Settings → Plugins**. A notification: there
is no response.

```json
{ "jsonrpc": "2.0", "method": "log", "params": { "level": "info", "message": "hello" } }
```

| Param | Type | Meaning |
|---|---|---|
| `level` | string | One of `debug`, `info`, `warn` or `error`. |
| `message` | string | The text. Truncated to 2,000 Unicode code points. |

A `log` whose params are missing, whose `message` is not a string, or whose `level` is not one of those four is silently dropped.

### Error responses

A refused request gets an error response, and the plugin keeps running:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "error": { "code": -32001, "message": "capability not granted: worktree.switch" }
}
```

The codes are listed under [JSON-RPC error codes](#json-rpc-error-codes).

---

## 4. Types

### Snapshot

The state of one project at one moment. It always describes the **whole**
project, so a plugin never has to apply differences.

```json
{
  "worktrees": [
    {
      "id": "a1b2c3",
      "branch": "main",
      "current": true,
      "dirty": { "files": 3, "conflicts": 0 },
      "sessions": [
        {
          "id": "s-1",
          "agent": "claude",
          "title": "Fix the flaky test",
          "state": "running",
          "plan": { "completed": 2, "total": 5 }
        }
      ]
    }
  ]
}
```

**Snapshot**

| Field | Type | Meaning |
|---|---|---|
| `worktrees` | array of Worktree | Every worktree of the project. The order is not specified. |

**Worktree**

| Field | Type | Present | Meaning |
|---|---|---|---|
| `id` | string | always | Opaque, stable identifier for the worktree. Pass it to `worktree/switch`. |
| `branch` | string | always | The branch checked out. |
| `current` | boolean | always | `true` for the worktree Alas has selected. At most one worktree is current, and none is if the selected worktree belongs to a different project. |
| `dirty` | Dirty | when known | Uncommitted changes. Omitted until Alas has scanned the worktree. |
| `sessions` | array of Session | always | The agent sessions in this worktree. May be empty. |

**Dirty**

| Field | Type | Meaning |
|---|---|---|
| `files` | integer | Number of changed paths. `0` means clean. |
| `conflicts` | integer | How many of those are unmerged. Always at most `files`. |

**Session**

| Field | Type | Present | Meaning |
|---|---|---|---|
| `id` | string | always | Opaque session identifier. |
| `agent` | string | always | Which agent this is, for example `claude` or `codex`. |
| `title` | string | always | The session's title. Free text. |
| `state` | string | always | See below. |
| `plan` | Plan | when the session has a plan | Progress through the agent's plan. |

**Plan**

| Field | Type | Meaning |
|---|---|---|
| `completed` | integer | Steps finished. |
| `total` | integer | Steps in the plan. |

**Session `state`**

| Value | Meaning |
|---|---|
| `running` | The agent is working. |
| `awaiting_input` | The agent is waiting for the user to answer. |
| `permission_request` | The agent is waiting for a permission decision. |
| `idle` | The session is open and nothing is happening. |
| `failed` | The last turn ended in an error; the session waits for the next prompt. |
| `unknown` | Alas cannot tell. |

Sessions that have been detached, meaning history rather than live sessions, are
not included. Treat any state string you do not recognize as `unknown`, because
new ones may be added.

---

## 5. Delivery semantics

- **One message per call.** Each message Alas sends is one `handle` call, and
  Alas never makes a second call while the first is running.
- **Sends are collected, then processed.** Messages sent with `alas.send` during a
  call are processed in the order sent, after `handle` returns.
- **Replies come in later calls.** The response to a plugin request arrives as a
  new `handle` call, in the order the requests were made. Match it by `id`.
- **Bounded chains.** A single delivery, meaning the message Alas started with
  plus the replies to requests the plugin makes in response, allows at most 64
  calls into the plugin. A plugin that answers every reply with another request
  is stopped.
- **Failure discards the call's output.** If a call fails, the messages the plugin
  sent during that call are dropped, including `log`.
- **Deactivation drops the rest.** Once deactivation starts, messages the plugin
  sent during a call still in progress are discarded, and replies not yet
  delivered are never sent.
- **Change detection is coalesced.** `workspace/changed` is driven by a twice-a-second
  check, so a burst of changes may arrive as one message.

---

## 6. Errors

There are three kinds of problem, and they behave differently.

### JSON-RPC error codes

Sent as an error response to a plugin request. The plugin keeps running.

| Code | Message | When |
|---|---|---|
| `-32601` | `method not found: <method>` | The request names a method Alas does not have. |
| `-32001` | `capability not granted: <capability>` | The method needs a capability the user did not grant. |
| `-32602` | `invalid params for <method>` | Required params are missing or the wrong type. |
| `-32003` | `unknown worktree <id>` | `worktree/switch` named a worktree that is not in this project. |

Checks run in that order: an unknown method is reported before a missing
capability, and a missing capability before bad params. Messages that would echo
more than 2,000 Unicode code points of your input, such as a very long method
name, are cut so the reply always fits the message limit.

### Why a plugin stops

The plugin is discarded and its instance shows `Stopped: <reason>`. **Restart**
starts a fresh instance. The reasons are listed in
[API v4 → Why a plugin stops](api-v4.md#5-why-a-plugin-stops).

### Manifest and discovery errors

Shown next to the folder under **Not loaded**. The plugin does not run.

| Message | Cause |
|---|---|
| `plugin.json is not a valid JSON object` | The manifest is not JSON, or not an object. |
| `plugin.json is missing "<field>"` | A required field is absent, or a string field is blank. |
| `invalid plugin id "<id>"; use reverse-DNS such as io.example.plugin` | `id` has the wrong format. |
| `built for plugin API <n>, the WebAssembly runtime, which Alas no longer supports; rebuild it for API 4` | `api` is `1`, `2` or `3`. See [Migrating](api-v4.md#6-migrating-from-api-1-to-3). |
| `requires plugin API <n>; this Alas supports 4` | `api` is any other value but `4`. |
| `unknown capability "<name>"` | A capability Alas does not know. |
| `entry "<path>" must be a relative path inside the plugin folder` | `entry` is absolute, contains `..`, or does not name an existing file. |
| `duplicate plugin id <id>` | Two folders declare the same `id`. Both are rejected. |
| a system file error | The folder has no readable `plugin.json`. |

---

## 7. Limits

| Limit | Value | When exceeded |
|---|---|---|
| Time per call | 250 ms (script evaluation: 1 s) | The plugin is stopped. |
| Message size, either direction | 1 MiB | The plugin is stopped. |
| `alas.send` calls per `handle` call | 64 | The plugin is stopped. |
| String request `id` | 256 bytes | The plugin is stopped. |
| Calls into the plugin per delivery | 64 | The plugin is stopped. |
| `log` message length | 2,000 Unicode code points | Truncated. |
| Log lines kept per instance | 200 | Oldest dropped. **Settings → Plugins** shows them all; **Debug → Plugins…** the latest 5. |
| Messages kept in the trace | 100 | Oldest dropped. **Debug → Plugins…** (Debug builds only) shows the latest 20, each cut to 2,000 bytes. |

The runtime's own limits (script size, frames) are in
[API v4 → Limits](api-v4.md#4-limits).
