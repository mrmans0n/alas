# Peer pairing by approval implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Pair nearby Macs through a persistent Allow/Decline prompt, without copying codes.

**Architecture:** An application-owned coordinator stores pending approvals. A native HTTP client proves requester identity, waits for a local decision, and redeems a request-bound authorization through the existing reciprocal peer-pairing workflow. Shared window overlays render the coordinator's state.

**Tech stack:** Swift 6 strict concurrency, macOS 15+, SwiftUI, Observation, Foundation, CryptoKit, Swift Testing. These are the current project settings; no new dependencies.

**Spec:** [Approved design](2026-09-23-peer-pairing-approval-design.md).

## Global constraints

- "Requests wait for at most 120 seconds, with a visible remaining-time label."
- "Approval expires after 120 seconds from submission. Allow does not extend that deadline; redemption must happen before it."
- "Require valid persistent identity keys on both sides for this flow."
- "No remote callback to requester-advertised origins happens before Allow."
- "Persist only the peer and device records produced by successful pairing."
- "Keep the original selectable code and Copy pairing link fallback; add Copy code alongside the fallback code so long codes never have to be typed."
- "Preserve browser QR/link pairing and the current code-based /pair contract."
- "This preserves the current trusted-LAN/tailnet transport assumptions."
- Keep code, copy, and comments in English; use Swift Testing, not XCTest.
- Do not run the full local test plan. Do not add attribution to code, documentation, commits, or review text.
- Work in the current isolated worktree. Preserve unrelated changes. Regenerate `Alas.xcodeproj` with `rtk xcodegen generate` as source files are added and commit the generated project with its owning task. Do not modify `project.yml` unless source discovery actually requires it.

## Review focus

- A laptop sleeps past expiry: waking must not resurrect the prompt or approve a stale request. Task 2 tests advancing the clock beyond both deadlines.
- Bonjour returns a stale address first: a mismatched identity must not get a prompt or force legacy fallback. Task 5 tests multiple candidate origins.
- Both windows display Allow and the user clicks both: only one credential and one reciprocal attempt are created. Tasks 2 and 4 test duplicate decisions and redemption.
- Cancellation races with a lost successful HTTP reply: credentials from this attempt must be revoked, while established peer records survive. Task 4 tests cancellation before and after reply delivery.
- A name contains line breaks or directional controls: it must not disguise the action text or change the signed identity. Tasks 1 and 6 test display sanitization separate from raw signed fields.

## File and interface map

New production files live under `Alas/Sources/Remote/Pairing/` unless stated otherwise:

| File | Responsibility |
| --- | --- |
| `RemotePairingApprovalProtocol.swift` | Wire values, limits, canonical transcripts, signed envelope verification |
| `RemotePairingApprovalCoordinator.swift` | In-memory request lifecycle, local decisions, authorization consumption |
| `RemotePairingApprovalHTTP.swift` | Native route parsing, status codes, coordinator calls |
| `RemotePairingApprovalClient.swift` | Bounded requests, identity checks, polling and cancellation |
| `RemotePairingApprovalView.swift` | Shared prompt stack and request card |
| `Alas/Sources/App/AppState+PairingApproval.swift` | Lifecycle and outgoing-flow orchestration |

Existing integration points:

- `RemoteIdentityKey.swift`: add purpose-specific signing without exposing keys.
- `RemoteHTTPResponder.swift`, `RemoteServer.swift`: route new operations and expose optional capability.
- `RemotePairingService.swift`: issue a device credential from a validated approval, sharing the existing issuance helper.
- `RemotePeerManager.swift`: share reciprocal completion between code and approval initiation.
- `RemoteDiscoveredInstanceResolver.swift`: return capability and identity alongside origins without breaking `origins(for:)` callers.
- `AppState.swift`, `RootView.swift`, `SettingsWindow.swift`, `RemoteServerPane.swift`: ownership, lifecycle, UI.

