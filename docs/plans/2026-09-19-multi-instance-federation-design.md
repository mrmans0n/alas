# Multi-Instance Federation Design

## Goal

Let one person control multiple Alas instances from a paired client and find
other instances on networks they choose. Local, LAN, and tailnet operation
must work without an Alas account or hosted service.

An optional service at `app.alas.build` adds cross-network reach, a fleet
dashboard, and push notifications. It does not own session execution or
replace direct connections. This document specifies that hosted tier; it
does not claim the service exists.

## Non-goals

- No mandatory Alas-operated directory, account, or relay. A hosted outage,
  account lockout, or expired subscription must not disable local use or
  already-paired direct access.
- No custom NAT traversal or hole punching. Direct connections use reachable
  LAN, tailnet, VPN, or manually configured addresses. The optional relay
  connects endpoints through outbound connections when direct access is
  unavailable. Entering an address alone does not make it reachable.
- No cloud storage of plaintext pairing tokens, device private keys, source
  code, or transcripts. The hosted directory may store approved public keys
  and routing metadata.
- No transfer of execution authority to the hosted service. Each home
  instance evaluates its own permissions and writer leases. A user may
  explicitly authorize a gateway to relay commands on their behalf.
- No multi-user story. Every peer and every paired client belongs to the same
  person who owns the instances.

## Background

The Remote stack already provides a per-instance control plane:

- `RemoteServer` (`Alas/Sources/Remote/Server/RemoteServer.swift`): HTTP +
  WebSocket server on an `NWListener`, multiple simultaneous connections, a
  writer lease with `takeOver` per session.
- `RemotePairingService` + `FileDeviceStore`: short-TTL single-use pairing
  codes, per-device 256-bit tokens stored as SHA-256 hashes, constant-time
  comparison, brute-force rate limiting, per-device revocation.
- `RemoteNetwork`: classifies loopback, LAN, and Tailscale ranges
  (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) and already recommends tailnet
  addresses for pairing.
- `RemoteClientMessage` / `RemoteServerMessage`
  (`Alas/Sources/Remote/Protocol/`): a typed `Codable` protocol covering
  session lists, creation, prompts, queue control, permission answers,
  transcript delta sync (`RemoteTranscriptSync`), diffs, file reads, and
  worktree-session creation.
- The static web client (`Alas/Resources/RemoteWeb/`) pairs once via QR and
  keeps a single token in `localStorage` under `alas.remote.token`.

PR #1337 (`nacho/pwa`, "multi-server hub for the remote web client, phase 1",
spec in `docs/superpowers/specs/2026-09-19-remote-hub-multi-server-design.md`)
changes that last point and lands several of this document's prerequisites.
It is treated here as the baseline; see "Relationship to PR #1337" below.

Discovery, instance trust, and gateway aggregation define the account-free
path below. The optional hosted tier adds a directory, relay, and notification
delivery without making them prerequisites for that path.

## Relationship to PR #1337

#1337 ships the topology this document originally listed as the fallback:
the phone pairs with every Mac directly and switches between them. Everything
below is written on top of it rather than beside it.

**Already landed by #1337 (do not re-specify):**

- Server identity: `AppConfig.Remote.serverId` (UUID, generated once) and
  `displayName`, exposed as `RemoteServerIdentity` and in `/remote-info`.
- `hello` as the first frame after upgrade, carrying `protocolVersion`
  (`RemoteProtocolVersion.current = 1`), `serverId`, `name`, `hubEnabled`.
- `RemotePairingLink.build(code:addresses:port:)`: the QR and the copy button
  encode every advertised origin as `hosts=`, in `RemoteNetwork` rank order.
- `RemoteOriginPolicy` plus CORS on `/pair`, `/health`, `OPTIONS /pair`, and
  the WebSocket upgrade, so a page served by Mac A may pair with and connect
  to Mac B.
- Client registry (`hub-registry.js`, `localStorage` key `alas.remote.hub`):
  one entry per server with `serverId`, `name`, ordered `origins`,
  `lastOrigin`, `token`, `protocolVersion`, `hubEnabled`. Migration from the
  old single token key.
- Client link manager (`hub-links.js`): one socket per server, origin
  fallback with a 4 s handshake timeout, idle links polling `listSessions`
  every 30 s while visible for attention and running counts, and
  unauthorized-versus-offline detection via a `/health` probe.
