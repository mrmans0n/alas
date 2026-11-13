# Shared Remote Core for iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new SwiftPM target, `AlasRemoteKit`, that builds for iOS 26 and macOS 15 and holds the remote wire protocol, the value types it encodes, transcript row decoding, and the peer connection. The Mac keeps using the same code through it.

**Architecture:** `AlasRemoteKit` sits at the bottom of `Packages/AlasCore`, below `AlasFoundation`, which re-exports it so every existing module and the app see moved types unchanged. The protocol moves as-is except for the `.host`/`.peerHost` channel. That channel carries `HostClientMessage`/`HostServerMessage`, whose closure is most of the host domain model. So the two message enums become generic over the host payload. `AlasHostCore` pins them to the real host types with typealiases, so no Mac call site changes. The iOS app pins them to `OpaqueHostMessage`, which keeps the raw JSON. Logic that only a server or the Mac needs stays where it is, as extensions.

**Tech Stack:** Swift 6 tools (Swift 5 language mode as today), SwiftPM, Foundation, CryptoKit, URLSessionWebSocketTask, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-11-native-ios-app-design.md` (section "Platform and code sharing")

## Global Constraints

- `AlasRemoteKit` imports only Foundation, CryptoKit and Observation: no AppKit, UIKit, SwiftUI, `Process`, sqlite, Network.framework or tree-sitter.
- Package platforms: `.macOS(.v15)`, `.iOS("26.0")`.
- No wire change: the Mac app and `alas-host` keep serving the web client unchanged. `RemoteProtocolVersion` stays 1.
- `swift test --package-path Packages/AlasCore` keeps working without the app build.
- Anything the app or tests use from the package is `public`.
- Tests use Swift Testing and follow the AGENTS.md testing policy. Moves need no new tests; the existing suites are the proof.
- After editing `project.yml`, run `xcodegen` and commit both files. No agent attributions in commits.
- Conventional Commits, e.g. `refactor(remote): move the wire protocol into AlasRemoteKit`.

## Review Focus

1. A newer host sends a server message type this build doesn't know. The client must skip that frame and stay connected (Task 4 pins it).
2. A gateway Mac forwards a `peerHost` request to a phone. The phone must decode the frame (as `OpaqueHostMessage`), not drop the whole message or the connection (Task 2 pins it).
3. A Mac-encoded server message must decode identically through the iOS instantiation. Otherwise snapshot and transcript frames silently fail on the phone (Task 2's contract test).
4. Frames near the 16,000,000-byte WebSocket limit (big transcript windows) must get the same `maximumMessageSize` on iOS (Task 4 keeps the constant shared).
5. A change to an upper module that reintroduces a macOS-only API into `AlasRemoteKit` must fail CI, not the next iOS build (Task 1 adds the CI step).

---

### Task 1: Create `AlasRemoteKit` with the leaf value types and an iOS CI build

**Files:**
- Modify: `Packages/AlasCore/Package.swift` (new target at the bottom, `AlasFoundation` depends on it, add `.iOS("26.0")`)
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/` (moved files below)
- Create: `Packages/AlasCore/Sources/AlasFoundation/ReexportRemoteKit.swift` containing `@_exported import AlasRemoteKit`
- Move (whole file): `AlasFoundation/JSONRPC/JSONRPCMessages.swift` (`JSONRPCID`, `AnyCodable`)
- Move (whole file): `AlasPlatform/SSH/RemoteFileNode.swift`, `AlasHostCore/Remote/Forward/PeerPortForwardProtocol.swift`, `AlasHostCore/Remote/Console/PeerConsoleProtocol.swift`
- Move (types only, out of mixed files):
  - `ACPConfigValue` (AlasACP/ACP/Protocol/ACPConfigOption.swift:8), `ACPElicitationValue` (ACPElicitation.swift:263)
  - `MergeOperation`, `RebasePlan`, `RebasePlanCommit` (AlasModel/Model/GitTypes.swift:281–327)
  - `RepoHookConsent`, `RepoHookEvent`, and `PeerRepoHook`'s stored fields + Codable (AlasPlatform/RepoHooks/RepoHook.swift). `PeerRepoHook.init(_: RepoHook)` and `repoHook(fromHost:)` stay behind as an extension.
  - `WorktreeFileVersion` + `contentHash(of:)` (AlasPlatform/SSH/RemoteWorktreeFileAccess.swift:9)
  - `RemotePairingLink.maxOrigins` and `normalizeOrigin` (Pairing/RemotePairingLink.swift). Move the whole file if the rest is pure.
  - `WebSocketFrame.maxPayloadLength` becomes `public enum RemoteWireLimits { public static let maxFrameBytes = 16_000_000 }`. `WebSocketFrame.maxPayloadLength` returns it.