New suites mirror production names under `AlasTests/Remote/`. Add integration coverage to existing peer-manager, responder, discovery, and AppState remote-access suites.

## Task 1: Define authenticated approval messages

**Files:** Create `RemotePairingApprovalProtocol.swift` and `AlasTests/Remote/RemotePairingApprovalProtocolTests.swift`. Modify `RemoteIdentityKey.swift` and `AlasTests/Remote/RemoteIdentityKeyTests.swift`.

**Interfaces:** Produce the following value types and signing interface. All wire structs conform to `Codable`, `Equatable`, and `Sendable`. The operation string selects both the route and signing purpose.

```swift
enum ApprovalOperation: String, Codable, Sendable {
    case challenge, submit, status, cancel, redeem
}
enum ApprovalPhase: String, Codable, Sendable {
    case challenged, pending, approved, redeeming, paired
    case declined, cancelled, expired, failed
}
struct ApprovalPeer: Codable, Equatable, Sendable {
    let serverID: String
    let publicKey: String
    let name: String
    let origins: [String]
}
struct ApprovalPayload: Codable, Equatable, Sendable {
    let operation: ApprovalOperation
    let requestID: String
    let requester: ApprovalPeer
    let receiver: ApprovalPeer
    let attemptNonce: String
    let operationNonce: String
    let challenge: String
    let expiresAtMilliseconds: Int64
    let phase: ApprovalPhase
    let counterCode: String?
    let responseDigest: String?
}
struct ApprovalEnvelope: Codable, Equatable, Sendable {
    let payload: ApprovalPayload
    let signature: String
}
@MainActor protocol ApprovalSigning {
    var publicKey: String { get }
    func signApproval(_ payload: ApprovalPayload, reply: Bool) -> String?
}
```

`ApprovalWire.domain(_:reply:) -> String` takes an `ApprovalOperation` and selects the signing domain.
`ApprovalWire.bytes(_:reply:) -> Data` takes an `ApprovalPayload` and produces deterministic bytes.
`ApprovalWire.verify(_:expectedKey:reply:) -> Bool` verifies a signature.
`ApprovalWire.displayName(_:) -> String` sanitizes presentation only.

- [ ] Add a deterministic-encoding test using a locally generated CryptoKit key. Construct one payload, encode twice, and assert equality. Add a field-mutation test for each payload field, including origins order, counter-code, and response digest. The test must verify the original signature fails for each altered payload.

```swift
@Test func requestAndReplyHaveDifferentSigningDomains() {
    #expect(ApprovalWire.domain(.submit, reply: false)
            != ApprovalWire.domain(.submit, reply: true))
    #expect(ApprovalWire.domain(.submit, reply: false)
            != ApprovalWire.domain(.redeem, reply: false))
}
```

- [ ] Run `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemotePairingApprovalProtocolTests test`. Confirm failure is caused by missing approval types, not build prerequisites.
- [ ] Implement a length-prefixed binary transcript, not concatenated unescaped strings or dictionary-order JSON. Encode strings as UTF-8 with UInt32 big-endian lengths; arrays include a count; optionals include a presence byte; integers use fixed big-endian Int64 representation. Use the declared field order. The domain is `alas.peer-approval.v1.<operation>.request` or `.reply`.

```swift
static func appendString(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    var length = UInt32(bytes.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(bytes)
}
```

- [ ] Extend `RemoteIdentityKeyProvider` to conform to `ApprovalSigning`, using its existing private key accessor and signing the canonical bytes. Leave existing `RemoteIdentitySigning` behavior intact. Validate all lengths before encoding. Require 32-byte Ed25519 public keys, 64-byte signatures, and 32-byte hex nonces/challenges. Cap each text field at 200 characters, origins at the existing eight-origin bound, and JSON at 16 KiB. Reject embedded control characters in IDs; strip control and Unicode bidi-formatting scalars only in `displayName`, without changing signed raw names.
- [ ] Add malformed-key, malformed-signature, oversized-fields, non-HTTP-origin, self-pairing, and display-name tests. Rerun the protocol and identity suites with two `-only-testing:` arguments. Commit as `feat: define authenticated peer approval messages`.