- `switchServer` with `resetServerScopedState()`, so all per-server state in
  `app.js` is already isolated behind one function.
- Experiment flag `AppConfig.Remote.hubEnabled` gating the client hub UI.

**Terminology.** #1337 uses "hub" for the *browser client* that holds several
credentials and is served by one of the Macs. This document previously used
"hub" for a *Mac instance* that proxies its peers. To avoid two meanings, this
document now calls the proxying Mac the **gateway instance**, and reserves
"hub" for the client-side registry and UI from #1337.

**Contradictions resolved in favour of #1337:**

- Identity field is `serverId`, not `instanceId`. Namespaced session IDs
  below use `serverId`.
- Protocol version starts at 1 and stays at 1 for everything additive here.
  A bump to 2 happens only when the gateway introduces a message an
  unversioned client cannot tolerate.
- There is no `helloAck` requirement. #1337's browser client records the
  version and refuses nothing. A Swift peer connection (below) does send
  `helloAck` and closes on a major mismatch; the server treats `helloAck` as
  optional so the browser client is unaffected.
- Per-origin token keying is replaced by the registry document. "Per-origin
  token keying" in Testing and Rollout below means the registry.

**What #1337 leaves open, and this document owns:**

- Discovery. #1337 has none; addresses arrive only through the pairing link
  or manual entry.
- Instance-to-instance trust. #1337 pairs browsers only. There is no Swift
  WebSocket client anywhere in the app today.
- Server-side aggregation. Attention counts are polled by the phone, one
  socket per Mac, only while the page is visible, and only for Macs the
  phone can reach directly.
- Mac-to-Mac visibility. Nothing in #1337 lets the native macOS app show a
  peer's sessions or fold a peer's needs-attention count into its own.

**Ordering.** Land #1337 first. The rollout below is rebased on it; the old
step 1 ("hello handshake + per-origin token keying") is done.

## Design

Federation is additive: each instance keeps running exactly the control plane
it has today. Three new pieces connect instances and clients.

### 1. Discovery (opt-in, link-local)

- Register the existing listener with Bonjour: `NWListener.service` with
  `_alas._tcp`, TXT records carrying a short instance display name and
  machine model. No paths, extra ports, or token material in TXT.
- Browse with `NWBrowser` for an "Add instance" flow in Settings → Remote.
  Discovered instances appear by name; adding one starts pairing (below).
- Default off. A "Discoverable on this network" toggle in Settings → Remote
  controls both advertisement and browsing. Pairing codes remain the gate;
  discovery only surfaces host:port candidates, it grants nothing.
- Bonjour discovery remains link-local. Elsewhere, users can add reachable
  addresses manually or opt into the hosted directory described below.
  Hosted enrollment neither enables Bonjour nor exposes an inbound listener
  to the internet.

### 2. Trust: an instance is just another paired device

- Extend the existing `RemotePairingService` and `FileDeviceStore` model.
  An Alas instance redeems a code like any other device; its device record
  gains a `kind` field distinguishing browsers from `alasInstance` peers.
- Pairing is reciprocal: when instance B redeems a code on instance A, B's
  redeem request carries B's own advertised origins and a fresh counter-code.
  A automatically stores B as a peer with the counter-code redeemable into a
  token for A→B. One flow produces mutual trust in both directions; either
  side can still revoke unilaterally, severing the link.
- The input to "add a peer" is the same pairing link #1337 already produces.
  B pastes A's link (or picks A from discovery, which yields the same shape);
  B's redeem body adds optional `peerOrigins` (B's own `hosts` list from
  `RemotePairingLink`) and `counterCode`. Browsers omit both fields and `/pair`
  behaves exactly as in #1337. A's device record for B gains `kind` and
  `peerServerId`; B's origins go into A's own peer record (below), which A
  uses, in order, exactly as `hub-links.js` uses a server's `origins`.
- Because both sides then hold an origin list and a token for the other, a
  peer record on the Mac (`remote-peers.json`) is the Swift twin of a registry
  entry in the browser: `serverId`, `name`, `origins`, `lastOrigin`, token,
  `protocolVersion`, plus `localDeviceId` linking back to the inbound device
  record so forgetting a peer revokes both directions.
- Implementation plan for this section and the handshake:
  `docs/superpowers/plans/2026-09-19-federation-phase-1-peer-trust.md`.
