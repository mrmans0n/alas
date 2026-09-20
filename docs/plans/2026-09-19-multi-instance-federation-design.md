# Multi-Instance Federation Design

## Goal

Let one person control multiple Alas instances (several Macs, or one Mac plus
peers reachable over the user's own network) from a single paired client, and
let instances find each other — without any Alas-operated server, account
system, or cloud relay.

## Non-goals

- No Alas-operated coordination server, directory, account, or relay. Anything
  that requires a server the project operator must run is out; the feature must
  work with only the instances themselves and networks the user already has.
- No NAT traversal, hole punching, or TURN-style rendezvous. Cross-LAN reach
  comes from networks the user already operates (Tailscale, WireGuard, VPN) or
  from manual host:port entry.
- No syncing of pairing/device state through iCloud or any third-party cloud.
- No merge of security boundaries: each instance stays authoritative for its
  own sessions, prompts, permissions, and writer leases. No instance can grant
  access to another instance's data.
- No multi-user story. Every peer and every paired client belongs to the same
  person who owns the instances.

## Background

The Remote stack already provides a per-instance control plane:

- `RemoteServer` (`Alas/Sources/Remote/Server/RemoteServer.swift`): HTTP +
  WebSocket server on an `NWListener`, multiple simultaneous connections, a
  writer lease with `takeOver` per session.
- `RemotePairingService` + `FileDeviceStore`: short-TTL single-use pairing
  codes, per-device 128-bit tokens stored as SHA-256 hashes, constant-time
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

What is still missing for multi-instance use is discovery, instance-to-instance
trust, and a server-side aggregation surface. None of that requires central
infrastructure.

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
- Off-LAN discovery is intentionally not built. On a user's tailnet, MagicDNS
  names are stable and manually entering host:port is fine; `RemoteNetwork`
  already flags tailnet addresses as recommended. If a design needs a server
  the user does not own, it is out of scope.

### 2. Trust: an instance is just another paired device

- Reuse `RemotePairingService` and `FileDeviceStore` unchanged. An Alas
  instance redeems a code like any other device; its device record gains a
  `kind` field distinguishing browser/app devices from `alasInstance` peers.
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
- Tokens never leave the machine that issued them. The device list is not
  replicated through any cloud.
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
- Invariant: the gateway is a proxy, not a primary. Every session has exactly
  one home instance. Writer leases, `canDrive`, and permission policy are
  evaluated only at the home instance. The gateway never evaluates policy for
  a peer's sessions; it forwards requests and responses.
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
- A hostile LAN sees at most the Bonjour name and port of instances with
  discoverability enabled. No secrets, paths, or session data in TXT records.
- Revoking a peer severs the link immediately; existing sockets close via
  `disconnectDevice`. Re-pairing requires a fresh code on the revoking side.
- The gateway proxies but cannot widen policy: a permission request from a
  peer's session is answered only through the peer's own policy evaluation,
  and the gateway cannot accept a permission the home instance would refuse.

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