## Task 2: Implement the approval state machine

**Files:** Create `RemotePairingApprovalCoordinator.swift` and `AlasTests/Remote/RemotePairingApprovalCoordinatorTests.swift`.

**Interfaces:** Consume Task 1 types. Produce an `@MainActor @Observable` coordinator initialized with `localPeer: () -> ApprovalPeer`, `signer: any ApprovalSigning`, and `now: () -> Date`. Expose `entries: [Entry]` where `Entry` has `id`, `payload`, and `phase`. Define `ApprovalDecision { case allow, decline }` and `ApprovalFailure: Error` with cases `invalid`, `unauthorized`, `disabled`, `expired`, `conflict`, `throttled`, and `capacity`.

`ApprovalDecision` also conforms to `Equatable`. Public methods:

```swift
func setEnabled(_ enabled: Bool)
func challenge(requester: ApprovalPeer, attemptNonce: String) throws -> ApprovalEnvelope
func receive(_ envelope: ApprovalEnvelope) throws -> ApprovalEnvelope
func decide(_ decision: ApprovalDecision, requestID: String)
func expire()
func cancelAll()
```

`receive` handles submit/status/cancel, verifies signatures against stored immutable peers, and returns signed status plus the next operation challenge. Consuming a challenge and creating its replacement is atomic. Cache the reply for an exact authenticated retransmission so a lost reply is retryable; replay never reapplies an operation. A new operation must use the replacement challenge. Bound each request to one current challenge and one last-response cache entry.

- [ ] Add a table-driven clock test for deadline behavior and run the coordinator suite to confirm it fails before implementation.

```swift
@MainActor private struct TestApprovalSigner: ApprovalSigning {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    func signApproval(_ payload: ApprovalPayload, reply: Bool) -> String? {
        try? key.signature(for: ApprovalWire.bytes(payload, reply: reply))
            .base64EncodedString()
    }
}

@Test @MainActor func disabledCoordinatorRejectsChallenges() {
    let signer = TestApprovalSigner()
    let receiver = ApprovalPeer(serverID: "receiver", publicKey: signer.publicKey,
                                name: "Receiver", origins: ["http://192.168.1.2:8765"])
    let requesterSigner = TestApprovalSigner()
    let requester = ApprovalPeer(serverID: "requester", publicKey: requesterSigner.publicKey,
                                 name: "Requester", origins: ["http://192.168.1.3:8765"])
    let coordinator = RemotePairingApprovalCoordinator(
        localPeer: { receiver }, signer: signer,
        now: { Date(timeIntervalSince1970: 1_000) })
    coordinator.setEnabled(false)
    #expect(throws: ApprovalFailure.self) {
        try coordinator.challenge(requester: requester,
                                  attemptNonce: String(repeating: "a", count: 64))
    }
    #expect(coordinator.entries.isEmpty)
}
```

Use real signing keys in the lifecycle tests too. Do not mock verification itself.

- [ ] Implement transitions as explicit switches, including the local decision gate:

```swift
guard entry.phase == .pending else { return }
guard nowMilliseconds < entry.payload.expiresAtMilliseconds else {
    entry.phase = .expired
    return
}
entry.phase = decision == .allow ? .approved : .declined
```

- [ ] Implement the exact limits from the spec: 32 challenges/30 seconds, three pending prompts, one per requester key, five submissions per key/minute, ten globally/minute, 60-second decline cooldown, 64 terminal records/120 seconds. Limit status calls to one per second per request and return a two-second retry delay. Count a duplicate authenticated submission once. Expire records before capacity checks. Charge new challenge creation to the global admission limiter so generating new keys does not bypass it.
- [ ] Test duplicate submission, double Allow, Allow after Decline, deadline equality, wake after expiry, mutated identity, old challenge reuse, repeated polling, global key rotation, capacity cleanup, and disabling while approved. Check that no code/device/peer is created by any coordinator operation so far. Rerun the coordinator suite. Commit as `feat: track pending peer pairing approvals`.

