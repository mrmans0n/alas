# Proven peer identity and a delegation-only credential

Status: proven identity (PR 1, #2380) and delegation scope (PR 2) implemented. This is the first follow-up named in the
[agent delegation design](2026-11-05-peer-agent-delegation-design.md#trust-model). The user asked to work through all of that
design's follow-ups, starting here, and left the design to the author.

## Intent

Close two gaps that design accepted:

1. **Ownership rests on a claim.** A target decides which children and outbox entries belong to a peer by the `peerServerId`
   on the device that authenticated. That value is whatever the redeemer sent in `POST /pair`. Someone holding a live pairing
   code who knows another Mac's server id can read that Mac's children and drain its outbox.
2. **A headless host holds a full controller token.** `alas-host peers add` pairs the host with a Mac so the host's agents can
   delegate there. The host keeps the token the Mac issued, which can do everything the Mac's own peer view can do: read and
   drive any session, open consoles and change worktrees. A host runs without the Keychain and stores that token in an
   owner-only file, so any agent on the host, running as the same user, can read it. A prompt-injected agent on an always-on
   host could then take over the laptop.

## Goals

- A target attributes a device to a peer only when the redeemer proved that peer's key.
- A host that pairs only to delegate holds a token that can do nothing but delegate.
- Pairings made by current builds keep working wherever their identity was already proven.

## Non-goals

- Protecting a signed app build's token from local processes. The data-protection Keychain already scopes it to the app's
  entitlements, so agents on that Mac cannot read it. The app also uses the same peer link for the person's own peer view, so
  splitting its token would mean a second channel per peer for no gain.
- Proof of possession on every socket. A host keeps its identity key in the same file store as its tokens, so demanding a
  signature per connection would not stop an agent that can read one.
- The other follow-ups. See [Later](#later).

## Current state

| Area | What exists | What it means here |
|---|---|---|
| `RemoteIdentityCrypto` | Ed25519 keys per Mac; signatures over `alas.peer-identity.v1`, the server id and a challenge | Reuse it with a new domain |
| `RemotePeerPairer.pair` | The redeemer challenges the responder, and pins the key the responder proves | Only the redeemer proves the other side |
| `POST /pair` (`RemoteHTTPResponder`) | Stores `peer.serverId` on the new device, unproven; `peer.publicKey` is passed on as a claim | The gap in intent 1 |
| `completeInboundPeer`, two-way | The responder pairs back and requires the reply to prove the claimed server id and key, else it revokes the device | A two-way device is proven after the fact, but nothing records that on the device |
| Initiator branch | Our counter-code, redeemed by the peer we just proved, is matched to that attempt | Also proven, also unrecorded |
| `recordInboundOnlyPeer` | A host that never pairs back records the claim, with `publicKey: nil` | Unproven, and stays so |
| Approval pairing | `RemotePairingApprovalCoordinator.redeem` verifies the requester's envelope against its advertised key | Already a proof |
| `RemoteDevice` | `tokenHash`, `kind`, `peerServerId`, `agentAccess`; no key and no scope | Both new fields go here |
| `RemoteServer` | `validate(token:)` gives a device id; `RemoteSessionGateway` serves every message to it | No place refuses by scope yet |
| `PeerDelegationGate.allows` | Checks kind and `agentAccess` | Gains the proof check |
| Secret storage | Keychain with a `RemoteFileSecretStore` fallback; a host and an ad-hoc build use the file | Why intent 2 matters on hosts only |

## Decisions

### 1. The redeemer proves its key at redeem

A peer's `/pair` body gains `proof`: a signature with its identity key over

```
alas.peer-redeem.v1
<redeemer serverId>
<code>
```

The code is minted by the responder, single use and live for two minutes, so it already is a fresh challenge and no extra
round trip is needed. The responder's server id is left out because the redeemer does not know it yet: the pairing link
carries only origins and the code, and the redeemer learns the server id from the reply. A malicious responder could replay
the signature only at another Mac that independently minted the same 48-bit code within those two minutes. The new domain
means a redeem signature can never pass as a socket proof, or the reverse.

Signing input arrives unauthenticated, so the responder bounds it the way `isPlausibleChallenge` does for sockets: the
signature must have Ed25519's fixed length and the key must pass `isPlausiblePublicKey`. It then checks without consuming
that the code matches a live one, verifies the proof against `peer.publicKey`, and only then consumes the code. A proof that
fails is refused with the code left unconsumed, like any other implausible advertisement, and counts toward the failed-redeem
limit. A request with no proof still pairs, because older builds send none, but the device stays unproven.

Approval pairing needs no extra proof: the coordinator already verifies the requester's envelope against the key it
advertises, so the device records that key.

### 2. The device records the proven key

`RemoteDevice` gains `peerPublicKey: String?`, set only from a verified proof: at redeem by decision 1, or when a two-way pair-back
or an initiator's reciprocal redeem completes, from the key that exchange proved. `peerServerId` keeps today's meaning, but a
device without `peerPublicKey` is no longer trusted with it.

Decoding stays tolerant, because `FileDeviceStore` drops the whole file on one bad record.

Existing records are backfilled once by `RemotePeerManager`, after both it and `RemotePairingService` have loaded: a device linked by `RemotePeer.localDeviceId` from a peer record that holds
both a token and a pinned key (a two-way pairing whose pair-back proved the key) gets that key. Inbound-only devices on a host
are not backfilled: their key was never proven, and they need a re-pair to delegate.

### 3. The gate requires proof

`PeerDelegationGate.allows` also requires `device.peerPublicKey != nil` for every verb. Ownership checks keep comparing server ids,
which are now proven.

`read`, `status`, `interrupt` and `outbox` are refused too, unlike when access is off. An unproven device could be anyone, so letting
it drain an outbox is exactly the gap being closed.

The refusal is typed, `peerIdentityUnproven`, so the source can tell it from a pull that failed in transit. That matters because the
collector skips the quiet-child check after a failed pull (#2370): a parent whose target refuses every pull would otherwise wait
forever. On `peerIdentityUnproven` the source does what it does when the link becomes `.unauthorized`: it fails that peer's unsettled
children with a wake whose reason says to pair the two Macs again. `discover` and `start` return the same refusal, so `agent_list --peer`
and `session_new --peer` say why. `agent_list` without `peer` stays cheap and makes no peer calls, so it cannot know.

Settings shows "Pair again to allow this" on the agent access row of an unproven peer, as it does for a peer with no device, and
`alas-host peers agents` refuses anything but `off` for one.

### 4. A delegation-only token

`RemoteDevice` gains `scope`, `.full` by default and on decode. A `.delegation` device may only:

- complete the socket handshake: `hello`, `helloAck` and identity proofs. Its `hello` names no other paired Macs;
- send host-protocol requests from an allowlist: `.delegation`, still behind the gate, and what the source's channel needs to
  subscribe: `snapshot`, answered with a cursor and nothing else, `subscribe`, `subscribeAccepting` and `unsubscribe`. Anything else
  gets `invalidRequest`;
- receive, from its subscription, only `delegationOutboxChanged` and `resync`.

Two allowlists hold this, so a message kind or host request added later is refused until someone decides otherwise. The
[one-way route](2026-11-07-peer-delegation-one-way-route-design.md) is the first such decision: it admits `.peerHost` answers. The gateway's
`handle` sees every client message of the socket and passes only `.host` frames, and the gateway sends only `.host` frames back, so a
list push or anything a later change sends is dropped. The host-protocol connection holds the second allowlist. A `.delegation`
device gets no federation, consoles or presenter.

Answering `snapshot` with an empty one keeps the source unchanged: its channel takes a snapshot for the cursor and then subscribes.

The redeemer asks for the scope: its `/pair` body gains `scope: "delegation"`. The responder honours it only with a valid proof, and
echoes it in the reply. A responder that does not echo it is an older build that issued a full token.

### 5. A host asks for it

`alas-host peers add` asks for `.delegation`. A host has no peer view of the Mac, so it never needs more.

The guard is the capability in decision 6: before redeeming at an origin, a host checks that origin advertises it, and refuses a Mac
without it, saying to update Alas there.

The reply's echo is a fallback for a Mac that advertised the capability but issued a full token anyway. The host then drops the token
without storing it and reports the failure. Cleanup is not clean: the Mac pairs back while the host is still answering, so by then the
Mac holds a token for the host and the host holds a device for it, and the Mac's own device for the host is full-scope with nobody
holding its token. The host cancels its counter-code, so a pair-back still on its way cannot redeem it, and revokes a device a
pair-back already made unless an earlier pairing still holds the identity. The Mac keeps a peer record with a dead token, and the
unheld device, until the user forgets the host there.

The Mac's pair-back is unchanged: the Mac gets a full token for the host, because the person at the Mac uses the peer view of the
host. The two links have different scopes, and the host's `peers list` says so.

The app keeps asking for full tokens.

### 6. Capability

The responder advertises `pair.delegation-scope.v1` in `capabilities` of its `/health` reply, which a host can read before it holds
any token. A host checks it before starting `peers add`, so it can name
the problem before redeeming a code. The proof needs no capability, since an older responder ignores the field.

## Trust model, after

- A target attributes children and outbox entries to a Mac only after that Mac proved its key, at redeem or by the pair-back.
- One server id has one proven key. The first device to prove a key for it holds it, and a device proving another key for that
  server id is refused (`hasOtherProvenKey`). Forgetting the peer revokes all its devices and is the only way to re-key.
- So until a Mac re-pairs a host whose pairing predates this, its server id there is unproven, and anyone holding a live pairing code
  for that host could prove their own key for it first. The real Mac is then refused until the user forgets the peer on the host.
  This is the same class of exposure as before, since a pairing code is a credential. The mitigation is to re-pair promptly after
  updating.
- Someone holding a live pairing code can still pair as themselves and get a full token. That was always so: a code is a credential.
- An agent on a host that reads the host's token file can delegate to the Mac within the Mac's consent for that host, and nothing
  more.
- An agent on a signed app build cannot read its tokens. An agent on an ad-hoc dev build can, as today.

## Compatibility

| Responder | Redeemer | Result |
|---|---|---|
| New | New | Proven device; a host gets `.delegation` |
| New | Old | Pairs, unproven unless the pair-back proves it; the gate refuses delegation from an unproven device |
| Old | New app | Pairs as today; the old Mac ignores the proof and keeps its current checks |
| Old | New host | The host refuses `peers add` and asks for a Mac update |

Inbound-only pairings made since #2363 need a re-pair before their agents can delegate. Both features shipped in the last two days.

## Delivery

Two PRs, in this order:

1. **Proven identity.** Decisions 1 to 3: the proof, `peerPublicKey`, recording it in the three branches,
   the backfill, the gate, the typed `peerIdentityUnproven` refusal and the source failing children on it, the Settings hint. Run the
   two-host suite early: if its fixture pairs inbound-only without a proof, the gate turns it red, which also shows whether the
   fixture pairs the way real hosts do.
2. **Delegation scope.** Decisions 4 to 6: `scope`, the gateway allowlist, `peers add`, `peers list`.

The first is a precondition for the second: a scoped token is only worth checking if the gate trusts whose it is.

## Testing

Extend the existing suites:

- `RemotePairingService` and the `/pair` responder: a valid proof records the key; a bad proof is refused without consuming the code;
  no proof leaves the device unproven; a scope request without a proof is not honoured. One parameterized test.
- `RemotePeerManager`: the pair-back and initiator branches record the proven key; the backfill picks two-way records only.
- `PeerDelegationGate`: parameterized over proven or not, access and verb.
- Coordinator against the fake `ACPDelegationPeers`: a `peerIdentityUnproven` pull fails the unsettled children with one wake.
- The `/pair` responder: an oversized signature or implausible key is refused before any verification runs.
- The gateway: a `.delegation` device is refused every kind outside the allowlist, parameterized over the message kinds.
- `RemoteIdentityCrypto`: a redeem signature does not verify as a socket proof, and the reverse.
- The two-host suite (`ALAS_PEER_E2E=1`): one run where the host pairs with `.delegation` and delegates.

## Verify while building

1. **Approval pairing.** Settled: the envelope is verified against the requester's key, so that key is recorded.
2. **Where the gateway dispatches.** That one place sees every client message, including consoles and the host-protocol frames, so the
   allowlist cannot be bypassed by a message routed elsewhere.
3. **The pair-back refusal on a host.** Exactly what each side keeps when a host refuses a full token after redeeming, against the
   description in decision 5.
4. **Re-pair with a scope change.** A host re-pairing an existing two-way peer must not keep an older full-scope device alive for the same
   Mac. `forget` already revokes every device carrying the identity; check `peers add` does the same on the Mac's side.

   Found: it does not. A redeem adds a device and leaves the earlier ones, because the Mac's rollback of a failed re-pair restores the
   earlier record and needs its device alive. So a host paired before this update keeps its old full device on the Mac after it
   re-pairs. The host stops holding that token, since the re-pair replaces it in its store, but a copy taken earlier stays valid.
   The way out is to forget the host on the Mac, then run `peers add` again. Revoking the earlier devices once a proven re-pair
   commits is a follow-up.

## Later

The remaining follow-ups get their own designs. This one must not rule them out:

- **A store epoch for a recreated target database.** The source's outbox cursor survives a target that lost its store. Nothing here
  touches cursors.
- **A one-way route to a Mac the source cannot dial.** Requests sent back over the Mac's own connection, and pairing without a pair-back.
  Decision 1 already proves the redeemer's identity without a pair-back, which is half of what that route needs.
- **The two known gaps from #2370.** Report quoting misses the transcript's replay and completed-output boundaries, and a lost-turn check
  can race an in-flight send into one false wake.