- Hoist: `AppConfig.Changes.ChangesComparisonMode` (AppConfig.swift:590) to top-level `ChangesComparisonMode` in AlasRemoteKit, leaving `public typealias ChangesComparisonMode = AlasRemoteKit.ChangesComparisonMode` inside `AppConfig.Changes`.
- Modify: `.github/workflows/build.yml` (next to the `swift test --package-path Packages/AlasCore` step at :133)
- Modify: `AGENTS.md` (one bullet under Development rules)

**Interfaces:**
- Produces: module `AlasRemoteKit`. Every type listed above is `public`, with the same name and members as before, reachable from every module through `AlasFoundation`'s re-export. `RemoteWireLimits.maxFrameBytes: Int`.

- [ ] **Step 1: Add the target and move the files and types listed above.** Add `import AlasRemoteKit` wherever the compiler asks. Keep each moved type byte-for-byte except for the access changes it needs.
- [ ] **Step 2: Build the package for iOS.**
  Run: `cd Packages/AlasCore && xcodebuild -scheme AlasRemoteKit -destination 'generic/platform=iOS Simulator' -quiet build > /tmp/remotekit-ios.log 2>&1; echo $?`
  Expected: `0`. If it fails, a moved type uses a macOS-only API. Split that member out into an extension in its old module.
- [ ] **Step 3: Run the core tests.**
  Run: `swift test --package-path Packages/AlasCore > /tmp/core-test.log 2>&1; grep -E "Test run with|failed" /tmp/core-test.log`
  Expected: `Test run with N tests … passed`, no failures.
- [ ] **Step 4: Build the Mac app.**
  Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build > /tmp/alas-build.log 2>&1; grep -c "BUILD SUCCEEDED\|error:" /tmp/alas-build.log`
  Expected: no `error:` lines.
- [ ] **Step 5: Add the CI step.** In `build.yml`, add a step "Build AlasRemoteKit for iOS" running the Step 2 command, so an iOS-breaking change fails CI.
- [ ] **Step 6: Add the AGENTS.md rule.** Add one bullet: "`AlasRemoteKit` must build for iOS: Foundation, CryptoKit and Observation only; put macOS-only members in an extension in the module above."
- [ ] **Step 7: Commit:** `refactor(core): add AlasRemoteKit with the remote value types`

### Task 2: Move the wire protocol, with a generic host channel

**Files:**
- Move: `AlasHostCore/Remote/Protocol/RemoteProtocol.swift`, `RemoteMessageWireJSON.swift`, `RemotePairingApprovalProtocol.swift` into `AlasRemoteKit/Protocol/`
- Move: `HostFileHistoryEntry` (Core/HostProtocol.swift:428) into `AlasRemoteKit/Protocol/`
- Create: `AlasRemoteKit/Protocol/OpaqueHostMessage.swift`
- Create: `AlasHostCore/Remote/Protocol/RemoteProtocol+Host.swift` (typealiases + server-only members)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/RemoteWireCompatibilityTests.swift`

**Interfaces:**
- Consumes: Task 1's types.
- Produces:
  - `public enum RemoteClientMessageOf<HostRequest: Codable & Equatable & Sendable, HostReply: Codable & Equatable & Sendable>` with `case host(HostRequest)` and `case peerHost(HostReply)`. Every other case is unchanged. Relax the constraints to whatever `HostClientMessage`/`HostServerMessage` actually conform to.
  - `public enum RemoteServerMessageOf<HostReply, HostRequest>` (same constraints) with `case host(HostReply)` and `case peerHost(HostRequest)`.
  - In AlasHostCore:
    - `public typealias RemoteClientMessage = RemoteClientMessageOf<HostClientMessage, HostServerMessage>`
    - `public typealias RemoteServerMessage = RemoteServerMessageOf<HostServerMessage, HostClientMessage>`
  - `public struct OpaqueHostMessage: Codable, Equatable, Sendable { public let json: Data }`. It decodes any JSON value, re-encodes it unchanged, and keeps the payload as sorted-keys JSON `Data`.
  - These stay in AlasHostCore as extensions:
    - `RemoteServerIdentity` defaults that read server capability lists
    - `RemoteServerMessage.hello(_:)`, `HostProtocolCapability.served`/`headlessOnly`
    - `RemoteVisualAid.init(_ ACPVisualAid)`
    - `RemoteWireMessage.transportByteCount`/`boundedForTransport`
    - `RemoteServerIdentity`'s defaults: the struct moves, and its defaulted initializer moves to an extension.
