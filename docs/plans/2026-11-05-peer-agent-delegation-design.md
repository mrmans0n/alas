# Agent delegation to paired peers

Status: proposed. No code exists yet. The user asked to extend what Alas has so
it covers the use case of T3 Code's Linked environments. They left the design to
the author, so the decisions below are the author's unless marked otherwise.

## Intent

Let an agent on one Mac hand work to another machine the user owns, and get the
result back in the same conversation. Today the user has to do this by hand: open
the peer view, start a session there, and carry the result back.

The typical case is a laptop agent sending heavy or long-running work to an
always-on Mac mini. Another is two working Macs, where one needs something only
the other has.

Prior art: [T3 Code's Linked environments](https://github.com/pingdotgg/t3code/blob/6328c8472255e9b93bd362af63ae0d3c17e2d540/docs/user/remote-access.md#L328-L362)
and [the discussion behind it](https://github.com/pingdotgg/t3code/discussions/15819).

## Goals

- An agent can discover a peer, start a child there, message it, wait on it, read
  it and stop it, using the existing delegation tools.
- The parent wakes with the child's result, as it does for a local child, including
  across a restart of either Mac.
- Each machine decides which peers' agents may use it. The default is no.
- A child never auto-runs unless both its parent and the target allow it.
- People can see where work came from, on both machines.

## Non-goals

- Copying a checkout or uncommitted changes between machines. Code travels through
  the git remote.
- Agents managing a peer's projects, settings, schedules, worktrees or sessions they
  did not start. T3 offers this at its "full access" level; Alas does not here.
- An agent linking a machine from a conversation. Pairing stays a human action in
  Settings or `alas-host pair`.
- Multi-user. All machines belong to one person, as in the
  [federation design](2026-09-19-multi-instance-federation-design.md).
- Protecting against malware running as the user on the source Mac, or sandboxing a
  child. See [Trust model](#trust-model).

## Anti-goals

The feature has failed, even if it works, if:

- A paired peer's agents can start work on a Mac that never opted in.
- A child auto-runs when its parent did not, or when the target did not allow it.
- A network outage or a target restart reports a healthy child as failed.
- A parent is woken twice for one result, or never woken.
- A child quietly works from older code than the parent assumed.
- The user's own peer view changes behaviour when the feature is off.

## Current state

Each of these was read in the code:

| Area | What exists | What it means here |
|---|---|---|
| `RemotePeerManager` | Outbound links, reciprocal pairing, key pinning | Transport and identity are done |
| `PeerHostChannel` | Host protocol requests matched by id, with a subscription; 60-second default timeout | The right client, but owned by `NativePeerHosts` in the app target |
| `NativePeerHosts.peersChanged` | Keeps a channel for every online peer, with or without the UI open | A background client can share it |
| Host protocol subscription | One per connection; a second subscribe replaces the first | There must be one channel per link, so share it |
| `HostCaller.remotePeer(deviceID:)` | Identity comes from the transport, never the wire | The right basis for the gate |
| `RemoteDevice` | `kind`, `peerServerId`, no scopes; re-pairing adds a new row | The access setting goes here |
| `RemotePeer.localDeviceId` | Links a peer to its inbound device; inbound-only peers on a host also get a record | Settings and the CLI can reach the device from a peer row |
| `ACPSessionOrchestrationCoordinator` | Turn outcomes, deferred background work, blockers, strict model checks, failure handling | The target can reuse all of it |
| `recoverDelegations()` | Re-attaches in-flight children and fails those whose worktree is not local | Reuse it on the target; peer records must skip it on the source |
| `delegations` schema | Currently version 4 | This work is version 5 |
| `followSession` | Refuses a session that is not loaded, and stops tracking revisions when unfollowed; revisions restart with the process | Not a reliable way to learn a turn's result. See decision 4 |
| `alas-host/main.swift` | Builds `RemotePeerManager`, never calls `connectAll()`; pair-back off | A headless host has inbound links only |
| `createWorktree` request | The client names the destination; the host does not fetch | The source cannot use it directly |
| `WorktreeCreateRequest.asksAboutRepoHooks` | Off for work a peer starts, so unapproved hooks are skipped | Already the behaviour wanted here |

## Decisions

### 1. Use the host protocol, under a new capability

The peer link carries two protocols that can create a session: the Remote protocol
and the host protocol. Use the host protocol. It has request ids, typed refusals and
`HostCaller`.

Gate on a new capability, `host.delegation.v1`. This is the only protection against
older hosts, which silently drop a frame they cannot decode, leaving the caller to time
out. A peer without the capability shows as `peer_outdated` in `agent_list`, and no
request is sent.

Add one family of requests rather than overloading the human-facing verbs:

```swift
case delegation(HostDelegationRequest)

enum HostDelegationRequest {
    /// The caller's access, projects matching `repository`, their worktrees, and agents.
    case discover(repository: String?)
    /// Records a child and starts it. Answers once the row exists.
    case start(HostDelegationStart)
    /// Queues a prompt for a child of this peer.
    case send(sessionID: String, prompt: String)
    /// One transcript page, in the shape `session_read` returns.
    case read(sessionID: String, offset: Int?, limit: Int?, maxChars: Int?)
    /// Each child's wait state, in the shape `session_wait` returns.
    case status(sessionIDs: [String])
    /// Cancels a child's running turn, as `session_interrupt` does.
    case interrupt(sessionID: String)
    /// Outbox entries after `seq`. Asking also acknowledges everything up to `seq`.
    case outbox(after: Int64)
}

struct HostDelegationStart {
    var childID: String          // minted by the source; repeats are idempotent
    var target: HostDelegationTarget
    var agentID: String
    var modelID: String?
    var reasoning: String?
    var role: String?
    var autoRun: Bool            // the parent's state; the target can only lower it
    var prompt: String
}

enum HostDelegationTarget {
    case worktree(WorktreeRef)
    case newWorktree(projectID: String, branch: String, base: String, expectedBaseSHA: String?)
}
```

`start` answers as soon as the row exists, with the checks it can make immediately:
the gate, project, worktree, agent, model and branch name. Worktree creation and fetching
continue in the background, and a failure there arrives as an outcome. Fetches and hooks
have no time limit, so waiting for them would trip the channel's timeout, and a retry would
collide with the worktree still being created.

The child's id is the same on both machines. The source mints it, writes its record,
then sends `start`. A repeat with the same id returns the existing child, so a retry after
a lost answer cannot start a second one.

### 2. The target owns consent

Add `agentAccess` to `RemoteDevice`, defaulting to `.off` for existing and new records:

| Value | Meaning |
|---|---|
| `off` | No new children and no new prompts |
| `ask` | Children run, and their permission requests wait for a person |
| `autoRun` | A child may auto-run if its parent was auto-running |

On every `.delegation` request, the caller must be `.remotePeer(deviceID)`, and that
device must exist with kind `.alasInstance`. `discover`, `start` and `send` also require
access other than `.off`.

`read`, `status`, `interrupt` and `outbox` keep working while access is off, so running
work can finish, be stopped and report back. Queued prompts and running turns finish.
This matches T3.

There is one switch, on the target, per peer. T3 requires a switch on both machines. Alas
does not add one on the source, because a second switch adds a failure mode without adding
protection for someone who owns both machines. It is easy to add later.

Re-pairing creates a new device, which starts at `.off`. A person consents again.

Surfaces:

- App: Settings > Remote > Peers, on each paired Mac: "Let agents on this Mac use this
  machine", with Off, Ask for approval and Allow auto-run. It acts on the device named by
  `RemotePeer.localDeviceId`. A peer without one shows the control disabled, with
  "Pair again to allow this".
- Headless: `alas-host peers agents <id|name|serverId> off|ask|auto`, through the running
  host like `peers remove`, using a new local-client-only `setPeerAgentAccess` request.
- `alas-host peers list` shows the value.

### 3. What a child may do

`effective auto-run = parent.autoRunEnabled && device.agentAccess == .autoRun`

The source reports the parent's state and the target only ever lowers it. It is read once
at `start`. No delegation request can answer a permission, question or plan: only a person
can, as today.

`send`, `read`, `status` and `interrupt` only reach children of the calling peer. The child's
row records the peer's `serverId`, and the check compares it with the device's `peerServerId`.
Ownership follows the server id so a re-pair does not orphan running children. Consent still
follows the device, so a re-pair alone grants nothing new.

A child's tool list removes:
`session_new`, `session_wait`, `session_interrupt`, `computer_*`, `vm_*`, `device_*`,
`preview_*`, `open`, `worktree_new`, `worktree_delete`, `worktree_switch` and `workspace_*`.

It keeps what it needs for its own work, such as `notify`, `pr_create` and reviews. The
restriction keys on the sentinel in `ALAS_PARENT_SESSION_ID`, because the existing
`BuiltInMCPToolScope` cases describe SSH relays, and peer children never run in SSH projects.
It must be applied in every place that enforces tools: the preamble, the router and the
Rust tool list.

Unapproved worktree-create hooks are skipped, which is the existing rule for work a peer
starts. An outcome notice tells the parent, because a worktree missing its setup can
otherwise look like a code problem.

### 4. The target decides when a turn ended; the source collects it

This is the core of the design.

The target stores the child as an ordinary row in its own `delegations` table, with
`parent_session_id` set to `peer:<serverId>`. That one choice lets the target reuse what
already works for local children: attaching a child with no open tab, recovery after a
restart, refusing nested delegation, hiding tools, strict model checks, deferring an outcome
while background work runs, blocker escalation and failure handling.

The one difference is where an outcome goes. Where the coordinator would enqueue a message
for a local parent (`enqueueOutcome`), a row whose parent is a peer writes to an outbox:

```sql
CREATE TABLE peer_outbox (
    seq              INTEGER PRIMARY KEY AUTOINCREMENT,
    peer_server_id   TEXT NOT NULL,
    child_session_id TEXT NOT NULL,
    message_id       TEXT NOT NULL UNIQUE,   -- the existing outcome-/blocker- id
    prompt           TEXT NOT NULL,          -- rendered as for a local parent
    kind             TEXT NOT NULL,          -- prompt or notice
    created_at       INTEGER NOT NULL
)
```

Every outcome kind travels this way, with its existing wake-or-notice choice: finished,
failed, cancelled, usage-limited, stopped, blocked and escalated. The rendered text names the
target machine.

The source collects like this:

1. A new event, `delegationOutboxChanged`, tells a subscribed peer that entries are waiting.
   The channel adds it to `subscribeAccepting`, and it goes only to the connection whose device
   matches the entry.
2. On that event, and whenever the channel subscribes, the source sends `outbox(after:)` with
   its stored cursor for that peer.
3. For each entry, in one transaction: compare-and-set the cursor forward, and enqueue a
   `ACPDelegatedMessage` to the parent using the existing inbox.
4. The existing delivery path takes it from there, including attaching a parent with no open
   tab.

Why this holds up:

- **Exactly one wake.** The cursor is durable and written with the enqueue. `message_id` alone
  would not be enough, because the inbox row is deleted on delivery.
- **No lease dependence.** Any instance sharing the profile may collect, and only the
  compare-and-set winner enqueues. This covers Alas Dev and the release app sharing data, and a
  parent whose tab is closed.
- **Restarts.** The outbox and cursor are stored on each side, and revision numbers are not
  involved. An outcome produced while the source was away waits for it.
- **Cost.** The source does not follow transcripts, so children are not kept loaded on the target,
  and past children cost nothing.

The target deletes entries up to the acknowledged `seq`, and all of a peer's entries when it is
forgotten.

Reporting: a child's final message is its report. The target's preamble replaces the "report with
`session_send`" sentence with: "This session was delegated from another machine. Your final message
is your report to the parent. It cannot be messaged in any other way." `session_send` to the sentinel
parent returns an error saying the same. `lastParentReportAt` stays nil, so finished turns take the
existing "finished without a report" path, which carries `lastAgentText`. That outcome's wording needs
a variant, because here it is the normal case and not a warning.

Turns a person starts on the target also produce outcomes, as they do for a local child. A local
parent gets those too, so this is consistent, but it should be checked by hand.

### 5. Records on the source

Schema version 5 adds one column to `delegations`, `peer_server_id`, plus a cursor table:

```sql
CREATE TABLE peer_delegation_cursors (
    peer_server_id TEXT PRIMARY KEY,
    seq            INTEGER NOT NULL
)
```

- `child_session_id` stays the primary key and matches the id on the target.
- `worktree_request` stays `.current(parentWorktreeId)` and `childWorktreeId` stays nil. The source
  has no local worktree or session for the child. A new enum case would stop older builds decoding
  the row.

On the target, version 5 adds `peer_outbox`, and the row's sentinel parent marks it as a peer's.
The peer's id and the "From" name are read from the parent value and the device record.

Every coordinator path that assumes a local child branches on `peer_server_id` first: `create`, `send`,
`list`, `read`, `wait`, `interrupt`, `readableSession`, `storedTurnState`, `markChildFailed` and
`recoverDelegations`. On the source, `recoverDelegations` skips peer rows, since there is nothing local
to recover. Paths that assume every parent is a real session (`loadDelegatedSessionParents`, the
`HostSessionSummary.parentID` field) must ignore the sentinel.

`session_search` covers local children only in this version.

### 6. Marking the origin

Show "From <Mac>" on the child's tab, its sidebar row and in the peer view. It comes from the row's
peer id, resolved through the device record, so the name is never taken from the wire. If the peer has
since been forgotten, show "From another Mac". Include it in `HostSessionSummary` as an optional field,
decoded as tolerantly as `shepherd`.

### 7. Choosing where the child runs

Tools gain one parameter, `peer` in MCP and `--peer <name|serverId>` in the CLI:

```sh
alas agent list --peer mini
alas session new --peer mini --agent codex --new-worktree fix/parser --prompt "…"
alas session new --peer mini --worktree fix/parser --prompt "…"
```

- `--peer` with the implicit current worktree is an error, because it means nothing on another machine.
- `agent_list` without `peer` adds a `peers` array: name, server id, link state and whether delegation
  is supported. That stays cheap, with no calls to the peer.
- `agent_list --peer` sends `discover` with the parent's normalized origin remote (`host/owner/repo`,
  credentials stripped). The target compares it with its projects' origins, reading git only when asked,
  so `ProjectSnapshot` does not change. The answer includes the caller's access, matching projects, their
  worktrees and available agents.
- `--project <id|name>` is needed when several projects match or the parent has no remote. No match is
  an error naming the peer's projects.
- The source resolves `--worktree` against the `discover` answer, with `AlasCLIWorktreeResolver`.
- The target picks a new worktree's destination from its own `worktrees.rootPath`.
- Model checks follow the local rule on the target: a model or reasoning value it cannot apply fails the
  child rather than falling back. `SessionsAPI.create`'s looser behaviour does not apply. The target also
  applies that function's admission and checkpoint-recovery checks.

### 8. Stale code fails loudly

For `--new-worktree` without `--base`, the source requires the parent's worktree to be clean, with `HEAD`
equal to its upstream, and that upstream on `origin`. Otherwise `session_new` fails and says to push first,
or to pass `--base`. It sends the bare branch name as `base` and `HEAD` as `expectedBaseSHA`.

The target fetches that branch explicitly from the remote it matched, because `fetchesBaseFirst` skips bare
names and swallows errors. It then creates the worktree from `<remote>/<branch>`. When `expectedBaseSHA` is
set, a failed fetch or a different SHA fails the child with a reason, so an always-on Mac with an old checkout
gets the current code or a clear refusal.

An explicit `--base` skips the source's checks and sends no expected SHA, but still fetches on a best-effort
basis. The target still refuses a branch that already exists at another commit than the base, since a worktree
would check out that branch and ignore the base. `--worktree` means the agent chose an existing checkout, so no check applies.

### 9. Outages are not failures

The child keeps running on the peer when the link drops, so its record is not failed.

- While the link is down, `session_wait` reports the child as `peer_unreachable` and settled, so a parent is
  never stuck. `session_send`, `session_read` and `session_interrupt` return an error naming the peer.
- `session_wait` otherwise asks `status`, again on `delegationOutboxChanged` and every few seconds, within
  its existing timeout.
- After 15 minutes offline with a child still unsettled at last sight, the parent gets one notice, not a wake,
  saying the child may still be running.
- When the channel subscribes again, the source pulls the outbox. Anything that ended meanwhile is delivered then.
- A child fails, with a wake, only on proof it is gone: `status` or `read` reports no such row, or the link
  became `.unauthorized`, or the peer was forgotten here. Those last two fail all of that peer's unfinished children.
- A parent that was archived or deleted should be handled as the inbox handles it for a local child (see
  [Verify while building](#verify-while-building)). The child is not stopped, because it may be doing useful work, and it
  remains visible on the target.

### 10. Layering

`AlasAgents` cannot import `AlasHostCore`, which depends on it. So:

- `AlasAgents` defines a small `ACPDelegationPeers` protocol with plain types, added to the coordinator's
  `Environment`.
- `AlasHostCore` implements it as `PeerDelegationClient`, using a closure that returns a peer's `PeerHostChannel`.
- `AppState+PeerHosts` installs that closure from `NativePeerHosts`, and forwards channel availability.
- `PeerHostChannel` gains a callback for `delegationOutboxChanged`.
- The target's handling lives in `HostProtocolServer` and a new `AlasHost+PeerDelegation.swift`.
- The coordinator gains an entry point for a peer's `start`, sharing `createChild` and the `.new` path. Its origin
  uses the target's project and worktree with the sentinel parent.

`swift test --package-path Packages/AlasCore` keeps working without the app build.

## Direction

| Source to target | This version | Why |
|---|---|---|
| App to app | Both directions | Pairing is reciprocal, so each side has a link and its own switch |
| App to headless host | Yes | The host serves `.delegation` over its inbound link |
| Headless host to a machine when the two can reach each other | Yes, in the last PR | Move channel ownership from `NativePeerHosts` to `AlasHostCore`, activate links on the host, and add `alas-host peers add`, because pairing with a host creates no link back. `peers add` is the ordinary two-way pairing: a Mac's server always pairs back and revokes the token if it can't, so the Mac must reach the host too and also gets a token for it |
| To a Mac the source cannot dial, or that cannot dial back | No | Needs requests sent back over the Mac's own connection, and pairing without a pair-back |

The last row is what's left of T3's "theirs here". It is a larger protocol change that needs its own design. Tailscale
covers the common cases through the row above it. A LAN may not for a host running as a launch agent: macOS may silently deny
its connections to LAN addresses, which is untested on this path.

The source's Remote must be on, as for any peer link.

## Trust model

A peer's token is a full controller credential. `.delegation` limits what an agent can do through Alas's tools, not
what that token can do. The protection covers an agent, including a prompt-injected one, acting through `session_new`
and friends. A process that extracts the token has the same reach as today. A scoped credential for agents, like T3's
separate session kind, would close this, and is the first follow-up to consider.

Child and outbox ownership rests on the server id a device claimed when it redeemed its pairing code, which redeeming does not prove. Someone holding a live pairing code and knowing another peer's server id could read that peer's children and drain its outbox, which would drop undelivered outcomes. This is accepted because a pairing code already grants a full controller credential. A signed challenge at redeem would close it, and belongs with the scoped credential above.

Tool scoping is not a sandbox. A child can run anything its permissions allow, with the target user's credentials. That
is why `autoRun` is a separate and explicit choice, and the Settings row should say so.

The source only sends over peers in `sessionCarryingPeers`, so an unverified link carries no delegation. That check
belongs on the source only: inbound-only records on a headless host never pin a key, and the target relies on the
device token.

Outbox prompts contain agent text from another machine and are delivered as prompts to the parent, as a local child's
are. A compromised target could try to steer the parent through them. Consent to delegate to a machine includes trusting
what it reports.

## Delivery

Five reviewable PRs, each usable on its own. The fifth, headless hosts as sources, is described under
[Direction](#direction):

1. **Target.** `agentAccess`, gate, capability, `.delegation` requests, sentinel-parent rows, outbox, `.peerChild` scope,
   preamble, Settings row, `alas-host peers agents`, "From" marker.
2. **Source.** `ACPDelegationPeers`, schema, `--peer` on `agent_list` and `session_new`, outbox collection and delivery, and
   `send`, `read`, `wait` and `interrupt`.
3. **Resilience.** Unreachable states, the offline notice, proof-of-gone failures, stale-code checks.
4. **Surface.** Child row and card on the source that open the peer session, a notification for blocked children that opens
   it too, a root preamble that mentions `peer` only when one is online with the capability, and updates to
   `docs/agent-delegation.md`, `docs/headless-host.md` and `docs/manual-test.md`.

## Testing

Following the repo's Testing policy, extend existing suites:

- Coordinator, against a fake `ACPDelegationPeers`: routing on `peer`, recovery skipping peer rows, unreachable versus gone.
- Coordinator on the target: each outcome kind reaches the outbox and not the inbox; `start` is idempotent.
- Store: v4 to v5 migration; the cursor's compare-and-set lets one of two collectors win; a redelivered entry does not wake twice.
- `HostProtocolServer`: the gate for each caller and access value, ownership refusal, and what still works while access is off.
- Pure functions, parameterized: effective auto-run, and remote normalization including stripped credentials.
- Real git: only the `expectedBaseSHA` refusal, reusing a template repository.

Manual, added to `docs/manual-test.md` because CI has no two-machine setup: delegate to a headless host, close the laptop during
a turn and reopen it after it ends, restart each side, revoke during a turn, turn access off during a turn, and re-pair with a
child running.

## Verify while building

These were not settled by reading the code. Each could change a detail:

1. **Turns on a child with no open tab.** That `childTurnCompleted` and `childBlocked` fire for a peer-started child on a headless
   host and in the app, including when the session is restored after a restart.
2. **The sentinel parent.** Whether anything else reads `parent_session_id` as a real session: hierarchy UI, archive cascades,
   parent lookups in `readableSession`. The parent's `nextPromptWorkCount` handling in `createChild` must tolerate no parent.
3. **Older builds on the same store.** How a build at schema 4 treats a store at 5, and how it treats a sentinel-parent row, since
   Alas Dev and the release app share data.
4. **Writer lease on the target.** When a second instance on the target has the profile open, which one runs the child, and whether
   the `start` path holds the lease.
5. **Agent never starting.** That a child whose agent cannot start (sign-in needed, not installed) produces a failure outcome through
   the existing path, rather than sitting idle with a queued prompt.
6. **Archived parents.** What the inbox does with a message for an archived or deleted parent, so a peer child's outcome behaves the
   same way and the cursor still advances.

## Calls for the reader to check

The user skipped design questions, so these are the choices most worth a second look:

- One switch on the target, rather than T3's switch on both machines.
- No access level above `autoRun`, so agents cannot touch anything they did not start.
- Links do not expire, unlike T3's 30 days, because peers already have explicit revocation.
- The final message is the report, rather than relaying `session_send` across machines.
- An unreachable child is never failed by a timeout alone.
- Peer children lose computer use, VM and device tools, which limits one interesting use of the feature: a host agent handing UI
  testing to a Mac.
- A headless host needs its own `alas-host peers add` to send work to a Mac. The two must reach each other, and pairing is two-way, so the Mac also gets a token for the host.
- That add keeps the Mac's existing access to the host, a narrow exception to "a re-pair starts at off", because the person at the host started it and access to the host is a separate decision.
