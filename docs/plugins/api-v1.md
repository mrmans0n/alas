# Alas plugin API v1

Alas plugins are WebAssembly modules that talk to Alas with JSON-RPC 2.0
messages. They have no filesystem, network, environment, or clock access. All
they can do is send messages, and Alas answers requests only for capabilities
the user approved.

## Installing

Put a folder in `~/Library/Application Support/Alas/Plugins/` containing
`plugin.json` and the wasm file it names. A symlinked folder works too. Open
**Debug → Plugins…**, then choose **Approve and run**. If you change either
file, the plugin needs approval again.

## Manifest

```json
{
  "id": "io.example.my-plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "api": 1,
  "entry": "plugin.wasm",
  "capabilities": ["workspace.read"]
}
```

| Field | Rule |
|---|---|
| `id` | Reverse-DNS: lowercase letters, digits, `-`, and at least one dot. Unique across installed plugins. |
| `name`, `version` | Non-empty strings. |
| `api` | Must be `1`. Anything else fails with `requires plugin API N; this Alas supports 1`. |
| `entry` | Relative path to the wasm file inside the plugin folder. |
| `capabilities` | Optional. Each must be one of the capabilities below; an unknown name rejects the plugin. |

Unknown fields are ignored.

## Wasm ABI

The module must export:

- `memory`
- `alas_alloc(len: i32) -> i32`: returns a buffer of `len` bytes. Alas writes
  one incoming message there. The plugin owns the buffer and must free it.
- `alas_handle(ptr: i32, len: i32)`: handles one message.

The module may import only `alas.send(ptr: i32, len: i32)`, which sends one
message to Alas. Any other import, including WASI, fails to load.

Messages sent during `alas_handle` are processed after it returns. Alas never
calls into a plugin while the plugin is running. A response to a plugin request
arrives in a later `alas_handle` call.

## Lifecycle

1. Alas sends `alas/activate` with id `0` and params
   `{api, project: {id, name}, grants: [capability]}`.
   The plugin must reply `{"jsonrpc":"2.0","id":0,"result":{}}` **during the
   same call**. A missing or error reply stops the plugin.
2. While active, the plugin receives notifications and responses.
3. Alas sends the notification `alas/deactivate` when the plugin is reloaded
   or restarted from Debug → Plugins…. Anything sent in reply is ignored.
   Deactivation on project close, disabling, and app quit is not wired up yet.

A plugin runs once per project. Its instances share nothing.

## Methods

| Direction | Method | Kind | Capability |
|---|---|---|---|
| Alas → plugin | `alas/activate` | request | none |
| Alas → plugin | `alas/deactivate` | notification | none |
| Alas → plugin | `workspace/changed` `{snapshot}` | notification, at most 2 per second | `workspace.read` |
| plugin → Alas | `workspace/snapshot` → `{snapshot}` | request | `workspace.read` |
| plugin → Alas | `worktree/switch` `{id}` → `{}` | request | `worktree.switch` |
| plugin → Alas | `log` `{level, message}` | notification | none |

`level` is `debug`, `info`, `warn`, or `error`. Unknown notifications and stray
responses are ignored.

### Snapshot

```json
{
  "worktrees": [{
    "id": "…", "branch": "main", "current": true,
    "dirty": { "files": 3, "conflicts": 0 },
    "sessions": [{
      "id": "…", "agent": "claude", "title": "…",
      "state": "running",
      "plan": { "completed": 2, "total": 5 }
    }]
  }]
}
```

- `state` is one of `running`, `awaiting_input`, `permission_request`, `idle`,
  or `unknown`.
- `dirty` is omitted until Alas has scanned the worktree.
- `plan` is omitted when a session has no plan.

## Capabilities

| Capability | Grants |
|---|---|
| `workspace.read` | `workspace/snapshot` and `workspace/changed` for the plugin's project |
| `worktree.switch` | `worktree/switch` to a worktree of the plugin's project |

## Errors

| Code | Meaning |
|---|---|
| `-32601` | Unknown method |
| `-32602` | Invalid params |
| `-32001` | Capability not granted |
| `-32003` | Action failed, for example an unknown worktree id |

## Limits

Exceeding any of these limits stops the plugin with a reason. The memory limit
is the exception: `memory.grow` just returns `-1`.

| Limit | Value |
|---|---|
| Execution per `alas_handle` call | 25,000,000 fuel units (about 50 ms) |
| Linear memory | 64 MiB |
| Message size, either direction | 1 MiB |
| `alas.send` calls per `alas_handle` | 64 |

A trap, a malformed message, or a memory range outside the plugin's memory also
stops the plugin. A stopped plugin can be restarted from Debug → Plugins….

## Example

See `plugins/samples/hello-workspace` for a Rust plugin that uses
`wasm32-unknown-unknown` and `serde_json`. Its `build.sh` builds it and installs
it into the plugins folder. You need `rustup target add wasm32-unknown-unknown`.
