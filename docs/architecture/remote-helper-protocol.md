# Remote Helper Protocol v1

`alas-helper serve` runs on a remote host as a long-lived stdio process launched
over batch SSH:

```text
ssh <batch opts> <host> /bin/sh -c '... "$HOME/.alas/bin/alas-helper" serve'
```

The app speaks JSON-RPC 2.0 using one newline-delimited JSON object per frame on
stdin/stdout. Stderr is diagnostic-only. The helper opens no TCP listener and
needs no SSH port forwarding. Its only sockets are the private Unix sockets of
the [visual MCP relay](#visual-mcp-relay).

## Lifecycle

The app owns one `RemoteHelperClient` actor per SSH host through
`RemoteHelperClientPool`. A client starts lazily on the first request and shuts
down after ten idle minutes when there are no active subscriptions. Active
subscriptions keep the helper alive; if a helper crash forces a restart, the
client replays those subscriptions before sending the next caller request. If
the SSH channel exits with status `255`, the app reports a host connection
failure through `RemoteHostStatusStore`. Other exits are treated as helper
crashes: in-flight requests fail with a fallback-capable client error, but the
host is not marked offline. Watch consumers are notified immediately so they
resume their pre-helper polling cadence; the next retry starts a new helper
channel and replays the active subscriptions. Open visual relay routes also keep
the helper alive and are re-registered on that replay; relayed MCP frames never
are.

## Handshake

Request:

```json
{"jsonrpc":"2.0","id":1,"method":"hello","params":{"clientName":"Alas","protocolVersion":1}}
```

Result:

```json
{
  "name": "alas-helper",
  "protocolVersion": 1,
  "binaryVersion": "0.6.0",
  "capabilities": {
    "watchKinds": ["files", "git"],
    "fs": {"read": true, "write": true, "stat": true},
    "ping": true,
    "proc": true,
    "sessionCoordination": 1,
    "visualMCPRelay": 1,
    "remoteMCPTools": 1
  }
}
```

`alas-helper version` prints the same `{name, protocolVersion, binaryVersion}`
handshake used by capability probing and installer checks.

## Methods

`ping`

Params: `{}`  
Result: `{"ok": true}`

`watch/subscribe`

Params: `{"root": "/srv/repo", "kinds": ["files", "git"]}`  
Result: `{"subscriptionId": "1"}`

The helper canonicalizes `root`, registers it as an allowed containment root,
and starts a native recursive watcher. Linux uses inotify and macOS uses
FSEvents through `notify`. For git subscriptions the helper also resolves and
watches the common git directory, including when it lives outside the worktree.

`watch/unsubscribe`

Params: `{"subscriptionId": "1"}`  
Result: `{"ok": true}`

`watch/event`

Notification:

```json
{
  "jsonrpc": "2.0",
  "method": "watch/event",
  "params": {
    "subscriptionId": "1",
    "root": "/srv/repo",
    "kind": "files",
    "paths": ["/srv/repo/README.md"]
  }
}
```

`files` events contain changed paths under the worktree root. `git` events are
limited to state that invalidates project or changes-pane data: main or linked
worktree HEAD and index changes, merge/rebase/cherry-pick/revert state, worktree
topology changes, branch refs, and packed refs. Transient lockfiles and
unrelated git metadata are ignored. Events are grouped by subscription and kind
for 250 ms before the helper sends one notification.

`fs/read`

Params: `{"path": "/srv/repo/README.md", "offset": 0}`  
Result: `{"kind":"file","contentBase64":"Li4u","mtime":1783940000.25}`

File bytes are base64 encoded so images and other binary files use the same
operation. Non-file results use `kind` values `missing`, `directory`, `symlink`,
or `unreadable`.

`fs/write`

Params:

```json
{"path":"/srv/repo/README.md","content":"...","expectedMtime":1783940000.25,"expectedContent":"old content"}
```

Result: `{"mtime": 1783940100.5}`

`expectedMtime` and `expectedContent` are optional. When content is provided it
is the authoritative baseline, avoiding false conflicts when a preceding exec
read only observed integer-second mtimes. Otherwise the mtime is the baseline.
When the selected baseline differs, cannot be read, or the target no longer
exists, the helper returns a conflict error instead of writing.

`fs/stat`

Params: `{"paths": ["/srv/repo/README.md"]}`  
Result:

```json
{
  "entries": [{
    "path": "/srv/repo/README.md",
    "exists": true,
    "isDirectory": false,
    "isFile": true,
    "size": 1234,
    "mtime": 1783940000.25
  }]
}
```

`fs/line-counts`

Params: `{"root":"/srv/repo","paths":["README.md","src/main.swift"]}`
Result: `{"entries":[{"path":"README.md","lineCount":42}]}`

Missing and non-regular files are omitted. The request is not subject to the
exec fallback's argv cap.

`fs/list`

Params: `{"path":"/srv/repo/src"}`
Result: `{"entries":[{"name":"main.swift","isDirectory":false}]}`

`search/start`

Params:

```json
{
  "root": "/srv/repo",
  "query": "needle",
  "caseSensitive": false,
  "wholeWord": false,
  "regex": false
}
```

Result: `{"searchId":"1"}`

The helper runs `rg --json` and emits each output line as a `search/event`
notification. It finishes with `search/complete`, including ripgrep's exit code,
bounded stderr, and whether the operation was cancelled.

`search/cancel`

Params: `{"searchId":"1"}`
Result: `{"ok":true}`

Cancellation kills the server-side ripgrep child without closing the helper
channel.

## SSH ACP session coordination

SSH ACP writers require both `proc: true` and `sessionCoordination: 1`. Older
helpers remain usable for filesystem and discovery operations, but cannot open
a writable SSH ACP attachment. Fenced process mutations revalidate this
capability after a helper connection restarts.

The helper canonicalizes `key.worktreePath` on the remote host. Bound sessions
are identified by that path, `key.agentId`, and the opaque
`key.remoteSessionId`, not by a Mac's local session UUID. Before `session/new`
returns an ID, the proposed process ID identifies the provisional record.
Delegated children have separate records and leases.

`lease/observe` looks up bound sessions. An unbound `(worktree, agent, null)` is
not unique; callers retain the provisional process locator and fence returned
by claim until binding.

| Method | Params | Result / effect |
| --- | --- | --- |
| `lease/claim` | `key`, `owner`, `proposedProcId`, `requestedToken`, optional `previousFence` | Current `lease` and an optional writer `fence`; a fresh foreign owner gets no fence |
| `lease/seize` | Same as claim | Explicit takeover with a new token |
| `lease/bind` | `fence`, `remoteSessionId` | Binds the provisional record without changing its actual process locator |
| `lease/heartbeat` | `fence`, `status` | Renews the writer using remote time and records idle/busy status |
| `lease/observe` | `key` | Current lease, or null |
| `lease/release` | `fence` | Relinquishes ownership without deleting history |
| `lease/delete` | `fence` | Deletes the record and replica; requires current, fresh ownership |
| `replica/publish` | `fence`, `batchId`, `entries`, `status` | Idempotent batch publication with a monotonic revision |
| `replica/read` | `recordId`, `afterRevision`, optional `pageToken` | Entries, pinned `cutoffRevision`, and optional `nextPageToken` |
| `replica/cancel` | `pageToken` | Releases a pinned read |

`owner` contains the Mac's persisted `serverId` and the Alas `instanceId`.
The server identity exists independently of enabling the WebSocket server.
A fence contains `{recordId, token}`. Replacing an attachment within the same
owner must present its `previousFence` and rotate the token; knowing the owner
identifiers alone does not authorize replacement.

Leases expire after 60 seconds by the helper's clock; clients heartbeat every
5 seconds. SQLite write transactions serialize arbitration across helper
processes. For associated processes, `proc/spawn`, `proc/write`, and `proc/kill`
require `leaseFence`, and the authority check and process mutation share that
transaction. `expectedStdinOffset` still deduplicates retries but does not grant
authority. Reading or attaching to output does not grant stdin authority.

Helper startup serializes WAL and schema initialization with
`remote_leases.open.lock`. The lock uses a separate inode from SQLite's
byte-range locks and remains on disk so waiting helpers share the same inode.
Normal arbitration still uses SQLite transactions.

An ordinary claim of an ownerless or expired foreign-Mac lease retires its old
process inside that write transaction before committing the new owner and token.
Cleanup failure does not grant ownership. The next fresh spawn resets private
protocol offsets; same-Mac reconnects preserve intentional process reuse.

After a successful claim or takeover, the manager starts heartbeats before
importing the remote replica. Long or paused imports keep both the local
reservation and remote ownership fresh. Heartbeats are scoped to the current
local lease token, so a canceled predecessor cannot renew a replacement lease.

Explicit takeover seizes first and imports the last committed remote replica.
It does not wait for predecessor acknowledgement; Mac-local writes whose
publication is unacknowledged are outside that shared cutoff.

Mirrors report remote activity only while the observed foreign lease is fresh;
an expired owner cannot keep a stale busy indicator alive.

Each supervised generation owns a fresh per-PID exit inode opened before PID
publication. A late predecessor writes only its retired inode, never a reused
PID's exit record or a path being removed by process cleanup.

Replica entries are keyed by kind and item key. Their base64 payload is opaque
to the helper; null payloads are tombstones. Pages use one pinned SQLite
snapshot, so concurrent edits cannot change an in-progress cutoff. Page tokens
expire after 60 seconds and are lost when their serving helper exits. Clients
discard incomplete staging and retry from the last committed revision.

Readers transactionally import complete pages into their own local SQLite
store. Portable relationships are mapped to local IDs; user text and tool
payload bytes are not path-rewritten. Composer drafts, process offsets, MCP
registrations, and broker credentials remain local. Same-Mac mirrors keep the
existing shared-SQLite fast path. Observing a foreign or ownerless lease clears
that shortcut, so a takeover and release between polls cannot hide a newer
remote transcript. Release, helper restart, and local Forget retain the remote
replica; an authorized agent-history deletion removes it.

Replicated recovery state is authoritative on both initial and subsequent
imports. A mirror remains recovery-pending until the writer publishes completion;
takeover must not release queued prompts while that state is pending.

Context recovery retires the old fenced process before replacing its durable
local identity. One local transaction records the randomized recovery process
locator, clears the old remote session ID, disables predecessor export, and
marks recovery pending before the provisional claim or spawn. Cold attachment,
takeover, and orphan cleanup reuse that locator. A successful native bind stores
the bound identity and clears the locator under the local lease fence; a lost
bind response is reconciled from the next claimed native lease. The locator
remains Mac-local, and the original remote transcript is retained.

One-time MCP guidance is portable conversation state: queued text and the sent
flag survive takeover. Agent-reported authentication status is also replicated,
including clearing it, so mirrors refresh sign-in state without their own attach.

On writer stand-down, Alas stops the runner and flushes its queued writes
before retiring the local lease fence. It cannot publish under a lost remote
fence. During manager disposal, remote heartbeats and publication stay alive
while sessions wait for sequential teardown and their final replica drain.
Each heartbeat ends when its lease is released. The coordinator shuts down once
the disposed manager has no owned leases, including after an in-flight
attachment releases its lease.

After a publication failure, final flush reconfirms the same fence and drains
pending batches before any fenced kill or release. If synchronization remains
unavailable, Alas retains the local outbox and leaves remote ownership to expire
instead of claiming a clean release.
Ownership release also requires a successful process kill. A failed kill leaves
the remote record owned, and a failed release leaves the active coordinator's
fence available for immediate reclaim or retry rather than waiting for expiry.

Cold-start orphan cleanup retains each ephemeral session's local and remote
identity until cleanup succeeds. It reserves the stale local row, ordinarily
claims remote ownership, then performs fenced process kill and record deletion
before deleting the local row under that reservation. Fresh local or remote
owners block cleanup. Helper, kill, or deletion failures retain the row for
retry; a failed kill also retains remote ownership. Parent history is untouched.

SSH side-session dismissal records a local cleanup-pending marker before
teardown. Failed close, kill, or deletion retires the local runner but keeps the
hidden row for immediate cold cleanup, even when its activity timestamp is
fresh. The marker does not bypass live ownership or promotion to a normal
session, and stale metadata writes cannot clear it.

## Visual MCP relay

SSH ACP sessions get a subset of the built-in Alas MCP server's tools through
the helper. Helpers advertise the relay with `visualMCPRelay: 1`; Alas gates on
that value, not on the binary version, and an older helper leaves the tools
unavailable without sending it an unknown method.

A helper that also advertises `remoteMCPTools: 1` waits long enough for
`pr_create`, so Alas relays `visual_show`, `pr_create`, and `pr_status` and runs
`alas mcp --remote` for the session. Behind a helper without it, and for
Workspace Checkout sessions, which the PR shepherd does not support, Alas relays
`visual_show` only and runs `alas mcp --visual-only`. The relay itself is the
same in both cases.

```text
remote ACP agent
  -> stdio: alas-helper mcp-proxy --state-dir <state dir> --record-id <record>
  -> current route for the record, read from the remote session registry
  -> one framed exchange over that route's private Unix socket
  -> `mcp/request` notification over the existing SSH channel
  -> the owning Mac, which runs `alas mcp --remote` (or `--visual-only`) for the session
```

The agent's MCP configuration holds only the helper path, its absolute state
directory, and the stable remote session `recordId`. It never contains a Mac
command, socket, URL, credential, local session ID, fence token, relay ID, or
socket path, so a retained proxy keeps working across reconnects and takeover.
The proxy resolves the route again for every frame and never replays one.

| Method | Direction | Params | Result / effect |
| --- | --- | --- | --- |
| `mcp/register` | app → helper | `fence`, `relayId` | Binds a private socket, then publishes it as the record's route. Returns `recordId`, `relayId`, `proxyCommand`, `proxyArgs`, and `relayProtocolVersion: 1` |
| `mcp/request` | helper → app (notification) | `requestId`, `recordId`, `relayId`, `frameBase64` | One MCP frame from the proxy; the outer envelope is a notification even for an inner request |
| `mcp/complete` | app → helper | `fence`, `relayId`, `requestId`, and exactly one of `responseBase64` (response bytes), `responseBase64: null` (inner notification), or `error: {code, message}` | `{"ok":true}` |
| `mcp/unregister` | app → helper | `fence`, `relayId` | Compare-and-delete of the route; `{"ok":true}` |

Each registration binds a fresh socket, mode 0600, in a new mode-0700
directory under the system temporary directory, with a short random name that
fits Darwin's socket path limit. The helper generates the path; the app never
supplies one. The `remote_mcp_routes` table maps a record to its current relay
ID, fence token, and socket path. A route is usable only while its token is the
record's current, fresh lease token, so a takeover invalidates the old route at
once even if the old helper is still running. Registration, frame forwarding,
and completion all revalidate the fence. Unregister deletes only a row matching
record, relay ID, and token, so stale cleanup cannot remove a replacement.
Deleting the remote session deletes its route. No HTML, request, or response is
stored.

Socket frames are `ALASMCP1 <decimal byte count>\n<exact bytes>`, one exchange
per connection, with the same framing for the reply. An empty reply
acknowledges an inner notification. Raw frames are at most 4 MiB; relay
envelopes at most 6 MiB. Lengths are checked before allocation. Header reads
time out after 5 seconds, body reads after 10, the helper's wait for a
completion after 130, and the proxy's wait for a reply after 135. These sit
just above the 120 seconds `alas mcp` waits for `pr_create`; every other call
gives up locally after 30. Each record has
at most two exchanges in flight and each `serve` process at most eight; excess
work fails at once. Frames are opaque and never path-rewritten.

When the relay fails, an inner request gets
`{"jsonrpc":"2.0","id":<original id>,"error":{"code":-32000,"message":"Alas relay unavailable; the call's outcome is unknown"}}`,
and an inner notification gets no reply. A visual may already have been saved,
or a PR opened, when its response is lost; the agent sees a failure or an
unknown outcome, never a fabricated success, and Alas does not retry the call.
A repeated `pr_create` waits for the first and adopts the PR it opened.

On the Mac, the session manager prepares the route after confirming remote
authority and before sending the session's MCP servers, and revokes it when that
attachment ends: reconnect, stand-down, takeover, detach, deletion, or manager
disposal. Each relayed request is checked against the attachment that prepared
it and that attachment's fence, and `visual_show` confirms writer authority
again before appending. `pr_create` and `pr_status` resolve the session's
worktree as for a local session; on an SSH project their git and `gh`/`glab`
commands run on the remote host. The Mac-side bridge gives each relayed request a unique
backend ID and restores the caller's ID in the response, so proxies whose MCP
IDs collide cannot receive each other's results. A completion reaches only the
registration and helper generation that delivered its request. When the helper
exits, pending exchanges are dropped and routes re-register under still-current
fences with fresh relay IDs.

Filesystem permissions and fences protect against other Unix users and stale
Alas instances. They do not isolate processes running as the same remote user.

## Security

Filesystem RPCs only serve paths under registered roots. `watch/subscribe` resolves
the requested root with the remote host filesystem. Reads, stats, listings,
line counts, and searches
resolve existing target paths and require them to be under a registered root.
`fs/write` resolves the parent directory and requires that parent to be under a
registered root before writing. If the final path already exists as a symlink,
the helper rejects the write. Writes use a sibling temporary file plus rename,
preserving the existing target mode when replacing a file, so hardlinks inside a
registered root are replaced instead of mutating an outside shared inode. This
catches symlink and hardlink escapes on the host that lexical path checks cannot
see.

## Errors

JSON-RPC parse errors use `-32700`; invalid requests and params use `-32600` and
`-32602`; missing methods use `-32601`. Helper-specific errors use the `-320xx`
range:

| Code | Meaning |
| --- | --- |
| `-32010` | invalid subscription root |
| `-32020` | filesystem operation failed |
| `-32021` | path does not exist |
| `-32022` | no containment roots have been registered |
| `-32023` | path is outside registered roots |
| `-32025` | path is not a regular file |
| `-32030` | expected content or mtime baseline did not match |
| `-32080` | remote session storage failed |
| `-32081` | remote session lease was lost or expired |
| `-32082` | remote session identity conflicts |
| `-32083` | replica page token expired or is unknown |

The visual relay reuses `-32081` for lost authority, `-32602` for malformed
parameters, and `-32000` for an unavailable, busy, or timed-out relay.