- The issuer stores the token hash; the paired client must hold the token to
  authenticate. Native outbound credentials belong in Keychain before
  hosted access ships. Cloud metadata must not contain either endpoint's
  plaintext credentials.
- Revocation uses the existing per-device revoke + live-socket disconnect
  (`RemotePairingService.revoke`, `RemoteServer.disconnectDevice`).

### 3. Control: gateway aggregation over the existing protocol

- No new peer protocol. A peer connection is a WebSocket client speaking the
  existing `RemoteClientMessage`/`RemoteServerMessage` wire. The DTOs and the
  JSON codec are shared, so the Swift client side is mechanical. It needs a
  new `RemotePeerConnection` (`URLSessionWebSocketTask` or `NWConnection`;
  nothing in the app opens a client WebSocket today) that mirrors
  `hub-links.js`: try `lastOrigin` then the rest, 4 s handshake timeout,
  backoff, `hello` first, `/health` probe to tell revoked from unreachable.
- Any instance with peers is a **gateway instance** for them. It holds one
  `RemotePeerConnection` per peer and presents a `FederatedSessionsProvider`
  that composes the local `RemoteSessionsProvider` with one connection per
  peer. There is no elected gateway; every paired Mac gateways its peers, and
  the phone simply talks to whichever Mac it has active.
- Every session surfaced through a gateway is tagged with the owning
  `serverId`. Session IDs are namespaced as `serverId:sessionId` on every
  federated surface; IDs are only unique per instance. Namespacing lives
  entirely in `FederatedSessionsProvider`: it prefixes on the way out and
  strips and routes on the way in. The web client treats `sessionId` as an
  opaque string and needs no change to any handler. `sessionList` rows gain an
  optional `serverId` and `serverName` so the client can group; rows without
  them are local, as today.
- Every session has exactly one home instance. Writer leases, `canDrive`,
  and permission policy are evaluated there. A gateway is nevertheless a
  trusted controller: it can read forwarded content and send commands using
  its peer credential. Allowing its clients to control a peer is explicit
  delegation, not something the account or relay may infer.
- Loop guard: a gateway never re-exports sessions it received from a peer.
  `FederatedSessionsProvider` only forwards rows whose `serverId` is absent
  (local) from each peer, so A↔B↔C pairings cannot echo sessions around the
  ring or duplicate them.
- Relationship to the #1337 client hub: the two compose. The phone keeps its
  direct links to every Mac it paired with (offline detection, "Pair again",
  switching) and additionally sees, on whichever Mac is active, that Mac's
  peers' sessions grouped by server. Concretely, when the active Mac is a
  gateway, its session list already contains its peers' sessions, so the
  Servers section badges for those peers can come from the gateway's pushed
  `sessionList` instead of the phone's own 30 s idle polls. Idle polling
  stays as the fallback for Macs that are paired with the phone but not with
  the active Mac.
- Why keep a gateway at all when direct mode exists: it gives the native
  macOS app peer visibility (a peer's sessions in the sidebar, needs-attention
  counts folded in), it keeps aggregation alive when the phone is in the
  background or cannot reach a peer directly, and it lets a phone paired
  with one Mac drive every Mac that Mac trusts. Direct mode alone covers
  none of those.
- Failure mode to document, not solve: a phone paired only with the gateway
  loses everything when the gateway is down. The mitigation is to pair the
  phone with each Mac directly as well, which #1337 makes cheap. The gateway
  must not become the only path.
- Transcript consumption follows the existing subscribe-on-view pattern: tail
  window first, then deltas via `RemoteTranscriptSync` epochs/revisions. The
  gateway does not replicate peer transcripts; it subscribes on demand like
  any client, and unsubscribes upstream when the last downstream subscriber
  for that session goes away.

### Protocol handshake (landed by #1337, extended here)

`hello` exists: first frame after upgrade, `protocolVersion: 1`, `serverId`,
`name`, `hubEnabled`. This document adds only:

- An optional client message `helloAck(protocolVersion)`. Swift peer
  connections send it and close on a major mismatch. Browser clients need
  not send it; the server never waits for it.
- Two optional fields on `hello`: `federationEnabled` (the flag below) and
  `peers: [{ serverId, name, state }]`, so a client can render the gateway's
  peer list without a separate request. Both absent means a #1337-era server.
- All existing messages keep their current meaning at version 1. New
  federation fields ride on new optional fields, never by redefining old ones.