## Task 3: Expose bounded native approval routes

**Files:** Create `RemotePairingApprovalHTTP.swift` and `AlasTests/Remote/RemotePairingApprovalHTTPTests.swift`. Modify `RemoteHTTPResponder.swift`, `RemoteServer.swift`, `RemoteDiscoveredInstanceResolver.swift`, and their existing tests.

**Interfaces:** `RemotePairingApprovalHTTP.response(for: HTTPRequest, body: Data) -> Data?` returns nil for unrelated routes. Inject the coordinator and an `enabled: () -> Bool` closure. Add `pairingApprovalVersion: Int? = nil` to diagnostics and its initializer. Advertise `1` only when all feature gates and persistent signing are available.

Routes are `POST /peer-approval/v1/challenge`, `/submit`, `/status`, and `/cancel`. The challenge request contains an `ApprovalPeer` and attempt nonce; all others contain an `ApprovalEnvelope`. Redemption remains a variant of `POST /pair` in Task 4.

- [ ] Write responder tests asserting 403 for any present Origin header, including empty and `null`; 413 above 16 KiB; 400 for malformed JSON; 405 for wrong methods; 429 with `Retry-After: 2` for throttling; 409 for capacity/conflicts; and signed terminal statuses on authenticated requests. Never include CORS headers on these routes. Run the new route suite and existing responder suite.
- [ ] Implement the routing guards before decoding or signature work:

```swift
guard req.headers["origin"] == nil else { return forbiddenResponse }
guard enabled() else { return forbiddenResponse }
guard req.method == "POST" else { return methodNotAllowedResponse }
guard body.count <= 16 * 1024 else { return tooLargeResponse }
```

Use `RemoteHTTPResponder.http` for response framing. Define each response locally with the specified HTTP status; do not return raw thrown error descriptions. Map invalid to 400, unauthorized to 401, disabled to 403, expired to 410, conflict/capacity to 409, and throttled to 429. The connection layer's existing Host policy still runs first.
- [ ] Add `ResolvedPeer` with `origins: [String]`, `serverID: String?`, and `pairingApprovalVersion: Int?`, and `resolvePeer(for:) async -> Result<ResolvedPeer, Failure>` to the resolver. Preserve `origins(for:)` as a projection. Decode absent capabilities as nil. Require the discovered ID to match diagnostics for approval; legacy peers retain current compatibility behavior.
- [ ] Test absent capabilities, disabled discovery, IPv6 origins, malformed bodies, and diagnostics compatibility. Run responder, approval HTTP, and resolver suites. Commit as `feat: expose native peer approval endpoints`.

## Task 4: Redeem approval through reciprocal pairing

**Files:** Modify the coordinator, `RemotePairingService.swift`, `RemotePeerManager.swift`, `RemoteHTTPResponder.swift`, `RemotePairingApprovalHTTP.swift`, and the corresponding coordinator, pairing, responder, and manager tests.

**Interfaces:** Define `ApprovalIssuedResponse` with `body: Data` and `deviceID: String`. Add `redeem(_ envelope: ApprovalEnvelope, issue: () throws -> ApprovalIssuedResponse) throws -> Data` to the coordinator. It returns the cached, signed pair response for an exact retry. Its issue closure runs once. The canonical payload's `responseDigest` binds the reply signature to the SHA-256 digest of the encoded legacy pair reply body. Encode the approval pair response as `ApprovalPairReply` with `pairBody: Data` and `proof: ApprovalEnvelope`; its body is the exact bytes hashed by `responseDigest`, avoiding re-encoding discrepancies.