- Known risk: `HostResponse.worktreeRead(reply: RemoteServerMessage)` (HostProtocol.swift:708, `indirect`) makes the generic recursive. If Swift rejects it, fall back to:
  - non-generic enums with `case host(OpaqueHostMessage)`/`case peerHost(OpaqueHostMessage)`
  - typed accessors in AlasHostCore (`var hostMessage: HostClientMessage?` and `static func host(_ HostClientMessage) -> Self`)
  - only the Mac call sites the compiler flags get updated

  Note the choice in the commit message.

- [ ] **Step 1: Write the failing contract test**

```swift
import Testing
import Foundation
@testable import AlasCore

@Suite struct RemoteWireCompatibilityTests {
    typealias PhoneServerMessage = RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>
    typealias PhoneClientMessage = RemoteClientMessageOf<OpaqueHostMessage, OpaqueHostMessage>

    // Pick ~6 server messages that a phone receives: a snapshot/session list,
    // a transcript delta with tool-call rows, a permission request, a queue
    // update, a `host` reply, and a `peerHost` request.
    @Test(arguments: RemoteWireSamples.serverMessages)
    func macEncodedServerMessageDecodesOnThePhone(_ message: RemoteServerMessage) throws {
        let data = try JSONEncoder.sorted.encode(message)
        let phone = try JSONDecoder().decode(PhoneServerMessage.self, from: data)
        #expect(try JSONEncoder.sorted.encode(phone) == data)
    }

    // ~6 client messages a phone sends: sendPrompt with attachments,
    // permissionDecision, questionAnswer, queueMove, setConfigOption, subscribe.
    @Test(arguments: RemoteWireSamples.clientMessages)
    func phoneEncodedClientMessageDecodesOnTheMac(_ message: RemoteClientMessage) throws {
        let data = try JSONEncoder.sorted.encode(message)
        let phone = try JSONDecoder().decode(PhoneClientMessage.self, from: data)
        let back = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder.sorted.encode(phone))
        #expect(back == message)
    }
}
```

`JSONEncoder.sorted` is a test-local `static let` with `.sortedKeys`. `RemoteWireSamples` is a test-local enum holding the sample values; reuse builders from `HostProtocolServerTests` where they exist.

- [ ] **Step 2: Run it to verify it fails**
  Run: `swift test --package-path Packages/AlasCore --filter RemoteWireCompatibilityTests`
  Expected: compile error, `cannot find 'RemoteServerMessageOf'`.
- [ ] **Step 3: Move the files and make the enums generic.** Write the AlasHostCore typealiases and extensions as described in Interfaces.
- [ ] **Step 4: Run the contract test, then the full core tests.**
  Run Task 1 Step 3's command.
  Expected: everything passes, including `RemoteWireCompatibilityTests` with 12 cases.
- [ ] **Step 5: Build for iOS and run the app's protocol suites.**
  Run Task 1 Step 2's command, then: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/RemoteProtocolTests -only-testing AlasTests/RemotePairingApprovalProtocolTests -only-testing AlasTests/RemoteMessageSessionScopeTests test > /tmp/alas-proto.log 2>&1`
  Expected: iOS build exits 0. The ✔ lines for 111 tests and no ✘ (read the Swift Testing lines, not the XCTest "Executed 0 tests" summary).
- [ ] **Step 6: Commit:** `refactor(remote): move the wire protocol into AlasRemoteKit`

### Task 3: Move the transcript value types and row decoding

**Files:**
- Hoist into `AlasRemoteKit/Transcript/`. Each type keeps a nested `public typealias` in `ACPMessage` so callers don't change.
  - `ACPMessage.ToolCall` → `ACPToolCall`
  - `ACPMessage.ToolCallAsset` → `ACPToolCallAsset`
  - `ACPMessage.FileEdit` → `ACPFileEdit`
  - `ACPMessage.PlanItem` → `ACPPlanItem`
  - `ACPMessage.Attachment` → `ACPAttachment`, only if `RemoteWireMessage` or row decoding needs it
  - all from AlasSessions/ACP/Session/ACPMessage.swift
- Move: `ACPPlanDocument` (AlasSessions/ACP/Session/ACPPlanDocument.swift) and `ACPVisualAid` (AlasACP/ACP/Session/ACPVisualAid.swift) types. Any member that needs session or app logic stays as an extension in its old module.
- Create: `AlasRemoteKit/Transcript/RemoteTranscriptRow.swift`. This is the body of `NativePeerRow` (Alas/Sources/Remote/Native/NativePeerTranscriptPresentation.swift:6–94), made `public`.
- Modify: `NativePeerTranscriptPresentation.swift`, replacing the enum with `typealias NativePeerRow = RemoteTranscriptRow`.
- Test: `AlasTests/Remote/NativePeerTranscriptTests.swift`, existing and unchanged.