### Feature flag

Follows #1337's `hubEnabled` precedent: `AppConfig.Remote.federationEnabled`,
default `false`, a row in Settings, Advanced, Experimental. It gates
discovery, the peer list in Settings → Remote, reciprocal pairing, and the
`FederatedSessionsProvider`. The `hello` reports it so the phone can decide
whether to trust pushed peer counts or keep polling. It is separate from
`hubEnabled` because the two are independently useful: a user can run the
phone hub without any Mac-to-Mac pairing, and a Mac can federate with peers
for the native sidebar without the phone hub being on.

## Security

- Pairing remains the only way to obtain a token, on every path:
  browser→instance, gateway→peer, peer→gateway. Discovery grants nothing.
- The reciprocal `peerOrigins` and `counterCode` fields on `/pair` are
  accepted only from a request that redeemed a valid code, so they cannot be
  used to plant a peer without the code holder's consent. The counter-code
  has the same 120 s TTL and single-use rule as a normal code.
- `RemoteOriginPolicy` from #1337 applies unchanged to peer connections. A
  Swift peer sends no `Origin` header and is admitted by the token alone,
  which is the same posture as any non-browser client today.
- Token hashes stay in the issuing instance's `remote-devices.json`. A peer
  connection's token is a normal per-device token scoped to that pair.
- Discovery exposes a service name, port, and the advertised TXT metadata,
  never secrets, paths, or session data. This is not transport encryption:
  the current `NWParameters.tcp` listener uses plaintext HTTP/WebSocket.
  Non-loopback use needs a trusted encrypted network or a separately secured
  transport. Host and Origin checks do not encrypt traffic.
- Revoking an inbound device closes its live sockets on that instance.
  Forgetting a peer also deletes this Mac's outbound credential. Fleet-wide
  revocation must report which other instances have received the change;
  an offline instance cannot apply a revocation immediately.
- Home-instance checks still apply to commands sent by a gateway, but a
  compromised gateway can exercise its delegated authority. The hosted
  relay must not receive that authority or those credentials.

### Known gap: a peer identity is claimed, not proved

`serverId` is self-reported, at pairing and on the wire. Nothing ties it to
anything the claimant had to possess. So a holder of one live pairing code
can redeem it while advertising an *existing* peer's `serverId`: the peer
store keys on that identity, so the claimant's token and origin replace the
row's, and this Mac's outbound link then dials the claimant instead of the
peer whose name the row still carries.

Two smaller consequences are already closed. A link refuses a socket whose
`hello` reports an id other than the one its record was paired with, so an
address that has merely been reassigned cannot re-key a record; and a peer
redeem no longer deletes earlier device records for the same identity, so the
impersonated peer keeps its inbound access. Forgetting the peer revokes every
device carrying the identity, which removes the claimant's access too.

Phase 1 accepts the remaining gap: the flag is off by default, no session
data crosses a peer link, and the actor must hold a code the user
deliberately displayed, within its 120-second window. It does not stay
acceptable. Bind each peer record to verified key material. The peer must
prove possession of a key committed to at pairing time, with `serverId`
derived from or pinned to it. This is a prerequisite for both aggregation
and hosted access, not a property an account login can supply. No real
session data may cross those links before that binding exists.

## Hosted fleet tier

### Decision and product scope

Offer `app.alas.build` as an optional directory, relay, and push service for
one person's devices. Ship a self-hostable implementation using the same
public protocol and a configurable endpoint. Neither local features nor
direct connections check a hosted entitlement.

The first hosted release focuses on reaching agents and handling work that
needs attention:

- A fleet dashboard lists enrolled instances, connection state, and last-seen
  time. Session status comes from each instance. Cached status is visibly
  dated, never presented as live.
- An attention inbox collects permission requests, questions, and failures
  from reachable instances. Each action identifies its home instance and
  session before the user approves it.
- Existing prompt, stop, transcript, changes, and file-reading operations work
  through a relay when the browser cannot reach the Mac directly. Both
  endpoints connect outbound, without router port forwarding or a VPN.
- Opt-in push notifies the user without an open dashboard tab. Account
  sign-in locates the fleet; trusted-device approval still gates enrollment.

User-operated infrastructure could also provide these capabilities. The
hosted value is removing that setup and maintaining one browser entry point,
not making peer-to-peer control possible. Firewalls and corporate proxies
can still block outbound connections.