Add `RemotePairingService.issueApprovedPeer(deviceName: String, peerServerId: String) -> RemotePeerRedeemResult`, callable only after validated approval. Extract the existing credential creation after code validation into a shared private helper.

Add a manager entry point:

```swift
func addApprovedPeer(
    expectedPeer: ApprovalPeer,
    redeem: (RemotePeerAdvertisement) async -> RemotePeerPairer.Outcome
) async -> AddError?
```

Both code and approved entry points call one private completion path. The closure receives the newly minted counter-code advertisement. Preserve the existing started-at, forget-generation, reciprocal confirmation, and rollback logic in that shared path.

- [ ] Add a coordinator redemption test that invokes the same signed request twice and asserts `issue` ran once and returned identical bytes. Add tests denying redemption for pending/declined/expired requests, wrong keys, modified origins/counter-code, and disabled settings. Run the focused suites before implementing.
- [ ] Extend `/pair` decoding with an optional `approval` envelope. Accept exactly one authorization mechanism, code or approval. Require a peer advertisement for approval, reject any Origin header for that variant, and enforce the 16 KiB bound. Verify advertisement identity/name/origins match the approved payload, and bind the fresh counter-code to its redeem signature. Never call ordinary `redeem(code:)` with an approval ID.
- [ ] Implement the atomic issue-once guard:

```swift
if let cached = exactAuthenticatedRetry(envelope) { return cached }
guard entry.phase == .approved else { throw ApprovalFailure.unauthorized }
entry.phase = .redeeming
do {
    let response = try issue()
    cacheRedeemResponse(response, for: envelope)
    return response.body
} catch {
    entry.phase = .failed
    throw error
}
```

The two helpers above are private coordinator methods: `exactAuthenticatedRetry(_:) -> Data?` verifies the full request digest/signature before returning the cached result; `cacheRedeemResponse(_:for:)` takes an `ApprovalIssuedResponse` and associates the request digest with its body and newly issued device ID for cleanup. The issue closure constructs the signed `ApprovalPairReply` bytes as the response body. Do not mark paired until the manager confirms the reciprocal exchange.
- [ ] Wire per-attempt completion/cancellation callbacks between manager and coordinator. Add `complete(requestID: String, succeeded: Bool)` and `onCancelRedeeming: ((String) -> Void)?` to the coordinator. Cancellation revokes this attempt's device and disconnects its sockets; guard every post-await manager publication against cancellation/forget generation. Never use broad `forget` to clean up a failed attempt if an older peer record exists. Cached credential responses are invalidated on cancellation, revocation, expiry, or configuration shutdown.
- [ ] Keep provisional approval-created device/peer records in memory until reciprocal success. Add a provisional flag to the shared issuance helper and make its store-save projection exclude those records until completion. Existing records remain persisted throughout. Add restart tests proving an unfinished approval leaves no durable credentials; legacy code pairing retains its current persistence behavior.
- [ ] Add manager tests for success on both sides, no success before reciprocal confirmation, pin mismatch, missing persistent key, lost initial reply, cancellation racing redemption, older record restoration, concurrent unrelated pairing, and Forget during the exchange. Ensure the approved return origins are still used at completion even if local addresses change while waiting; changed request metadata requires a new request. Run coordinator, pairing-service, manager, and responder suites. Commit as `feat: complete approved peer pairing reciprocally`.

## Task 5: Implement the requester and app lifecycle

**Files:** Create `RemotePairingApprovalClient.swift`, `AppState+PairingApproval.swift`, and `AlasTests/Remote/RemotePairingApprovalClientTests.swift`. Modify `AppState.swift` and `AlasTests/Remote/RemoteAppStateAccessTests.swift`.

**Interfaces:** Client initialization accepts the existing `RemotePeerPairer.Fetch`, `signer: any ApprovalSigning`, injected `now`, and `sleep: (Duration) async throws -> Void`. Define `ApprovalClientResult` cases `approved(ApprovalSession)`, `declined`, `cancelled`, `expired`, and `failed(ApprovalFailure)`. `ApprovalSession` stores the last signed payload, approved receiver key, and chosen origin without exposing credentials in descriptions.

