# Alas plugin API v4 reference

API 4 is the current plugin API. A plugin is one JavaScript file that Alas runs
in JavaScriptCore. The messages, capabilities, view trees and storage are the
ones API 1 to 3 introduced; their shapes are documented in the
[API v1](api-v1.md), [API v2](api-v2.md) and [API v3](api-v3.md) message
references. This page covers the runtime: the manifest, the script, the two host
functions, the limits, and why a plugin stops.

**Contents**

1. [Plugin folder and manifest](#1-plugin-folder-and-manifest)
2. [The script](#2-the-script)
3. [Methods and notifications](#3-methods-and-notifications)
4. [Limits](#4-limits)
5. [Why a plugin stops](#5-why-a-plugin-stops)
6. [Migrating from API 1 to 3](#6-migrating-from-api-1-to-3)

---

## 1. Plugin folder and manifest

```
Plugins/
└── my-plugin/
    ├── plugin.json     required: the manifest
    └── plugin.js       required: the file named by "entry"
```

Alas scans `~/Library/Application Support/Alas/Plugins/`, or `Plugins/` under
`ALAS_APP_SUPPORT_DIR` when that is set. Symlinked folders are followed. The
folder name does not matter; only `id` identifies a plugin. The one exception is
a folder named exactly after the plugin's `id`: that is where the catalog in
**Settings → Plugins → Available** installs, and a copy you build into any other
folder takes precedence over a release there.

```json
{
  "id": "com.example.my-plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "api": 4,
  "entry": "plugin.js",
  "capabilities": ["workspace.read", "worktree.switch"],
  "contributes": { "tabs": [{ "id": "board", "title": "Board", "kind": "view" }] }
}
```

| Field | Type | Required | Rule |
|---|---|---|---|
| `id` | string | yes | Reverse-DNS: `[a-z0-9-]+(\.[a-z0-9-]+)+`. Unique across installed plugins. |
| `name` | string | yes | Non-blank. Shown to the user. |
| `version` | string | yes | Non-blank. Shown to the user; not interpreted. |
| `api` | integer | yes | Must be `4`. |
| `entry` | string | yes | The script, relative to the plugin folder. No leading `/`, no `..` segment, a regular file (not a symlink) that resolves inside the folder. |
| `capabilities` | array of strings | no | Any of the capabilities below. May be omitted, but not `null`. |
| `contributes.tabs` | array | no | Up to 4 tabs, each `{id, title, kind?}`. `kind` is `canvas` (default) or `view`. See [API v2](api-v2.md#manifest-contributestabs) and [API v3](api-v3.md#manifest-tab-kind). |

Unknown fields are ignored. The validation order and every manifest error are in
[API v1 → Validation](api-v1.md#validation).

### Capabilities

Every capability is available at API 4.

| Capability | Covers | Shown to the user as |
|---|---|---|
| `workspace.read` | `workspace/snapshot`, `workspace/changed`, `agent/list` | Read this project's worktrees and what their agent sessions are doing |
| `worktree.switch` | `worktree/switch` | Switch the selected worktree |
| `session.focus` | `session/focus` | Open agent sessions in this project |
| `session.read` | `session/last_message` | Read agents' final replies in this project |
| `tasks.start` | `task/start` | Create worktrees and start agents in this project |

---

## 2. The script

### Evaluation

Alas reads the entry file (at most 8 MiB of UTF-8) and evaluates it once, when
the instance activates, in a fresh JavaScriptCore context. Every instance (one
per plugin per project) gets its own VM, so instances share no objects and no
heap. Top-level code runs during evaluation, so module state set up there
persists for the life of the instance.

The script is evaluated as a classic script: a plain script, or a bundle such as
the output of `esbuild --bundle --format=iife`. ES module syntax (`import`,
`export`) does not parse, so bundle a multi-file plugin first. Once evaluated,
`globalThis.handle` must be a function. Otherwise activation fails with
`plugin does not define globalThis.handle`.

### Globals

The global object has the ECMAScript built-ins (`JSON`, `Map`, `Promise`, typed
arrays, `Math`, and so on) and `alas`. Nothing else: no `console`, `fetch`,
timers (`setTimeout`, `setInterval`), `require`, `process`, `TextEncoder`,
`WebAssembly`, or DOM. `Math.random()` and `Date.now()` are the built-in ones.

Promises work, and their microtasks run before the call returns. Work that waits
on anything outside the call never resumes, because nothing outside the call
exists.

### `handle(json)`

```js
globalThis.handle = (json) => {
  const message = JSON.parse(json);
  // react, call alas.send(...) for each reply or request, return
};
```

Each message Alas delivers is one call to `handle`, with one JSON-RPC 2.0
message as a string. The return value is ignored. Alas never calls `handle`
while a call is running.

### `alas.send(json)`

Queues one outgoing JSON-RPC message. It must be a string holding one JSON
object (not an array), at most 1 MiB, and at most 64 sends per call. Alas
processes the queued messages in order **after** `handle` returns; replies to
your requests arrive in later calls.

A refused send (not a string, too large, too many) throws into the script, and
the whole call fails even if the script catches the exception. The plugin is
stopped with the reason.

### `alas.present(tab, pixels, width)`

Draws one frame into a canvas tab. Defined only when the manifest declares at
least one tab.

| Argument | Rule |
|---|---|
| `tab` | A number: the index of a declared tab. Presenting to a view tab stops the plugin. |
| `pixels` | A `Uint8Array` or `Uint8ClampedArray` of RGBA8 pixels, non-premultiplied, row-major, top-left origin. At most 4 MiB. |
| `width` | A number, 1 to 1024. `pixels.length` must be a multiple of `width * 4`, and the height `length / (width * 4)` must be 1 to 1024. |

Alas copies the bytes the array covers, so a `subarray` of a larger buffer is
fine and you may reuse the buffer after the call. If a tab is presented more than
once in a call, the last frame wins. Frames from a failed call are discarded. An
invalid frame throws into the script and fails the call, like a refused send.

How the frame is drawn, and the `tick` and region messages that go with it, are
in [API v2](api-v2.md).

---

## 3. Methods and notifications

Message shapes, params and error codes are in the linked references. Requests
the plugin sends without the capability get `-32001`; unknown methods get
`-32601`.

| Direction | Method | Kind | Capability | Reference |
|---|---|---|---|---|
| Alas → plugin | `alas/activate` | request | none | [v1](api-v1.md#alasactivate) |
| Alas → plugin | `alas/deactivate` | notification | none | [v1](api-v1.md#alasdeactivate) |
| Alas → plugin | `workspace/changed` | notification | `workspace.read` | [v1](api-v1.md#workspacechanged) |
| Alas → plugin | `tick` | notification | none (canvas tabs only) | [v2](api-v2.md#tick-dt) |
| Alas → plugin | `canvas/click` | notification | none | [v2](api-v2.md#canvasregions-and-canvasclick) |
| Alas → plugin | `view/event` | notification | none | [v3](api-v3.md#viewevent) |
| Alas → plugin | `task/failed` | notification | none | [v3](api-v3.md#taskstart) |
| plugin → Alas | `workspace/snapshot` | request | `workspace.read` | [v1](api-v1.md#workspacesnapshot) |
| plugin → Alas | `worktree/switch` | request | `worktree.switch` | [v1](api-v1.md#worktreeswitch) |
| plugin → Alas | `session/focus` | request | `session.focus` | [v2](api-v2.md#sessionfocus) |
| plugin → Alas | `session/last_message` | request | `session.read` | [v3](api-v3.md#reading-sessions-and-agents) |
| plugin → Alas | `agent/list` | request | `workspace.read` | [v3](api-v3.md#reading-sessions-and-agents) |
| plugin → Alas | `task/start` | request | `tasks.start` | [v3](api-v3.md#taskstart) |
| plugin → Alas | `storage/get`, `storage/set`, `storage/keys` | request | none | [v3](api-v3.md#storage) |
| plugin → Alas | `log` | notification | none | [v1](api-v1.md#log) |
| plugin → Alas | `canvas/regions` | notification | none | [v2](api-v2.md#canvasregions-and-canvasclick) |
| plugin → Alas | `view/render` | notification | none | [v3](api-v3.md#viewrender) |

`alas/activate` carries `"api": 4`. Answer it during the first `handle` call,
before any request of your own.

---

## 4. Limits

| Limit | Value | When exceeded |
|---|---|---|
| Script size | 8 MiB | The plugin fails to load. |
| Script evaluation | 1 s of CPU time | The plugin stops: `plugin took longer than 1000 ms`. |
| Each `handle` call, including the `alas/activate` one | 250 ms of CPU time | The plugin stops: `plugin took longer than 250 ms`. |
| Message size, either direction | 1 MiB | The plugin stops. |
| `alas.send` calls per `handle` call | 64 | The plugin stops. |
| `handle` calls per delivery (the message plus replies to the plugin's requests) | 64 | The plugin stops. |
| String request `id` | 256 bytes | The plugin stops. |
| Frame width and height | 1 to 1024 | The plugin stops. |
| Frame size | 4 MiB | The plugin stops. |
| Tick rate | 15 fps | Ticks are dropped while a delivery is running. |

Memory is not capped. JavaScriptCore has no per-VM heap limit Alas can enforce,
so the time limit is what bounds growth: one call can allocate on the order of
70 MB before it is stopped. A plugin that keeps everything it ever received can
still grow across calls, so drop what you no longer need.

The other limits (log length, regions, view trees, storage) are in the v1, v2
and v3 references.

---

## 5. Why a plugin stops

The instance shows `Stopped: <reason>`. **Restart** creates a fresh instance with
a fresh VM.

| Reason | Cause |
|---|---|
| `could not load plugin: script of <n> bytes exceeds the size limit` | The entry file is over 8 MiB. |
| `could not load plugin: script is not UTF-8` | The entry file is not valid UTF-8. |
| `plugin does not define globalThis.handle` | After evaluation, `globalThis.handle` is missing or not a function. |
| `plugin threw: <message>` | An uncaught exception, during evaluation (including a syntax error) or in `handle`. Only the first line of the message is kept. |
| `plugin took longer than <n> ms` | The script or a call ran past its time limit. |
| `alas.send expects one string` | `alas.send` got something other than a string. |
| `message of <n> bytes exceeds the size limit` | A message was larger than 1 MiB. |
| `plugin sent more than 64 messages in one call` | Too many `alas.send` calls in one `handle` call. |
| `plugin presented an invalid frame: <detail>` | `alas.present` got an undeclared tab, a bad width, something other than a `Uint8Array`, or a length that does not fit. |
| `plugin presented a frame to view tab <n>` | `alas.present` targeted a view tab. |
| `plugin did not respond to alas/activate` | No response to `alas/activate` in the first call. |
| `plugin rejected activation: <message>` | The response to `alas/activate` was an error. |
| `plugin sent a request before answering alas/activate` | A request came before the activation response. |
| `plugin sent a malformed message` | Not valid JSON-RPC 2.0. See [API v1 → Envelope](api-v1.md#envelope). |
| `plugin sent a request id longer than 256 bytes` | A request had a string `id` over the limit. |
| `plugin exceeded 64 round trips in one delivery` | See [API v1 → Delivery semantics](api-v1.md#5-delivery-semantics). |

Canvas and view tab violations (bad `canvas/regions`, invalid view trees) stop
the plugin with their own reasons, listed in [API v2](api-v2.md) and
[API v3](api-v3.md).

When a call fails, everything it sent and presented is discarded, `log`
included.

---

## 6. Migrating from API 1 to 3

API 1 to 3 plugins were WebAssembly modules. Alas no longer runs them and lists
them under **Not loaded** with:

```
built for plugin API 3, the WebAssembly runtime, which Alas no longer supports; rebuild it for API 4
```

To migrate, rewrite the plugin in JavaScript (or TypeScript bundled to one file),
set `"api": 4` and point `entry` at the script. The messages are the same, so
the protocol logic carries over; only the glue changes: `alas_handle(ptr, len)`
becomes `globalThis.handle(json)`, `alas.send(ptr, len)` takes a string, and
`alas.present` takes a typed array instead of a pointer and length. Capabilities
no longer depend on the `api` number, and `kind` and `contributes` are always
read.