**Interfaces:**
- Consumes: `RemoteWireMessage` (Task 2), `AnyCodable` (Task 1).
- Produces:
  - `public enum RemoteTranscriptRow: Equatable` with the same cases as `NativePeerRow` today
  - `public init(message: RemoteWireMessage)`
  - `ACPToolCall`, `ACPFileEdit`, `ACPPlanItem`, `ACPPlanDocument` and `ACPVisualAid`, all public, with Codable output unchanged
  - Methods that mutate streaming state (`apply…`, preview computation) stay in AlasSessions as `extension ACPToolCall` unless they're pure. Pure ones may move.

- [ ] **Step 1: Hoist and move the types; add the typealiases.** Add `RemoteTranscriptRow`.
- [ ] **Step 2: Build for iOS** with Task 1 Step 2's command. Expected: `0`.
- [ ] **Step 3: Run the core tests** with Task 1 Step 3's command. Expected: all pass.
- [ ] **Step 4: Run the transcript suites.**
  Run: `xcodebuild … -only-testing AlasTests/NativePeerTranscriptTests test`, with the same flags as Task 2 Step 5, plus any ACP message codec suite the grep `ACPMessageCodec` finds in AlasTests.
  Expected: all ✔.
- [ ] **Step 5: Commit:** `refactor(remote): share transcript row decoding through AlasRemoteKit`

### Task 4: Move the peer connection

**Files:**
- Move: `AlasHostCore/Remote/Peer/RemotePeerConnection.swift` into `AlasRemoteKit/Connection/`
- Split: `AlasHostCore/Remote/Identity/RemoteIdentityKey.swift`. `RemoteIdentityCrypto` (pure CryptoKit) moves. `RemoteIdentityKeyProvider` and `RemoteSecretStore` (keychain) stay.
- Modify: `AlasHostCore`. Add `public typealias RemotePeerConnection = RemotePeerConnectionOf<HostClientMessage, HostServerMessage>` (or keep the name if Task 2 took the fallback).
- Test: `AlasTests/Remote/RemotePeerConnectionTests.swift` (existing suite; add one test)

**Interfaces:**
- Consumes: the Task 2 message enums, `RemoteWireLimits.maxFrameBytes`.
- Produces: `@MainActor public final class RemotePeerConnectionOf<HostRequest, HostReply>`. Its public API is the same as today's `RemotePeerConnection`, decoding `RemoteServerMessageOf<HostReply, HostRequest>`. Its `URLSessionWebSocketTask` sets `maximumMessageSize = RemoteWireLimits.maxFrameBytes`.

- [ ] **Step 1: Write the failing test** in `RemotePeerConnectionTests`, reusing the suite's existing fake-server fixture:

```swift
@Test func unknownServerMessageTypeIsSkippedAndTheConnectionStaysUp() async throws {
    // Fake server sends {"type":"fromTheFuture"} then a valid known frame.
    // Expect: the known frame is delivered and the state is still connected.
}
```

Fill in the body with the suite's fixture. Assert that the known frame arrives and the state is connected.
- [ ] **Step 2: Run it.** Expected: it passes before the move, because the `try? … continue` at RemotePeerConnection.swift:393/419 already handles it. It pins that behavior now that phones meet newer hosts. If it fails, fix the skip.
- [ ] **Step 3: Move the connection and the crypto.** Make the connection generic as described in Interfaces.
- [ ] **Step 4: Build for iOS** with Task 1 Step 2's command. Expected: `0`.
- [ ] **Step 5: Run the core tests** (Task 1 Step 3), then `-only-testing AlasTests/RemotePeerConnectionTests -only-testing AlasTests/RemoteIdentityCryptoTests -only-testing AlasTests/RemotePeerManagerTests`.
  Expected: all ✔, with the new test among them.
- [ ] **Step 6: Commit:** `refactor(remote): move the peer connection into AlasRemoteKit`

---

## Out of scope here, picked up by later plans

- Moving `NativePeerTranscript`, `NativePeerComposerState`, `NativePeerRequestBridge` and `NativePeerNewSession`. Plan 3 moves each one when the iOS app first needs it, so nothing moves without a second user.
- Pairing with a phone identity key, and the `mobileApp` device kind (plan 4).
- An iOS app target in `project.yml` (plan 2, the transcript spike, creates it).