```swift
func request(localPeer: ApprovalPeer, target: ResolvedPeer,
             expectedServerID: String) async -> ApprovalClientResult
func redeem(session: ApprovalSession,
            advertisement: RemotePeerAdvertisement) async -> RemotePeerPairer.Outcome
func cancel(session: ApprovalSession) async
```

AppState owns `remotePairingApprovals`, the client, and an outgoing Task handle. `startNearbyApproval(_ instance: RemoteDiscoveredInstance)` resolves capability and either starts the request or selects the legacy field. `cancelNearbyApproval()` cancels the Task and sends a bounded authenticated cancellation using its stored session.

- [ ] Use a scripted Fetch closure with real signed envelopes to test pending→approved, decline, expiry, cancellation, tampered replies, repeated nonce, mismatched server ID, first-origin failure, and old capability. Inject sleep so tests do not wait on real polling. Run the client suite before implementation.
- [ ] Implement four-second bounded requests and 16 KiB reply caps, with the existing bounded-fetch utility. Pin the challenge reply's verified receiver key for the entire attempt. Try candidate origins before a request is established; after submission use only the same proven identity and request ID. Never create independent prompts for each address.

```swift
while !Task.isCancelled {
    guard now() < deadline else { return .expired }
    let status = try await pollAuthenticatedSession()
    switch status.payload.phase {
    case .pending: try await sleep(.seconds(2))
    case .approved: return .approved(session)
    case .declined: return .declined
    case .cancelled: return .cancelled
    case .expired: return .expired
    default: return .failed(.conflict)
    }
}
return .cancelled
```

Define `pollAuthenticatedSession() async throws -> ApprovalEnvelope` privately to send the stored session with a fresh nonce, verify the reply against that nonce and pinned key, and replace the stored challenge. Exact retries reuse the original envelope; successful operations advance to a fresh challenge.
- [ ] Wire AppState configuration changes through one `syncPairingApprovalState()` function. It gates receiver operation on enabled/federation/discoverable and signing availability. Cancel incoming and outgoing attempts on shutdown and remote/federation disable; discoverability disable cancels incoming requests. Do not create an identity key just because a disabled feature's overlay renders. Initialize the coordinator with inert closures and request signing only when enabled.
- [ ] Test no outbound callback before approval, counter-code minted only after approval, task cancellation during sleep/fetch, and cancellation of pending/approved work on configuration changes. Preserve outgoing result state long enough for the UI to show errors. Run client and AppState remote-access suites. Commit as `feat: request peer pairing approval from nearby Macs`.

## Task 6: Add shared request cards and fallback copy controls

**Files:** Create `RemotePairingApprovalView.swift` and `AlasTests/Remote/RemotePairingApprovalPresentationTests.swift`. Modify `RootView.swift`, `SettingsWindow.swift`, and `RemoteServerPane.swift`.

**Interfaces:** `RemotePairingApprovalStack(coordinator:)` displays the shared coordinator. `RemotePairingApprovalCard(entry:allow:decline:)` renders one request. Extract presentation-only calculations into `ApprovalPresentation` with `title: String`, `detail: String`, `allowsDecision: Bool`, and `remainingSeconds: Int`, initialized with an Entry and current Date.

- [ ] Test presentation of pending, redeeming, expired, failed, long Unicode names, and names containing controls. Assert expiry disables Allow at zero seconds and that display sanitization does not alter signed fields. Run the presentation suite.
- [ ] Mount the stack on the outer content in both windows, within their theme environment, so it covers empty workspaces too:

```swift
.overlay(alignment: .bottomTrailing) {
    RemotePairingApprovalStack(coordinator: state.remotePairingApprovals)
        .frame(maxWidth: 380)
        .padding(16)
}
```