Fleet search and usage summaries are possible extensions. Start with
client-side aggregation of data reachable instances expose. Report missing
or offline instances and distinguish provider-reported usage from estimates
and unavailable data. No plaintext cloud search index is required.

Encrypted history backup is separately opt-in. Define key recovery,
retention, deletion including backups, and storage quotas before adding it.
Restoring a transcript does not migrate a running agent, its process state,
or its worktree. Archives are not a prerequisite for fleet control.

### Connection model

The hosted service is not a gateway instance. A gateway terminates a trusted
peer connection and can read its data. The relay carries encrypted traffic
between an authorized client and the home instance.

```text
Browser/PWA ---- outbound WSS ---- Relay ---- outbound WSS ---- Mac A
                                 |
                                 +--------- outbound WSS ---- Mac B

Each browser-to-Mac channel authenticates and encrypts end to end.
```

Each enrolled Mac maintains an outbound connection while Alas is running
and hosted access is enabled. The dashboard reaches each home instance
through the relay; no always-on gateway Mac is required. This does not
introduce an unattended daemon independent of Alas. Disabling hosted access
closes its channels and rejects new hosted commands even with valid account
credentials.

Reuse `RemoteClientMessage` and `RemoteServerMessage` operations inside the
encrypted channel, then apply the existing gateway and home-instance policy
checks. Add negotiated envelopes for command identity and delivery tracking
rather than assuming the current wire already provides them. Never treat a
relay connection as an authenticated local caller or expose a generic TCP
tunnel or arbitrary URL fetcher.

The outer relay protocol needs its own version and capabilities, independent
of `RemoteProtocolVersion`. Use opaque routing IDs and bounded frames. Bind
endpoint identities, routing context, and protocol version into the
authenticated channel, and reject replay. Qualify instance-local objects
with `serverId` across lists, actions, and pending requests.

Native clients may prefer a direct authenticated route and use the relay
when it fails. Verify the same pinned identity on both routes; reconcile
subscriptions after switching. Never replay a mutation merely because a
different route connected.

The HTTPS dashboard cannot assume access to plaintext `http://` and
`ws://` LAN endpoints. CORS does not solve
[mixed-content restrictions][mixed-content]. Use the secure relay unless a
browser-compatible authenticated direct transport is available. The existing
locally served browser client remains a separate outage path.

Browser storage is already origin-scoped. The hosted dashboard cannot read
the local client's `alas.remote.hub` registry or inherit its tokens.
Authorize each new dashboard browser instead of copying its stored
credentials to the service.

### Enrollment, keys, and recovery

Account authentication grants service access and discovery, not permission
to read a Mac or control its agents.

- Bootstrap a fleet from a locally confirmed Mac. Generate device keys there,
  retain native private keys in Keychain, and pin the fleet's initial
  approval identity independently of the hosted directory.
- Enroll subsequent devices through a short-lived, single-use exchange
  approved by an already trusted device. Bind approval to the joining key,
  fleet, role, selected instances, and expiry. QR-carried key or verification
  code comparison must prevent directory key substitution.
- Home instances verify the approved key chain and their own policy before
  accepting access. Inserting a hosted database row cannot grant control.
  Controller grants may include permission approval; do not describe them
  as read-only status access. Distinguish controller and Mac identities.
- Keep relay-account credentials separate from Alas device credentials.
  Any instance token a client needs travels only inside the verified
  end-to-end channel, never in a relay URL, log, or outer frame.

Use an established, reviewed authenticated key-exchange and encryption
implementation. Review its browser support, nonce handling, replay
protection, and rotation before release. Two TLS connections terminated at
the relay are not end-to-end encryption.

Account recovery must not recover device private keys or silently authorize
a replacement controller. Without a trusted device or a separately designed
user-held recovery mechanism, require local re-enrollment on surviving Macs.
A password reset alone does not restore fleet authority.

The service cuts off a revoked controller's relay access immediately.
Reachable home instances verify signed revocations and close its channels.
Persist revocation state and reject older membership updates. An offline Mac
must synchronize revocations before accepting hosted commands on reconnect.
Show pending acknowledgements; do not promise immediate revocation of
disconnected direct peers.

### Data visibility and browser trust

The service stores account records, approved public-key membership, opaque
routing IDs, presence timestamps, push subscriptions, and bounded encrypted
attention records. It observes IP addresses, connection times, traffic
volume, and routing relationships. Names, session titles, paths, transcripts,
and approval content belong in encrypted payloads.

