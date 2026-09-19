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

What is missing for multi-instance use is discovery, instance-to-instance
trust, and an aggregation surface. None of that requires central
infrastructure.

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
  redeem request carries B's own advertised endpoint and a fresh counter-code.
  A automatically stores B as a peer with the counter-code redeemable into a
  token for A→B. One flow produces mutual trust in both directions; either
  side can still revoke unilaterally, severing the link.
- Tokens never leave the machine that issued them. The device list is not
  replicated through any cloud.
- Revocation uses the existing per-device revoke + live-socket disconnect
  (`RemotePairingService.revoke`, `RemoteServer.disconnectDevice`).

### 3. Control: hub aggregation over the existing protocol

- No new peer protocol. A peer connection is a WebSocket client speaking the
  existing `RemoteClientMessage`/`RemoteServerMessage` wire. The DTOs and the
  JSON codec are shared, so the Swift client side is mechanical.
- One instance acts as the hub (typically the one the phone paired with). The
  hub holds client connections to its peers and presents a
  `FederatedSessionsProvider` that composes the local
  `RemoteSessionsProvider` with one connection per peer.
- Every session surfaced through the hub is tagged with the owning
  `instanceId`. Session IDs are namespaced as `instanceId:sessionId` on every
  federated surface; IDs are only unique per instance.
- The web client gains an instance picker: sections per instance, session
  lists per instance, and existing session views unchanged per instance.
  Permission requests and questions from a peer surface through the hub's
  socket to the phone; answers route back with the same namespacing.
- Invariant: the hub is a proxy, not a primary. Every session has exactly one
  home instance. Writer leases, `canDrive`, and permission policy are
  evaluated only at the home instance. The hub never evaluates policy for a
  peer's sessions; it forwards requests and responses.
- Alternative topology (kept as fallback, not chosen for v1): the phone pairs
  with each instance directly and picks between them. This is today's model
  plus an instance picker; it requires the web client to key tokens per
  origin (`alas.remote.token:<origin>`) and the phone to reach every
  instance. The hub model needs one pairing and one address, and degrades to
  this direct mode trivially, so the web client's token keying should land
  either way.
- Transcript consumption follows the existing subscribe-on-view pattern: tail
  window first, then deltas via `RemoteTranscriptSync` epochs/revisions. The
  hub does not replicate peer transcripts; it subscribes on demand like any
  client.

### Protocol handshake (prerequisite)

The protocol currently has no versioning. Before any instance-to-instance
traffic:

- Add a `hello` server message sent immediately after WS upgrade, carrying
  `protocolVersion` (starting at 2), `instanceId` (stable UUID), and display
  name.
- Clients send `helloAck(protocolVersion)` and close on incompatible major
  versions. A mismatched browser client shows an upgrade prompt instead of
  undefined behavior.
- All existing messages keep their current meaning at version 2. New
  federation fields ride on new optional fields, never by redefining old ones.

## Security

- Pairing remains the only way to obtain a token, on every path:
  browser→hub, browser→instance, hub→peer, peer→hub. Discovery grants nothing.
- Token hashes stay in the issuing instance's `remote-devices.json`. A peer
  connection's token is a normal per-device token scoped to that pair.
- A hostile LAN sees at most the Bonjour name and port of instances with
  discoverability enabled. No secrets, paths, or session data in TXT records.
- Revoking a peer severs the link immediately; existing sockets close via
  `disconnectDevice`. Re-pairing requires a fresh code on the revoking side.
- The hub proxies but cannot widen policy: a permission request from a peer's
  session is answered only through the peer's own policy evaluation, and the
  hub cannot accept a permission the home instance would refuse.

## Testing

- Protocol round-trip tests for `hello`/`helloAck` and the version-mismatch
  refusal path.
- Pairing tests: reciprocal redeem, counter-code single-use and expiry,
  peer-device `kind` persistence, unilateral revoke closing live sockets.
- Provider tests: `FederatedSessionsProvider` composition, namespaced session
  IDs, writer-lease and `canDrive` evaluated only at the home instance.
- Gateway tests: forwarded list/subscribe/prompt across a fake peer
  connection; late/superseded results suppressed by generation guards.
- Web asset tests: per-origin token keying, instance picker wiring, service
  worker cache revision bump.
- Manual: two real instances over a tailnet, discovery off → add by host:port;
  discovery on → add from the browsed list; phone paired with hub only,
  driving a session on the peer end to end.

## Rollout

1. `hello` handshake + per-origin token keying (safe, useful alone).
2. Bonjour discovery toggle + "Add instance" browsing.
3. Reciprocal pairing + peer device kind.
4. Hub `FederatedSessionsProvider` + web instance picker.

Each step is shippable and independently testable; step 1 is the prerequisite
for all instance-to-instance traffic.