- [ ] Reuse `InAppNotificationBanner` visual values: background at 0.12 accent opacity over `bg-1`, 0.75-point border at 0.3 opacity, eight-point corner radius, and reduced-motion handling. Do not put approval entries into `InAppNotificationStore`. Use a one-second timeline for remaining time and coordinator expiry; no hover pause. Only cards intercept mouse events, not the empty overlay area. Avoid overlapping ordinary center-pane notifications by reserving their bottom inset while approval cards are visible.
- [ ] Render selectable names/details with `.textSelection(.enabled)`, wrapping text, explicit accessibility labels, and separate Allow and Decline buttons. The close button calls Decline. Do not assign `.defaultAction` to Allow. Disable decision controls once the coordinator leaves pending. Both windows call `decide` on the same request ID.
- [ ] Replace the first nearby Pair click with capability resolution and `startNearbyApproval`. Show outgoing waiting/progress/error state and Cancel; call `cancelNearbyApproval` when the initiating pane disappears. Keep unsupported peers' current code field. Add the fallback copy action using the existing `copyAddress` helper:

```swift
AlasButton(title: "Copy code", style: .subtle) {
    copyAddress(code)
}
```

- [ ] Run the presentation suite and `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`. Inspect both window sizes, light/dark themes, selectable text, keyboard focus, VoiceOver labels, and overlap with ordinary notifications. Commit as `feat: show peer pairing approval cards across windows`.

## Task 7: Verify the complete two-peer flow

**Files:** Create `AlasTests/Remote/RemotePairingApprovalIntegrationTests.swift`. Update `docs/manual-test.md` with the two-Mac acceptance steps from the spec. Update the design status to implemented only after the feature and required checks are complete.

- [ ] Build an in-memory two-peer fixture connecting the real client, HTTP responder, coordinator, pairing service, and manager. Use ephemeral signing keys, in-memory stores, and injected bounded fetch. The fixture exposes `request() async`, `allow()`, `decline()`, `cancel()`, `advanceClock(by:)`, `devicesA`, `devicesB`, `peersA`, and `peersB`; these call the actual production interfaces, not replacement state machines.

```swift
@Test @MainActor func requestDoesNotGrantAccessBeforeApproval() async {
    let pair = ApprovalPairFixture()
    let request = Task { await pair.request() }
    await pair.waitForPendingRequest()
    #expect(pair.devicesA.isEmpty && pair.devicesB.isEmpty)
    pair.decline()
    await request.value
    #expect(pair.peersA.isEmpty && pair.peersB.isEmpty)
}
```

`waitForPendingRequest()` waits on an explicit test signal emitted after submission; do not use polling sleeps. Define the fixture privately in this suite.
- [ ] Add end-to-end Allow with reciprocal records, drop-and-retry redeem reply, duplicate Allow from two views, shutdown while waiting, restart losing pending requests, cancellation after issuance, older-peer fallback, and code/browser regression scenarios. Assert each failed attempt leaves no extra device credentials or replacement peer records.
- [ ] Run `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemotePairingApprovalIntegrationTests test`. Run existing focused suites only if integration changes affected their implementation since their last passing run. Check `rtk git diff --check`.
- [ ] Perform the spec's two-Mac manual acceptance when two runnable instances are available. If unavailable, report those checks as unrun; do not claim the network/UI behavior was manually verified. Record exactly which local suites and builds ran, and any failures or limitations.
- [ ] Commit as `test: cover approval pairing across two peers`. Request a whole-branch review focused on authorization, rollback, and user-visible lifecycle, then fix confirmed findings and rerun the affected checks.

## Execution handoff

Review this plan before implementation. Recommended execution is subagent-driven,
with sequential implementation and review of each task: the signed protocol,
authorization state, and reciprocal rollback need independent checks. Tasks 1–6
share interfaces and should not be implemented concurrently. Native execution
in the current session is also available, followed by a whole-branch review.
