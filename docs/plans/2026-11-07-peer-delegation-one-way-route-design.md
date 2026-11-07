# Delegating to a Mac the source cannot dial

Status: implemented. The last follow-up named in the [agent delegation design](2026-11-05-peer-agent-delegation-design.md#trust-model),
after [proven identity and a delegation-only credential](2026-11-07-peer-delegation-credential-design.md). The user asked to work
through all of them and left the design to the author.

## Intent

A headless host often runs where it can be reached, for example a server on a tailnet, while the laptop that uses it cannot:
it sleeps, changes networks and sits behind NAT. Such a laptop pairs with the host and the host answers `inboundOnly`, since
it cannot pair back. The laptop's agents can then delegate to the host. The host's agents cannot delegate to the laptop, because
every delegation request travels over the source's own outbound link, and the host has none.

The laptop does keep a link open to the host. This design sends the host's delegation requests back over that link, and the
laptop serves them.

## Goals

- A host's agents can delegate to a Mac that paired with it inbound-only, while that Mac's link to the host is up.
- The Mac decides, per host, whether that host's agents may use it, as it does for any peer today.
- The Mac serves those requests exactly as it serves a delegation-only token: the delegation verbs and outbox events, nothing else.

## Non-goals

- Any other traffic in that direction: no sessions, consoles or lists for the host's person, who has no peer view of the Mac.
- A host reaching a Mac whose link is down. Children wait, as they do for an offline peer today.
- Two apps that cannot dial each other. Both pair back, so neither is inbound-only.

## Current state

| Area | What exists | What it means here |
|---|---|---|
| Wire | `RemoteClientMessage.host(HostClientMessage)` up, `RemoteServerMessage.host(HostServerMessage)` down | No case carries a request from server to client |
| `RemoteServer` | Connections keyed by socket, `connectionDevice` maps each to its device | Nothing sends to one device |
| Host's record of the Mac | Inbound-only `RemotePeer`: no token, no key, `localDeviceId` = the Mac's device, which proved its key at redeem | The device is the proven identity to route to |
| Mac's record of the host | `RemotePeer` with token and pinned key, no `localDeviceId`, no device for the host | Consent has nowhere to live |
| `HostPeerDelegation` | Channels and a `PeerDelegationClient` over `FederatedPeerLinks` (outbound links) | The seam for a second route |
| `HostProtocolConnection` | Finds the caller's device through `delegationPairing` | Needs the device given directly instead |
| `helloAck` | Version and challenge | No way for the Mac to advertise what it serves |

## Decisions

### 1. Two wire cases

- `RemoteServerMessage.peerHost(HostClientMessage)`: a host-protocol request from the server to the client.
- `RemoteClientMessage.peerHost(HostServerMessage)`: its response, and the events of a subscription it opened.

They mirror `.host` in the other direction. A client that does not know the case skips it, as it skips any unknown server message.

### 2. Capabilities both ways

The Mac advertises `host.delegation.reverse.v1` in a new optional `capabilities` field of `helloAck`, only to a server whose
`hello` advertises it too. Older servers ignore the field. A host advertises it in `hello` when it serves Remote headlessly, and
only uses the route to a device whose `helloAck` carried it on the current socket.

The capability stands for everything the route needs: the host protocol, its events and the delegation verbs. An inbound-only
Mac never sends the host a `hello`, so the host has nothing else to read them from, and the Mac never advertises it without
serving all three.

### 3. The host routes by device

`RemoteServer` records each authenticated socket's acknowledged capabilities and gains `send(_:toDevice:)`, which sends on that
device's newest socket. A gateway passes a `.peerHost` frame from its client to a handler the server holds, with the device id
it authenticated.

`send(_:toDevice:)` writes on the connection, not through the gateway, so the outbound filter of a delegation-only gateway
(part 2) does not apply to it. That gateway's inbound allowlist admits `.peerHost` too: it carries answers to what this host
asked, never a request of this host. This is the decision part 2's allowlist left to be made for any new kind.

`HostPeerDelegation` gains a reverse set: inbound-only peers whose device is proven (part 1), connected, and acknowledged the
capability. For each, a `PeerHostChannel` whose `send` is `send(.peerHost(message), toDevice:)`. `PeerDelegationClient` sees
the union: a peer reachable outbound uses that link, and an inbound-only one uses the reverse channel. `agent_list`'s `peers`
lists both, so an agent can name the Mac. The reverse peers are listed by the delegation client only: `helloPeers` feeds the
`hello` frame's federation targets, and a Mac nobody else can dial does not belong there.

The server reports a socket that acknowledged the capability, and one that closed, so the reverse set and the outbox collector
learn of availability from the server's socket lifecycle, as they learn of outbound peers from their links.

A reply that names no pending request is dropped, as on the outbound channel, so a Mac can only answer what was asked.

### 4. The Mac serves it as a delegation-only peer

The Mac serves a `.peerHost` request only from a link that is online, whose key is pinned and proven on this socket, and that
has no device here, which is what an inbound-only host is. It opens one `HostProtocolConnection` per link, delegation-only
(part 2), with a device built from the peer record:

- `kind` `.alasInstance`, `peerServerId` the record's server id, `peerPublicKey` its pinned key;
- `agentAccess` from the record (decision 5);
- `scope` `.delegation`.

`HostProtocolServer.connect` gains a variant that takes this device instead of looking one up. Every place the connection reads
the caller's device uses it, the outbox subscription's peer included, so the gate, ownership and outbox events work unchanged.
The connection closes when the link goes down. Its caller is `.remotePeer(deviceID:)` with an id derived from the record and
prefixed so it can never match a real device, used only for leases.

### 5. Consent lives on the Mac's peer record

`RemotePeer` gains an optional `agentAccess`, nil meaning off, decoded tolerantly: `FilePeerStore` drops every record when one
fails to decode. `RemotePeerManager.setAgentAccess` writes it when the record has
no device here, which is the inbound-only host's case, and `summaries` read it. So Settings' agent access row, which today says
"Pair again to allow this" for such a host, becomes a working control. A re-pair with that host starts at off, as for devices.
A two-way peer has no device here for a moment while it pairs, so its row reads this field until the pair-back lands; nothing
serves it on this route meanwhile, since it is not inbound-only.

### 6. Trust model

- The host is who the Mac pinned at pairing and who proved that key on this socket. The Mac decides what it may do, as for any
  peer, and the host can do no more than a delegation-only token could.
- The Mac is who proved its key to the host at redeem (part 1). The host trusts answers on that device's socket only.
- Nothing new is stored as a secret on either side.

## Compatibility

| Host | Mac | Result |
|---|---|---|
| New | New | The host's agents can delegate to the Mac once the Mac allows it |
| New | Old | The Mac sends no capability, so the host never routes there; as today |
| Old | New | The host's `hello` lacks the capability, so the Mac advertises nothing and serves nothing; as today |
| New | New, paired before part 1 | The Mac's device at the host is unproven, so the host never routes there until the Mac re-pairs |

## Testing

- Wire round trip of both cases, and `helloAck` with and without capabilities.
- `RemoteServer`: `send(_:toDevice:)` reaches that device only.
- Mac side: a `.peerHost` request is served only for a link with no device and consent, delegation-only; refused otherwise.
- `RemotePeerManager`: consent on a deviceless record, and `summaries` showing it.
- Host side: `PeerDelegationClient` uses the reverse channel for an inbound-only peer that acknowledged the capability.
- The two-host suite: a variant where host A pairs with host B inbound-only and B's agents delegate to A over A's link.

## Delivery

One PR, after the credential PRs it builds on.
