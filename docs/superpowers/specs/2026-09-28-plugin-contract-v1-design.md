# Plugin contract v1 (#1560 phase 2)

## Goal

A minimal, versioned contract that lets an independently built Wasm plugin run
inside Alas without app changes. It is shaped by the first real plugin we want
to ship: a **pixel-art office** that shows one character per worktree/session of
the current project, animated by what its agents are doing, in a center tab.

Phase 2 delivers the contract: manifest, discovery, trust, lifecycle, message
protocol, and capability enforcement. The office's canvas rendering is phase 4
and gets its own spec; this contract only has to leave room for it.

**Exit condition (from #1560):** a sample plugin loads through the documented
contract, an unsupported API version fails clearly, and a denied capability
cannot be used.

## Decisions already made

- **Runtime:** WasmKit, in-process, per-call fuel budget; no helper process
  (see the phase 1 comment on #1560).
- **Calling convention:** JSON-RPC 2.0 messages over linear memory. Component
  Model/WIT is deferred: it is an opt-in WasmKit trait and WASI Preview 2 is
  unfinished. Messages are shaped as records and tagged unions so a later WIT
  migration is mechanical.
- **Reference plugin language:** Rust (`wasm32-unknown-unknown`).
- **Office rendering (phase 4, informs this contract):** a canvas contribution:
  an RGBA framebuffer plus named regions `[{id, label, rect}]` used for hit
  testing, keyboard focus, and VoiceOver.

## Components

All new code lives in `Alas/Sources/Plugins/`.

| Unit | Responsibility | Depends on |
|---|---|---|
| `PluginManifest` | Decode and validate `plugin.json`. Pure. | Foundation |
| `PluginRuntime` | One WasmKit instance on a serial queue. Moves bytes in and out; enforces fuel, memory, message-size, and send-count limits. Knows nothing about Alas. | WasmKit |
| `PluginHost` | One per (plugin, project). Protocol state machine, capability checks, request routing, event delivery. | `PluginRuntime`, `PluginHostActions` |
| `PluginHostActions` | Adapter from plugin requests to existing Alas code: snapshot from `AgentSidebarRollupBuilder` and the worktree status stores; actions via `AlasActionService`. | AppState services |
| `PluginManager` | On `AppState`. Discovery, approvals, starting and stopping hosts as projects open and close and plugins are enabled or disabled. | all of the above |

The phase 1 prototype (`PluginPrototypeRuntime.swift`, `PluginPrototypeWindow.swift`)
is removed. Its runtime code moves into `PluginRuntime`, and its window becomes
**Debug → Plugins…**.

## Discovery and manifest

Plugins live in `~/Library/Application Support/Alas/Plugins/<folder>/`, one
folder per plugin, holding `plugin.json` and the wasm entry point. Symlinked
folders are followed, for development.

```json
{
  "id": "io.nlopez.pixel-office",
  "name": "Pixel Office",
  "version": "0.1.0",
  "api": 1,
  "entry": "plugin.wasm",
  "capabilities": ["workspace.read", "worktree.switch"],
  "contributes": { "tabs": [{ "id": "office", "title": "Office" }] }
}
```

Validation, in order. The first failure wins and is reported with the folder path:

1. `id`, `name`, `version`, `api`, `entry` are present and non-empty. `id` is
   reverse-DNS: lowercase `[a-z0-9.-]`, at least one dot.
2. `api` is in the host's supported set, which is `{1}` in v1. Failure message:
   `requires plugin API 2; this Alas supports 1`.
3. Every capability is known. v1 knows `workspace.read` and `worktree.switch`.
   An unknown capability rejects the plugin.
4. `entry` resolves to a regular file inside the plugin folder. No absolute
   paths and no `..` escapes.
5. Duplicate `id` across folders: both are rejected.

Unknown top-level fields are ignored, so newer manifests still load on older
hosts when their `api` is supported. `contributes` is parsed but inert until
phase 4.

## Trust

This reuses the `RepoHookTrust` pattern. The approval key is
`SHA256("alas-plugin-trust-v1\0" + manifest bytes + "\0" + wasm bytes)`.

- The first time a plugin is discovered, an approval sheet (modeled on
  `RepoHookApprovalSheet`) shows its name, id, version, and each requested
  capability in plain language.
- Approval stores `{id, hash, grantedCapabilities}`. In v1 the granted set is
  all of the requested capabilities. It is stored separately so that later
  versions can grant only some of them.
- If either file changes, the hash changes and the plugin needs approval again.
- An unapproved plugin is never instantiated.

## Protocol

Each message is one JSON-RPC 2.0 object, using the existing `JSONRPCEnvelope`,
`JSONRPCID`, and `JSONRPCError` from `ACP/Protocol/ACPMessages.swift`.

**Wasm ABI.** A module must export `memory`, `alas_alloc(len: i32) -> i32`, and
`alas_handle(ptr: i32, len: i32)`. It may import only `alas.send(ptr: i32, len: i32)`.
Any other import fails instantiation, so there is no WASI and no ambient
filesystem, network, environment, or clock access.

**Delivery.** Each Alas → plugin message is exactly one `alas_handle` call with
its own fuel budget. The host writes the message into a buffer it gets from
`alas_alloc`, and the plugin owns and frees that buffer. Messages the plugin
sends with `alas.send` during a call are copied out and **queued**. The host
processes them only after `alas_handle` returns, so the host never re-enters a
plugin. A response to a plugin request is delivered in a later `alas_handle`
call.

### v1 methods

| Direction | Method | Kind | Capability |
|---|---|---|---|
| host → plugin | `alas/activate` `{api, project: {id, name}, grants: [String]}` | request; plugin must respond within the same call | none |
| host → plugin | `alas/deactivate` | notification | none |
| host → plugin | `workspace/changed` `{snapshot}` | notification, coalesced to at most 2 per second | `workspace.read` |
| plugin → host | `workspace/snapshot` → `{snapshot}` | request | `workspace.read` |
| plugin → host | `worktree/switch` `{id}` → `{}` | request | `worktree.switch` |
| plugin → host | `log` `{level: "debug"\|"info"\|"warn"\|"error", message}` | notification | none |

**Snapshot.** Always the whole project. It is small, and one format means no
diff drift.

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

- `state` is `AgentSidebarState` in snake_case: `running`, `awaiting_input`,
  `permission_request`, `idle`, `detached`, `unknown`.
- `plan` is omitted when a session has no plan.
- `dirty` is omitted while the worktree status is still `unknown`.

**Error codes.** `-32601` unknown method. `-32602` invalid params.
`-32001` capability not granted. `-32002` too many pending requests.
`-32003` action failed; the message carries the `AlasActionService` error text.

## Lifecycle

States of one `PluginHost`: `loaded → activating → active → deactivating → stopped`,
plus `failed(reason)` reachable from any running state.

- **Activate.** The host sends `alas/activate`. The plugin must send a success
  response to it before `alas_handle` returns. If it sends no response, or an
  error response, the host moves to `failed`.
- **Active.** Events and responses are delivered. If the plugin holds
  `workspace.read`, a `workspace/changed` notification is sent right after
  activation and then on each coalesced change.
- **Deactivate.** Happens when the project closes, the plugin is disabled, the
  approval is revoked, or the app quits. The host sends `alas/deactivate` with a
  normal fuel budget, then drops the instance whatever the outcome, along with
  every queued message and pending request.
- **Failed.** Caused by a trap, fuel exhaustion, a malformed envelope, a guest
  memory range out of bounds, or exceeding the message-size or send-count limit.
  The instance is dropped and the reason is logged. The plugin's surface (the
  Debug → Plugins list in phase 2; its tab in phase 4) shows
  `Plugin stopped: <reason>` with a Restart action. Restart creates a fresh
  instance and activates it again.

Ownership: a host exists while its project is open in Alas and the plugin is
enabled and approved. Hosts for different projects share nothing; each has its
own instance and memory.

## Capability enforcement

- One table in `PluginHost` maps each method to its required capability. It is
  checked against the **granted** set, not the manifest's requested list.
- A request without the grant gets `-32001` and has no side effects. The plugin
  keeps running.
- Events that need a capability are never delivered without the grant.
- A malformed JSON-RPC envelope is a protocol violation and moves the host to
  `failed`. A well-formed request with bad params gets `-32602`.

## Limits

These are constants in v1.

| Limit | Value | On exceed |
|---|---|---|
| Fuel per `alas_handle` call | 25,000,000. That is about 50 ms optimized; unoptimized (Debug) WasmKit is about 400× slower. | `failed` |
| Linear memory | 64 MiB, or the module's declared maximum if lower. Enforced with `Store.resourceLimiter` (currently `@_spi(Fuzzing)`). | `memory.grow` returns −1; the plugin decides what to do |
| Message size, either direction | 1 MiB | `failed` |
| `alas.send` calls per `alas_handle` | 64 | `failed` |
| Pending plugin → host requests | 32 | `-32002`; the plugin keeps running |

The host validates every guest `ptr`/`len` itself before touching memory,
because WasmKit's buffer accessors `precondition` on out-of-bounds access.

**Threading.** Snapshots are built on the main actor from existing observable
state, encoded there, and handed to the plugin's queue as bytes. All WasmKit
execution happens on the plugin's serial queue. Results come back to the main
actor only to apply host actions, which go through `AlasActionService`.

## Testing

Tests follow the AGENTS.md testing policy.

- **`PluginManifestTests`:** one parameterized test over the validation failures
  (missing field, bad id, unsupported api, unknown capability, escaping entry
  path) and one test that unknown fields are ignored.
- **`PluginHostTests`:** real WasmKit with small WAT fixtures, in-memory.
  - The activation handshake succeeds; a plugin that sends no activate response
    fails.
  - A denied capability returns `-32001` and the host stays `active`.
  - One parameterized failure test: trap, out of fuel, malformed JSON, oversized
    message, too many sends. Each ends in `failed` with a reason.
  - Messages sent during a call are processed after the call returns, not
    re-entrantly.
  - Deactivation drops pending requests; a response that arrives later is
    ignored.
- **Trust:** changing the wasm bytes changes the hash and requires approval again.
- **Snapshot mapping:** representative rollup rows and dirty state produce the
  expected JSON.
- No tests for views or the approval sheet.

## Sample plugin and docs

- `Examples/plugins/hello-workspace/` is a Rust crate targeting
  `wasm32-unknown-unknown`, using only `serde` and `serde_json`, with hand-written
  ABI glue. On activate it requests `workspace/snapshot` and logs a summary, and
  it logs again on each `workspace/changed`. It declares only `workspace.read`
  and sends one `worktree/switch` request to show the `-32001` path.
- A `build.sh` next to it builds the crate and installs it into the plugins
  folder. It is not in CI yet; host tests use WAT so CI needs no wasm toolchain.
- `docs/plugins/api-v1.md` is the authoring reference: manifest, ABI, framing,
  lifecycle, methods, snapshot schema, capabilities, limits, error codes.

**Manual exit check.**
1. The sample installs, is approved, activates, and logs snapshot summaries.
2. Editing its manifest to `"api": 2` shows `requires plugin API 2; this Alas supports 1`.
3. The denied `worktree/switch` returns `-32001`, and the plugin keeps running.

## Out of scope

- Canvas, `tick`, and clicks; tab contribution rendering (phase 4).
- The Rust SDK crate and a CI build of the sample (phase 3).
- The install UI, real enable/disable settings, and a log viewer (phase 3).
- Network capabilities, partial grants, signing, remote workspaces, Component Model.

## Risks

- **WasmKit pinned to `main`.** Fuel is unreleased, so the pin has to move to a
  tagged release when one includes it.
- **`resourceLimiter` is SPI.** Upstream a request to make it public. The
  fallback is to require modules to declare a memory maximum no higher than the
  cap, and reject them at load otherwise.
- **A WasmKit crash takes down Alas.** Accepted for v1. The helper process is the
  mitigation if this happens in practice.
