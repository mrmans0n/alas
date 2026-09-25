# Native peer sessions design

## Purpose and scope

Show verified peers' sessions in the macOS app, let the user read and drive a
selected peer session through the existing gateway, and include live peer
requests in attention counts. This is the native half of federation rollout
step 4 and GitHub issue #1409. It consumes the existing
`FederatedSessionsProvider`; it changes no wire messages, peer routing, or web
client behavior.

The feature is active only while Remote and `federationEnabled` are on. With
the flag off, the left sidebar, center selection, attention count, and peer
subscriptions retain their current behavior.

## Placement and selection

The left workspace sidebar gains a Peers section outside the space-specific
project and checkout tree. This section appears on every space, once, so a
peer session cannot be mistaken for a local worktree session. Each peer is a
collapsible group identified by `serverId` and labeled with its current name.
The group shows its attention count. Online groups show their cached
`RemoteSessionSummary` rows with agent, title, status, and worktree name as
display metadata. Row identity and selection use the namespaced session ID;
the peer's `projectId` and `worktreeId` are never used to find a local owner.

Selecting a peer row opens a dedicated peer view in the center of the current
window. The app remembers the previous local center selection and returns to
it when the peer view closes or a local workspace item is selected. The peer
view does not create a local `Tab`, because `Tab` and `CenterPaneView` are
currently owned by a worktree or checkout. Selecting another peer row changes
the center selection and transfers the transcript subscription. At most one
peer session is selected in this window. The right pane remains tied to the
last local worktree and must not present peer data as that worktree's data.

## Native adapter and data flow

An app-owned, observable adapter attaches one `FederatedDownstream` to
`FederatedSessionsProvider` while the native feature is enabled. It reads
`peerSessionSummaries` and `RemotePeerManager.helloPeers` to build a single
sidebar snapshot keyed by `serverId`. Its downstream's list-change callback
refreshes the rows; peer-availability changes refresh group names and states
as well as rows. The adapter must not infer online status from a nonempty
cached list. Provider reconciliation removes rows when a peer stops carrying
sessions; forgetting removes the peer group entirely.

The adapter routes a selection's `subscribe`, `unsubscribe`, `fetchOlder`, and
drive messages through `FederatedSessionsProvider.route(_:from:)`. It consumes
the forwarded transcript snapshot and delta sequence using the existing
epoch/revision rules, applies message upserts by stable ID, and handles a
fresh snapshot as authoritative. A stale delta or late frame from an earlier
selection cannot change the current transcript. `sessionClosed`, peer loss,
and flag disablement end the subscription and make the selected view
unavailable. The view can offer a return action; it must not show stale
content as live.

The transcript view renders the forwarded `RemoteWireMessage` kinds using
their text or structured JSON payload. It shows the peer name and remote
worktree context. The composer, stop, and other drive controls are enabled
only while the latest home-produced snapshot or delta reports `canDrive`.
The client does not use a summary's earlier `canDrive` value to authorize
driving. A rejected prompt restores the draft and reports the failure. This
client does not take a writer lease automatically. When the session is
readable but not drivable, an explicit Take over control sends the existing
`takeOver` message and waits for an updated `canDrive` value.

## Peer states

Each stored peer has a sidebar group while federation is enabled. The group
uses the same source as Settings, `helloPeers`, and distinguishes online,
connecting, offline, unauthorized (token revoked), unverified or identity
unproven, identity mismatch, and incompatible protocol. Only online,
session-carrying peers show session rows or offer subscription. Nononline
groups show a short state label and no stale rows or attention count.
Forgetting a peer removes its group and selected transcript. Renaming a peer
updates the group and the selected view without changing selection identity.

## Attention

A peer session needs attention when its summary status is
`awaitingPermission` or `awaitingInput`. Count each unique namespaced session
ID once, across the entire peer list. Peer group counts derive from the same
set, and the global header badge is the existing local unresolved count plus
the peer count. The attention inbox shows a separate, live Peer sessions
section for those counted rows with an Open action; its total matches the
badge. Local attention events retain their current persistence and
acknowledgment behavior. Peer attention has no local acknowledgment: the
count clears when the home Mac's status clears or the peer stops carrying
sessions. The inbox's local "Acknowledge all" action only applies to local
events and must be labeled accordingly when peer rows are present.

Peer attention is not inserted into `AttentionStore` or associated with a
local `AttentionWorktreeIdentity`. This prevents persisted duplicate events,
cross-Mac worktree ID collisions, and a badge that remains raised after B
clears the request. Offline, forgotten, and unverified peers contribute zero.
With `federationEnabled` off, the adapter contributes zero and the current
attention count remains unchanged.

## Boundaries and verification

Keep the provider's session list and message routing behavior intact. The
native adapter owns observation, subscription lifetime, transcript sync, and
count projection. The sidebar and center view consume that projection.

Focused Swift Testing coverage should prove: grouping by peer identity;
namespaced deduplication; online-to-offline, revoked, unproven, forgotten, and
rename transitions; flag-off behavior; selection and subscription cleanup;
snapshot/delta ordering and stale-frame rejection; `canDrive` gating and
prompt rejection; and local-plus-peer badge/inbox totals. Run affected suites
only, as required by `AGENTS.md`. A two-Mac manual acceptance check remains
useful for the real link lifecycle and visual appearance, but tests must not
claim that it ran.