Do not log tokens, pairing links, command bodies, or decrypted session data.
The operator must still secure service credentials for account sessions,
TLS, and push delivery. No device private keys on the server does not mean
there are no server secrets.

End-to-end encryption protects against passive relay inspection and storage
compromise. A browser still trusts the JavaScript `app.alas.build` serves.
A compromised web deployment can read decrypted content or issue commands
using that browser's authority. Non-exportable browser keys do not prevent
this.

Separate web deployment and relay administration, exclude third-party
scripts from the dashboard, and enforce a restrictive content security
policy. These reduce risk but do not remove trust in delivered code. Users
who need independence from hosted web delivery need an independently
distributed native client or a self-hosted client whose delivery they trust.
Do not advertise the browser dashboard as protected from a malicious
operator.

### Push, stale state, and delivery

Use standards-based Web Push with explicit permission and capability checks.
On iOS and iPadOS the supported path requires an installed Home Screen web
app; see [WebKit's Web Push requirements][web-push]. Keep the inbox usable
when permission is denied or push is unavailable.

Default to generic notification text such as "Alas needs your attention".
Push services and lock screens should not receive source code, prompts, or
permission details. Bound and expire encrypted attention records. Clicking
a notification reconnects to the home instance and fetches the current
request; the push payload is not authority to approve it.

Push does not guarantee waking a sleeping Mac or starting Alas. Show
last-seen state for asleep, offline, or quit instances and disable actions
that require them. Notifications may be delayed, duplicated, or refer to
requests already resolved elsewhere.

Do not ship server-queued execution in the first hosted release. A user can
keep a draft locally, but the UI must not say it was sent until the home
instance acknowledges it. Prompt submission, stop, permission decisions,
and worktree creation must never replay automatically on reconnect.

Commands need unique operation IDs and home-side deduplication across
reconnections. On a lost acknowledgement, reconcile before offering retry.
If the home instance cannot establish the result, show "outcome unknown".
Permission and question responses also bind the session generation and
pending request so a stale click cannot answer a different request. Offline
command queues need a separate design covering expiry, cancellation,
revocation, and durable deduplication.

### Outages, self-hosting, and operation

Disconnecting `app.alas.build` must leave local use and previously authorized
direct LAN and tailnet access unchanged. The hosted dashboard may be
unavailable and push stops. Never silently downgrade it to an insecure
transport. A user relying only on the relay must establish direct pairing
before claiming an outage path.

Ship a self-hostable service with the same public protocol, enrollment, and
revocation rules, plus deployment, upgrade, backup, and deletion procedures.
It must not require an `app.alas.build` account. Moving providers requires
confirming the new endpoint and fleet identity; never send stored
credentials to an arbitrary replacement URL.

Operating the service requires authentication security, bandwidth and
connection quotas, bounded queues and frames, slow-client backpressure,
abuse handling, push delivery, dependency updates, incident response, and
support. Publish retention and deletion rules, including backup expiry,
before launch. Account deletion removes hosted records and subscriptions,
not local sessions or direct pairings.

A paid tier may cover relay capacity and push convenience. Billing stays out
of local authorization and execution. Search, usage reports, and encrypted
archives remain separate product decisions, not reasons to upload
transcripts by default. Team access, remote software installation, and a
general remote shell remain out of scope.

### Hosted release gates

- Close the peer-identity gap above before real session data crosses either
  a gateway or hosted channel.
- Review encryption, enrollment, recovery, revocation, and the browser-code
  delivery threat model before opening the service.
- Ship working relay access and the attention inbox before adding archives
  or offline command queues.
- Publish the self-hosted path, retention policy, operating limits, and
  outage recovery procedure with the hosted offering.

[mixed-content]: https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Mixed_content
[web-push]: https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/

## Testing

- Protocol round-trip tests for `hello`/`helloAck` and the version-mismatch
  refusal path.
- Pairing tests: reciprocal redeem, counter-code single-use and expiry,
  peer-device `kind` and `peerOrigins` persistence, a browser redeem without
  the new fields unchanged from #1337, unilateral revoke closing live sockets.
- Peer connection tests (`RemotePeerConnection` with an injected socket
  factory, mirroring `scripts/tests/remote-web-hub/test-hub-links.js`): origin
  fallback order and timeout, `lastOrigin` promotion, `hello` then `helloAck`,
  close on major mismatch, unauthorized versus offline via `/health`.
- Provider tests: `FederatedSessionsProvider` composition, namespaced session
  IDs, loop guard on rows that already carry a `serverId`, writer-lease and
  `canDrive` evaluated only at the home instance, upstream unsubscribe when
  the last downstream subscriber leaves.
- Gateway tests: forwarded list/subscribe/prompt across two in-process
  `RemoteServer`s; late/superseded results suppressed by generation guards.
- Web tests (node, `scripts/tests/remote-web-hub/`): `sessionList` rows
  grouped by `serverId`; Servers badges taken from a gateway's pushed list
  when the active server reports `federationEnabled`, from idle polls
  otherwise. `RemoteWebAssetTests` for the `?v=` bump only.
- Manual: two real instances over a tailnet, discovery off → add by pasting a
  pairing link; discovery on → add from the browsed list; phone paired with
  the gateway only, driving a session on the peer end to end; then quit the
  gateway and confirm the phone falls back to its direct link to the peer.

Hosted acceptance checks supplement the direct federation checks:

- From a separate network, prompt a Mac and answer a pending request over
  the encrypted relay without inbound ports.
- Substitute a directory key or use account login without approved device
  enrollment. The home instance must reject access.
- Revoke connected and offline controllers. Verify live disconnect, pending
  acknowledgement display, and refusal after the offline Mac returns.
- Inspect relay storage and logs for plaintext credentials and content.
  Review web-deployment compromise separately; empty relay storage is not
  proof of browser-client safety.
- Drop acknowledgements during prompt submission and worktree creation.
  Reconnect on another route and verify no duplicate operation. Reject
  stale approvals after a session restart or local resolution.
- Exercise denied push permission, delayed and duplicate notifications,
  and a sleeping Mac. Stale notifications must not authorize actions.
- Stop the service and confirm local work and pre-established LAN and
  tailnet connections still function without an account check.
- Exercise enrollment, relay, revocation, and deletion on a self-hosted
  deployment using the same clients. Verify one fleet cannot route to or
  retrieve another fleet's records.

These are implementation acceptance criteria, not checks performed by this
documentation change. Source-text and asset-wiring assertions are not
substitutes for these observable behaviors.

## Rollout

0. PR #1337 merges: `hello`, `serverId`, pairing link with `hosts`, Origin
   policy, client registry and link manager. Done on `nacho/pwa`.
1. `helloAck` (optional) + `RemotePeerConnection` Swift client + `kind` and
   `peerOrigins` on `RemoteDevice`. No UI yet; covered by integration tests
   with two in-process `RemoteServer`s.
2. Reciprocal pairing: paste a pairing link into Settings → Remote → Peers.
   Both Macs list each other; revoke severs both ways.
3. Bonjour discovery toggle + "Add peer" browsing, feeding step 2.
4. `FederatedSessionsProvider` behind `federationEnabled`: peer sessions in
   the native sidebar and in the gateway's `sessionList`, namespaced IDs,
   loop guard, upstream subscribe/unsubscribe.
5. Web client: group `sessionList` rows by `serverId`/`serverName`, and let
   the Servers section take badge counts from a gateway's pushed list when
   available.

Steps 1 to 3 are Mac-only and independently useful. Step 4 is the first one
that changes what the phone sees. Step 5 is the only web-client change, and it
is small because #1337 already isolated per-server state and treats session
IDs as opaque.


Hosted access has a separate rollout and does not require a proxying gateway
in the data path. Verified device identity is a shared prerequisite: complete
it before direct aggregation in step 4 above or any hosted data access.

1. Review authenticated encryption, scoped enrollment, recovery, and
   revocation. Bind peer and controller records to verified device keys.
2. Add the optional account directory, service connection, and self-hostable
   relay. Its opt-in setting is separate from `hubEnabled` and
   `federationEnabled`; it does not enable LAN discovery.
3. Serve the fleet dashboard and attention inbox through encrypted channels
   to home instances. Exercise uncertain delivery and outage behavior before
   releasing them.
4. Add opt-in Web Push and bounded encrypted attention records. Document
   installation, permissions, and sleeping-host limitations.

Fleet search, usage aggregation, and encrypted history backup can follow
under separate designs. They do not block direct federation or the hosted
control and notification release.
