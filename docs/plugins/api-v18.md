# Plugin API v18: native stacks and project mutation ownership

API 18 adds project-scoped native gg inventory and presentation. Existing API 4
through 17 plugins remain supported. No stack endpoint executes a confirmed
mutation on behalf of a plugin.

All fields use camelCase. Requests and notifications use JSON-RPC 2.0.

| Method | Capability | Params | Result |
| --- | --- | --- | --- |
| `stacks/list` | `workspace.read` | `{ refresh: boolean }` | `{ inventory: StackInventory }` |
| `stacks/open` | `workspace.read` | `{ stack, fingerprint, action, entry? }` | `{ opened: true }` |
| `stacks/acquire` | `process.exec` | `{}` | `{ token: string }` |
| `stacks/release` | `process.exec` | `{ token: string }` | `{ released: true }` |

`StackInventory` has `complete`, `busy`, `stacks`, optional `fetchedAt` in epoch
milliseconds, optional `error`, and optional `applicable`. `applicable: false`
means the host explicitly rules native workflows out for this execution context
(SSH/folder projects or a disabled/unavailable gg integration); it does not mean
discovery succeeded. Incomplete inventory with no applicability flag remains
unknown and cannot authorize generic writes. Non-applicability still retains
known native stacks as read-only dependencies. Failures preserve previously known stacks
as incomplete data. Cached inventory becomes stale after native changes or 30
seconds. Mutation decisions require a successful refresh.

Each stack has opaque `id`, `name`, `base`, provider `host` and `repo`, optional
`worktree`, `fingerprint`, `complete`, ordered `entries`, supported `actions`, and
optional `unavailableActions`. The latter maps action names to refusal reasons.
Saved local metadata or remote-only discovery may supply `reviewNumbers`, an
unordered membership list. For local stacks without numbered entries, an omitted
list means the published mapping is unknown; an explicit empty list confirms no
saved published mapping. Unknown local mapping prevents generic provider writes.
Those placeholders have empty entries and base, `complete: false`, and no native
actions because this gg schema cannot verify order, heads, base, or fetch success.
They remain visible dependencies and cannot become executable ordered chains.
Failed or unavailable refreshes also retain previously known review numbers and
identities as stale data, with no native actions. A complete successful refresh
can replace that cached membership. Provider/repository identities remain separate.
Entries have `id`, full `sha`, one-based `position`, optional review `number`,
`title`, and optional `state`. Unpublished entries stay visible. Incomplete
review mapping disables landing while allowing supported Sync/Rebase actions.
Unintegrated work reported outside gg's ordered entries remains incomplete. Its
known head/count appears in unavailable-action reasons; inbox mutation actions
stop until it is resolved in native gg. Open remains available. Native preflight
also refuses unintegrated commits introduced after the confirmation was shown.
SSH projects return an explicit unavailable inventory; the host never runs local
gg against their remote paths.

`action` is `open`, `sync`, `rebase`, `land`, or `landThrough`. The fingerprint
pins project/provider identity, worktree, final base, every ordered entry ID,
head SHA, and review number. `land` always selects the last member, even when
an `entry` is supplied. `landThrough` requires an entry in that stack and selects
its prefix. Stack and entry identities are project-scoped and cannot be paths
or arbitrary commands. Stack/entry strings are limited to 1024 UTF-8 bytes;
fingerprints to 256 bytes. Invalid requests return `-32602`; stale, unsupported,
unknown, or busy requests return `-32003`. Capability refusals use `-32001`.

`stacks/open` refreshes and validates scope before presenting the owning
worktree's native workflow. It only opens UI. The user must confirm Sync,
Rebase, landing, or creating/reusing a stack worktree in native UI. Landing
retains native preflight, project locking, streaming progress, waiting,
cancellation, and no-clean behavior. Missing worktrees require a separate native
follow confirmation before their other actions become available.

Use `stacks/acquire` before individual, bulk, or generic stack writes and release
in a `finally` block. Tokens are opaque, limited to 128 UTF-8 bytes on release,
and belong to exactly one plugin instance and project. Foreign, stale, and
already released tokens fail. Acquisition fails while native gg or another
plugin owns the project, including other linked worktrees. Releasing or ending
an instance closes its reservation to new processes, but ownership remains until
all its active processes settle. Shutdown terminates those processes through the
existing stop/kill lifecycle; it cannot make an in-flight write safe to overlap.
An uncertain remote startup has a specific unknown-settlement error in inventory
and acquisition refusals. Plugin teardown finishes without waiting for remote
reconciliation. The gate keeps the reservation until a terminal process result
is observed; no timeout clears it. An uncertain remote spawn's terminal helper
claim is retained so a delayed retry cannot launch that command again. A remote
outage can therefore leave this project busy until reconciliation succeeds.
A helper refusal before creating a supervisor (`-32055`) settles that launch
attempt. It cannot settle an earlier lost spawn reply; those reservations still
require terminal reconciliation. Legacy `-32050` startup failures remain unknown.

Alas sends `stacks/changed {}` to active API 18 plugins with `workspace.read`
when native operation ownership or project/worktree state changes. The SDK
exposes this invalidation as `stacksChanged`; clients refresh inventory rather
than treating the notification as a completed merge.
