# Federation Phase 1: Mac-to-Mac Peer Trust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two Macs running Alas can pair with each other by pasting one pairing link, hold a live authenticated WebSocket to each other, and show that link's state in Settings → Remote, all behind an experiment flag.

**Architecture:** Everything sits on top of PR #1337 (`nacho/pwa`). The server side gains an optional `peer` object on `POST /pair` that makes pairing reciprocal, a `kind` on device records, and an optional `helloAck` client message. The client side is new Swift: a peer store holding outbound tokens, an HTTP pairer, a `URLSessionWebSocketTask` connection that mirrors `hub-links.js`, and a manager that owns both. No session data crosses the link yet; that is the next plan (`FederatedSessionsProvider`).

**Tech Stack:** Swift 5.9, SwiftUI (macOS), `Network.framework` server already in place, `URLSession` for the outbound side, Swift Testing (`import Testing`), in-process `RemoteServer` for integration tests.

**Spec:** `docs/plans/2026-09-19-multi-instance-federation-design.md` (sections "Relationship to PR #1337", "2. Trust", "Protocol handshake", "Feature flag", "Rollout" steps 1 and 2). The web-client hub it builds on is specified in `docs/superpowers/specs/2026-09-19-remote-hub-multi-server-design.md`.

## Global Constraints

- Base branch: `nacho/pwa` (PR #1337). Branch from it; do not start from `main` until #1337 merges. All `path:line` references below are to the `nacho/pwa` versions of files.
- Protocol version stays `RemoteProtocolVersion.current = 1`. Every new wire field is optional on decode.
- `AppConfig.Remote` fields decode with `(try? c.decode(...)) ?? default`, matching `AppConfig.swift:800-810`.
- Device records on disk (`remote-devices.json`) must still decode when written by a pre-federation build: new keys are optional with defaults.
- Identity field name is `serverId` everywhere. Never `instanceId`.
- The proxying Mac is called a "gateway" in prose; "hub" is the #1337 browser client. No UI string in this plan uses either word.
- Tokens for outbound peers are stored in plaintext in `remote-peers.json` under Application Support, the same posture as the browser's `localStorage`. Never log them.
- Tests use `import Testing`, never XCTest. Run only the suites named in each task; CI runs the rest.
- **Any task that creates a new file must run `xcodegen` and commit the
  regenerated `Alas.xcodeproj` with its sources.** `project.yml` declares
  `sources: - path: AlasTests`, but xcodegen expands that into explicit file
  references in `project.pbxproj`. A new file that is not regenerated in is
  never compiled: a new source file silently drops out of the target, and a
  new test file makes `-only-testing AlasTests/<NewSuite>` match nothing.
  xcodebuild then prints `** TEST SUCCEEDED **` over `Executed 0 tests` — a
  false green. After regenerating, confirm the suite really ran by checking
  the Swift Testing tail line (`Test run with N tests in M suites passed`)
  names every suite you selected, not just the pre-existing ones.
- Commits carry no agent attribution of any kind (see `CLAUDE.md`).
- Code, comments, log strings, and UI strings are English.

Run a focused suite with:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/<SuiteName> test > /tmp/alas-test.log 2>&1; grep -E "TEST (SUCCEEDED|FAILED)" /tmp/alas-test.log
```

Build only with:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build > /tmp/alas-build.log 2>&1; echo exit=$?
```

---

## File map

Create:

- `Alas/Sources/Remote/Pairing/RemotePeer.swift` — `RemotePeer` model, `RemotePeerStore` protocol, `FilePeerStore`.
- `Alas/Sources/Remote/Pairing/RemotePeerAdvertisement.swift` — the `peer` object on `/pair` and the `RemotePeerPairingRequest` the server hands to the app.
- `Alas/Sources/Remote/Peer/RemotePeerPairer.swift` — outbound `POST /pair` with origin fallback.
- `Alas/Sources/Remote/Peer/RemotePeerConnection.swift` — outbound WebSocket link.
- `Alas/Sources/Remote/Peer/RemotePeerManager.swift` — owns peers and connections; add, forget, inbound reciprocal pairing.
- `AlasTests/Remote/RemoteDeviceTests.swift`
- `AlasTests/Remote/RemotePeerStoreTests.swift`
- `AlasTests/Remote/RemotePeerPairerTests.swift`
- `AlasTests/Remote/RemotePeerConnectionTests.swift`
- `AlasTests/Remote/RemotePeerManagerTests.swift`

Modify:

- `Alas/Sources/Persistence/AppConfig.swift:58-118` — `federationEnabled`.
- `Alas/Sources/Persistence/Paths.swift:88-92` — `remotePeersFile`.
- `Alas/Sources/Remote/Protocol/RemoteProtocol.swift` — `RemoteServerIdentity.federationEnabled`, `hello.federationEnabled`, `RemoteClientMessage.helloAck`.
- `Alas/Sources/Remote/Pairing/RemoteDevice.swift` — `kind`, `peerServerId`.
- `Alas/Sources/Remote/Pairing/RemotePairingService.swift:57-73` — `redeemPeer`.
- `Alas/Sources/Remote/Pairing/RemotePairingLink.swift` — `parse`.
- `Alas/Sources/Remote/Server/RemoteHTTPResponder.swift:87-97` — `peer` on `/pair`, identity in the reply, `acceptsPeers`, `onPeerPaired`.
- `Alas/Sources/Remote/Server/RemoteServer.swift:178-222` — forward `onPeerPaired` and `acceptsPeers`.
- `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift:52` — ignore `helloAck`.
- `Alas/Sources/App/AppState.swift:455-640` — `remotePeers`, identity, `syncRemotePeers`.
- `Alas/Sources/Settings/AdvancedPane.swift:47-62` — toggle.
- `Alas/Sources/Remote/Settings/RemoteServerPane.swift` — Peers group.

---

### Task 1: `federationEnabled` flag, identity, and `hello` field

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift:58-118`
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift:6-15, 361, 414-423, 428-433, 602-607, 781-789`
- Modify: `Alas/Sources/App/AppState.swift:540-544`
- Modify: `Alas/Sources/Settings/AdvancedPane.swift:47-62`
- Test: `AlasTests/Remote/RemoteConfigTests.swift`, `AlasTests/Remote/RemoteProtocolTests.swift`, `AlasTests/Remote/RemoteServerIntegrationTests.swift`

**Interfaces:**
- Produces: `AppConfig.Remote.federationEnabled: Bool`; `RemoteServerIdentity.init(serverId:name:hubEnabled:federationEnabled: = false)`; `RemoteServerMessage.hello(protocolVersion:serverId:name:hubEnabled:federationEnabled: = false)`.

- [ ] **Step 1: Write the failing config tests**

Append to `AlasTests/Remote/RemoteConfigTests.swift`:

```swift
    @Test func federationDefaultsOffAndRoundTrips() throws {
        #expect(AppConfig.defaults.remote.federationEnabled == false)
        var cfg = AppConfig.defaults
        cfg.remote.federationEnabled = true
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(cfg))
        #expect(back.remote.federationEnabled == true)
    }

    @Test func oldRemoteConfigWithoutFederationKeyDecodesFalse() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var remote = try #require(json["remote"] as? [String: Any])
        remote.removeValue(forKey: "federationEnabled")
        json["remote"] = remote
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.remote.federationEnabled == false)
    }
```

- [ ] **Step 2: Write the failing protocol tests**

Append to `AlasTests/Remote/RemoteProtocolTests.swift` inside the struct:

```swift
    @Test func helloEncodesFederationEnabledAndDefaultsItOff() throws {
        let on = RemoteServerMessage.hello(RemoteServerIdentity(serverId: "s", name: "n", hubEnabled: false, federationEnabled: true))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(on)) as? [String: Any])
        #expect(object["federationEnabled"] as? Bool == true)

        let legacy = Data(#"{"type":"hello","protocolVersion":1,"serverId":"s","name":"n","hubEnabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: legacy)
        #expect(decoded == .hello(protocolVersion: 1, serverId: "s", name: "n", hubEnabled: false, federationEnabled: false))
    }
```

- [ ] **Step 3: Write the failing integration test**

Append to `AlasTests/Remote/RemoteServerIntegrationTests.swift` next to `helloIsTheFirstFrameAfterUpgrade` (line 167):

```swift
    @Test func helloCarriesFederationEnabled() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: FakeSessionsProvider(),
            identity: { RemoteServerIdentity(serverId: "srv-1", name: "Test Mac", hubEnabled: false, federationEnabled: true) }
        )
        try server.start(port: 0)
        defer { server.stop() }
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!, protocols: [token])
        task.resume()
        let first = try await receiveServerMessage(task)
        #expect(first == .hello(protocolVersion: RemoteProtocolVersion.current, serverId: "srv-1", name: "Test Mac", hubEnabled: false, federationEnabled: true))
        task.cancel(with: .goingAway, reason: nil)
    }
```

- [ ] **Step 4: Run the three suites to confirm they fail to compile**

Run: the focused-suite command with `-only-testing AlasTests/RemoteConfigTests -only-testing AlasTests/RemoteProtocolTests -only-testing AlasTests/RemoteServerIntegrationTests`.
Expected: build error, `federationEnabled` unknown.

- [ ] **Step 5: Add the config field**

In `AppConfig.swift`, inside `struct Remote`, after `var hubEnabled: Bool = false` (line 73):

```swift
        /// Experiment: lets this Mac pair with other Macs running Alas.
        var federationEnabled: Bool = false
```

Add `federationEnabled: Bool = false` as the last `init` parameter and `self.federationEnabled = federationEnabled` in its body. Add `federationEnabled` to the second `CodingKeys` line. In `init(from:)` add:

```swift
            federationEnabled = (try? c.decode(Bool.self, forKey: .federationEnabled)) ?? false
```

- [ ] **Step 6: Extend the identity and `hello`**

Replace `RemoteServerIdentity` (`RemoteProtocol.swift:11-15`) with:

```swift
struct RemoteServerIdentity: Equatable, Sendable {
    let serverId: String
    let name: String
    let hubEnabled: Bool
    let federationEnabled: Bool

    init(serverId: String, name: String, hubEnabled: Bool, federationEnabled: Bool = false) {
        self.serverId = serverId
        self.name = name
        self.hubEnabled = hubEnabled
        self.federationEnabled = federationEnabled
    }
}
```

Change the case at line 361 to:

```swift
    case hello(protocolVersion: Int, serverId: String, name: String, hubEnabled: Bool, federationEnabled: Bool = false)
```

Add `federationEnabled` to the last `CodingKeys` line (line 421). Decode (line 428):

```swift
        case "hello":
            self = .hello(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                serverId: try c.decode(String.self, forKey: .serverId),
                name: try c.decode(String.self, forKey: .name),
                hubEnabled: try c.decodeIfPresent(Bool.self, forKey: .hubEnabled) ?? false,
                federationEnabled: try c.decodeIfPresent(Bool.self, forKey: .federationEnabled) ?? false)
```

Encode (line 602):

```swift
        case .hello(let protocolVersion, let serverId, let name, let hubEnabled, let federationEnabled):
            try c.encode("hello", forKey: .type)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(serverId, forKey: .serverId)
            try c.encode(name, forKey: .name)
            try c.encode(hubEnabled, forKey: .hubEnabled)
            try c.encode(federationEnabled, forKey: .federationEnabled)
```

Helper (line 781):

```swift
extension RemoteServerMessage {
    static func hello(_ identity: RemoteServerIdentity) -> RemoteServerMessage {
        .hello(
            protocolVersion: RemoteProtocolVersion.current,
            serverId: identity.serverId,
            name: identity.name,
            hubEnabled: identity.hubEnabled,
            federationEnabled: identity.federationEnabled)
    }
}
```

- [ ] **Step 7: Report the flag from the app**

`AppState.swift:540-544`:

```swift
    func remoteServerIdentity() -> RemoteServerIdentity {
        RemoteServerIdentity(
            serverId: config.remote.serverId,
            name: remoteDisplayName,
            hubEnabled: config.remote.hubEnabled,
            federationEnabled: config.remote.federationEnabled
        )
    }
```

- [ ] **Step 8: Add the toggle**

In `AdvancedPane.swift` directly after the "Remote hub" row (line 62):

```swift
                    SettingsRow(
                        name: "Remote peers",
                        desc: "Lets this Mac pair with other Macs running Alas so each can see the other's sessions."
                    ) {
                        AlasToggle(on: Binding(
                            get: { state.config.remote.federationEnabled },
                            set: { enabled in
                                state.config.remote.federationEnabled = enabled
                                state.saveConfig()
                                state.remoteServer?.broadcastHello()
                            }
                        ))
                    }
```

(Task 11 adds `state.syncRemotePeers()` to this setter once it exists.)

- [ ] **Step 9: Run the three suites**

Same command as Step 4. Expected: `TEST SUCCEEDED`, and the two existing `hello` equality tests at `RemoteServerIntegrationTests.swift:186,214,219` still pass because the default associated value fills `federationEnabled`.

- [ ] **Step 10: Commit**

```bash
git add Alas/Sources/Persistence/AppConfig.swift Alas/Sources/Remote/Protocol/RemoteProtocol.swift Alas/Sources/App/AppState.swift Alas/Sources/Settings/AdvancedPane.swift AlasTests/Remote/RemoteConfigTests.swift AlasTests/Remote/RemoteProtocolTests.swift AlasTests/Remote/RemoteServerIntegrationTests.swift
git commit -m "feat(remote): add the federation experiment flag and report it in hello"
```

---

### Task 2: `helloAck` client message

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift:39-74, 77, 94-97, 183-205`
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift:52-54`
- Test: `AlasTests/Remote/RemoteProtocolTests.swift`, `AlasTests/Remote/RemoteSessionGatewayTests.swift`

**Interfaces:**
- Produces: `RemoteClientMessage.helloAck(protocolVersion: Int)`. Servers ignore it. Only `RemotePeerConnection` (Task 8) sends it.

- [ ] **Step 1: Write the failing tests**

`RemoteProtocolTests.swift`:

```swift
    @Test func helloAckRoundTripsAndEncodesType() throws {
        let ack = RemoteClientMessage.helloAck(protocolVersion: 1)
        #expect(try roundTrip(ack) == ack)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ack)) as? [String: Any])
        #expect(object["type"] as? String == "helloAck")
        #expect(object["protocolVersion"] as? Int == 1)
        #expect(ack.isControl == false)
        #expect(ack.fileRequestDedupKey == nil)
        #expect(ack.isDriveOrdering == false)
    }
```

`RemoteSessionGatewayTests.swift`, next to `listSessionsEmitsSummaries` (line 398):

```swift
    @Test func helloAckIsAcceptedAndSendsNothing() async {
        let provider = FakeSessionsProvider()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.helloAck(protocolVersion: 1))
        await Task.yield()
        #expect(sent.isEmpty)
        #expect(provider.sessionSummariesCallCount == 0)
    }
```

- [ ] **Step 2: Run to confirm compile failure**

Run with `-only-testing AlasTests/RemoteProtocolTests -only-testing AlasTests/RemoteSessionGatewayTests`. Expected: `helloAck` unknown.

- [ ] **Step 3: Add the case**

`RemoteProtocol.swift`, first line inside `enum RemoteClientMessage` (before `case listSessions`):

```swift
    /// Sent by Alas peer connections after the server's `hello`. Browsers
    /// never send it and servers never wait for it.
    case helloAck(protocolVersion: Int)
```

Add `protocolVersion` to the `CodingKeys` list at line 77. Decode, before `case "listSessions"`:

```swift
        case "helloAck": self = .helloAck(protocolVersion: try c.decode(Int.self, forKey: .protocolVersion))
```

Encode, before `case .listSessions`:

```swift
        case .helloAck(let protocolVersion):
            try c.encode("helloAck", forKey: .type)
            try c.encode(protocolVersion, forKey: .protocolVersion)
```

- [ ] **Step 4: Ignore it in the gateway**

`RemoteSessionGateway.swift:52`, first case of `switch message`:

```swift
        case .helloAck:
            // Version acknowledgement from an Alas peer; nothing to do server-side.
            break
```

- [ ] **Step 5: Run the two suites**

Expected: `TEST SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Protocol/RemoteProtocol.swift Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift AlasTests/Remote/RemoteProtocolTests.swift AlasTests/Remote/RemoteSessionGatewayTests.swift
git commit -m "feat(remote): add the optional helloAck client message"
```

---

### Task 3: Device `kind` and `peerServerId`

**Files:**
- Modify: `Alas/Sources/Remote/Pairing/RemoteDevice.swift`
- Create: `AlasTests/Remote/RemoteDeviceTests.swift`

**Interfaces:**
- Produces: `enum RemoteDeviceKind: String { case browser, alasInstance }`; `RemoteDevice.init(id:name:tokenHash:createdAt:lastSeenAt:kind: = .browser, peerServerId: = nil)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Alas

struct RemoteDeviceTests {
    @Test func preFederationRecordDecodesAsBrowser() throws {
        let json = Data(#"{"id":"d1","name":"iPhone","tokenHash":"ab","createdAt":"2026-01-02T03:04:05Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let device = try decoder.decode(RemoteDevice.self, from: json)
        #expect(device.kind == .browser)
        #expect(device.peerServerId == nil)
        #expect(device.lastSeenAt == nil)
    }

    @Test func peerRecordRoundTrips() throws {
        let device = RemoteDevice(id: "d2", name: "Studio", tokenHash: "cd", createdAt: Date(timeIntervalSince1970: 1),
                                  lastSeenAt: nil, kind: .alasInstance, peerServerId: "srv-b")
        let data = try JSONEncoder().encode(device)
        let back = try JSONDecoder().decode(RemoteDevice.self, from: data)
        #expect(back == device)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "alasInstance")
        #expect(object["peerServerId"] as? String == "srv-b")
    }
}
```

- [ ] **Step 2: Run to confirm failure**

`-only-testing AlasTests/RemoteDeviceTests`. Expected: `kind` unknown.

- [ ] **Step 3: Replace the struct**

`RemoteDevice.swift`, replace lines 3-9 with:

```swift
enum RemoteDeviceKind: String, Codable, Equatable, Sendable {
    case browser
    case alasInstance
}

struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    let id: String          // UUID
    var name: String
    var tokenHash: String   // hex SHA-256 of the token; plaintext never stored
    var createdAt: Date
    var lastSeenAt: Date?
    /// Browsers and the web client are `.browser`; another Mac running Alas
    /// that paired here is `.alasInstance`.
    var kind: RemoteDeviceKind
    /// For `.alasInstance` devices, the peer's advertised `serverId`.
    var peerServerId: String?

    init(id: String, name: String, tokenHash: String, createdAt: Date, lastSeenAt: Date?,
         kind: RemoteDeviceKind = .browser, peerServerId: String? = nil) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.kind = kind
        self.peerServerId = peerServerId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tokenHash, createdAt, lastSeenAt, kind, peerServerId
    }

    // Records written before federation have no `kind`; treat them as browsers
    // rather than failing the whole file (FileDeviceStore drops everything on error).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tokenHash = try c.decode(String.self, forKey: .tokenHash)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        kind = (try? c.decodeIfPresent(RemoteDeviceKind.self, forKey: .kind)) ?? .browser
        peerServerId = try c.decodeIfPresent(String.self, forKey: .peerServerId)
    }
}
```

- [ ] **Step 4: Run `RemoteDeviceTests` and `RemotePairingServiceTests`**

Expected: both `TEST SUCCEEDED` (the pairing service's existing 5-argument `RemoteDevice(...)` call at `RemotePairingService.swift:67` still compiles via the defaults).

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Pairing/RemoteDevice.swift AlasTests/Remote/RemoteDeviceTests.swift
git commit -m "feat(remote): record whether a paired device is a browser or an Alas peer"
```

---

### Task 4: `redeemPeer` on the pairing service

**Files:**
- Modify: `Alas/Sources/Remote/Pairing/RemotePairingService.swift:57-73`
- Test: `AlasTests/Remote/RemotePairingServiceTests.swift`

**Interfaces:**
- Produces: `struct RemotePeerRedeemResult { let token: String; let deviceId: String }`; `RemotePairingService.redeemPeer(code:deviceName:peerServerId:) throws -> RemotePeerRedeemResult`. `redeem(code:deviceName:)` keeps its signature.

- [ ] **Step 1: Write the failing tests**

Append inside `RemotePairingServiceTests`:

```swift
    @Test func redeemPeerStoresKindAndServerId() throws {
        let svc = make()
        let result = try svc.redeemPeer(code: svc.beginPairing(), deviceName: "Studio", peerServerId: "srv-b")
        #expect(svc.validate(token: result.token) == result.deviceId)
        let device = try #require(svc.devices.first { $0.id == result.deviceId })
        #expect(device.kind == .alasInstance)
        #expect(device.peerServerId == "srv-b")
        #expect(device.name == "Studio")
    }

    // A peer redeem must NOT evict an earlier record for the same
    // `peerServerId`: the identity beside a code is an unverified claim, so
    // evicting on it would let one code holder cut an established peer's
    // access. "No token issued to a peer outlives the user forgetting that
    // peer" is carried instead by `RemotePeerManager.forget` (Task 10), which
    // revokes every device matching the identity.
    @Test func redeemPeerKeepsEarlierRecordsForTheSameServer() throws {
        let svc = make()
        let first = try svc.redeemPeer(code: svc.beginPairing(), deviceName: "Studio", peerServerId: "srv-b")
        let second = try svc.redeemPeer(code: svc.beginPairing(), deviceName: "Studio (renamed)", peerServerId: "srv-b")
        #expect(svc.devices.filter { $0.peerServerId == "srv-b" }.count == 2)
        #expect(svc.validate(token: first.token) == first.deviceId)
        #expect(svc.validate(token: second.token) == second.deviceId)
    }

    @Test func redeemPeerDoesNotTouchBrowserDevices() throws {
        let svc = make()
        let phone = try svc.redeem(code: svc.beginPairing(), deviceName: "iPhone")
        _ = try svc.redeemPeer(code: svc.beginPairing(), deviceName: "Studio", peerServerId: "srv-b")
        #expect(svc.validate(token: phone) != nil)
        #expect(svc.devices.count == 2)
    }
```

- [ ] **Step 2: Run to confirm failure**

`-only-testing AlasTests/RemotePairingServiceTests`. Expected: `redeemPeer` unknown.

- [ ] **Step 3: Implement**

Add above the class in `RemotePairingService.swift`:

```swift
struct RemotePeerRedeemResult: Equatable, Sendable {
    let token: String
    let deviceId: String
}
```

Replace `redeem(code:deviceName:)` (lines 57-73) with:

```swift
    /// Exchanges a valid pairing code for a fresh per-device token. The code is consumed.
    func redeem(code: String, deviceName: String) throws -> String {
        try redeemCore(code: code, deviceName: deviceName, kind: .browser, peerServerId: nil).token
    }

    /// Same exchange for another Alas instance. Existing records for the same
    /// `peerServerId` are left alone: a redeem only proves the caller holds a
    /// live pairing code, never that it is the peer whose identity it claims,
    /// so evicting on that claim would let one code holder cut an established
    /// peer's access. Re-pairing therefore adds a row rather than replacing
    /// one; `RemotePeerManager.forget` revokes every device carrying the
    /// identity, so no token outlives the user forgetting the peer.
    func redeemPeer(code: String, deviceName: String, peerServerId: String) throws -> RemotePeerRedeemResult {
        try redeemCore(code: code, deviceName: deviceName, kind: .alasInstance, peerServerId: peerServerId)
    }

    private func redeemCore(code: String, deviceName: String, kind: RemoteDeviceKind,
                            peerServerId: String?) throws -> RemotePeerRedeemResult {
        // Drop failures outside the window, then throttle if too many remain.
        recentFailedRedeems = recentFailedRedeems.filter { now().timeIntervalSince($0) < Self.rateWindow }
        guard recentFailedRedeems.count < Self.maxFailedRedeems else {
            throw RemoteServerError.unauthorized
        }
        prunePendingCodes()
        // Hex codes are case-insensitive; normalize, then match any live code in constant time.
        let candidate = code.uppercased()
        guard let idx = pendingCodes.firstIndex(where: { Self.constantTimeEquals($0.code, candidate) }) else {
            recentFailedRedeems.append(now())
            throw RemoteServerError.unauthorized
        }
        pendingCodes.remove(at: idx)   // consume only the matched code
        recentFailedRedeems.removeAll()   // a successful pair clears the failure window
        let token = Self.randomToken(byteCount: 32)
        let device = RemoteDevice(id: UUID().uuidString, name: deviceName,
                                  tokenHash: Self.hash(token), createdAt: now(), lastSeenAt: nil,
                                  kind: kind, peerServerId: peerServerId)
        devices.append(device)
        store.save(devices)
        return RemotePeerRedeemResult(token: token, deviceId: device.id)
    }
```

- [ ] **Step 4: Run `RemotePairingServiceTests`**

Expected: `TEST SUCCEEDED`, including every pre-existing test.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Pairing/RemotePairingService.swift AlasTests/Remote/RemotePairingServiceTests.swift
git commit -m "feat(remote): redeem pairing codes for Alas peers"
```

---

### Task 5: `RemotePeer` model and `FilePeerStore`

**Files:**
- Create: `Alas/Sources/Remote/Pairing/RemotePeer.swift`
- Modify: `Alas/Sources/Persistence/Paths.swift:88-92`
- Create: `AlasTests/Remote/RemotePeerStoreTests.swift`

**Interfaces:**
- Produces: `struct RemotePeer`, `protocol RemotePeerStore`, `final class FilePeerStore`, `Paths.remotePeersFile`, and the test-target `InMemoryPeerStore`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Alas

/// In-memory `RemotePeerStore` shared by the Remote suite.
final class InMemoryPeerStore: RemotePeerStore {
    private(set) var saved: [RemotePeer] = []
    func load() -> [RemotePeer] { saved }
    func save(_ peers: [RemotePeer]) { saved = peers }
}

struct RemotePeerStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-peers-\(UUID().uuidString)")
            .appendingPathComponent("remote-peers.json")
    }

    @Test func missingFileLoadsEmpty() {
        #expect(FilePeerStore(url: tempFile()).load().isEmpty)
    }

    @Test func peersRoundTripThroughDisk() {
        let url = tempFile()
        let peer = RemotePeer(id: "p1", serverId: "srv-b", name: "Studio",
                              origins: ["http://100.64.1.5:8765", "http://192.168.1.20:8765"],
                              lastOrigin: "http://100.64.1.5:8765", token: "tok", protocolVersion: 1,
                              localDeviceId: "d9", addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        FilePeerStore(url: url).save([peer])
        #expect(FilePeerStore(url: url).load() == [peer])
    }

    // Seeded through FilePeerStore, not a throwaway JSONDecoder: the behaviour
    // under test is that the PRODUCTION load path tolerates a record written
    // without the optional keys. FilePeerStore.load() decodes the whole file as
    // one array and returns [] on any error, so a wrongly-strict field loses
    // every peer, not one.
    @Test func recordWithoutOptionalKeysDecodes() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = Data(#"[{"id":"p1","serverId":"srv-b","name":"Studio","origins":["http://a:1"],"token":"t","addedAt":"2026-01-02T03:04:05Z"}]"#.utf8)
        try json.write(to: url)
        let peers = FilePeerStore(url: url).load()
        #expect(peers.count == 1)
        #expect(peers.first?.lastOrigin == nil)
        #expect(peers.first?.protocolVersion == nil)
        #expect(peers.first?.localDeviceId == nil)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

`-only-testing AlasTests/RemotePeerStoreTests`. Expected: `RemotePeer` unknown.

- [ ] **Step 3: Create the model and store**

`Alas/Sources/Remote/Pairing/RemotePeer.swift`:

```swift
import Foundation

/// Another Mac running Alas that this Mac holds a token for. The Swift twin
/// of one entry in the web client's `alas.remote.hub` registry.
struct RemotePeer: Codable, Equatable, Identifiable, Sendable {
    let id: String                 // local UUID, stable across renames
    var serverId: String           // the peer's advertised identity
    var name: String
    var origins: [String]          // full origins, preferred first
    var lastOrigin: String?        // the origin that last answered
    var token: String              // bearer token the peer issued to us
    var protocolVersion: Int?
    /// The `RemoteDevice.id` on this Mac that the peer uses to reach us, so
    /// forgetting the peer can revoke its inbound token too.
    var localDeviceId: String?
    var addedAt: Date
}

protocol RemotePeerStore: AnyObject {
    func load() -> [RemotePeer]
    func save(_ peers: [RemotePeer])
}

final class FilePeerStore: RemotePeerStore {
    private let store: any PersistenceStoreProtocol
    private let url: URL

    init(store: any PersistenceStoreProtocol = PersistenceStore(), url: URL = Paths.remotePeersFile) {
        self.store = store
        self.url = url
    }

    func load() -> [RemotePeer] {
        (try? store.readIfExists([RemotePeer].self, from: url)) ?? []
    }

    func save(_ peers: [RemotePeer]) {
        try? store.write(peers, to: url)
    }
}
```

`Paths.swift`, after the `remoteDevicesFile` extension (line 92):

```swift
extension Paths {
    static var remotePeersFile: URL {
        appSupportRoot.appendingPathComponent("remote-peers.json")
    }
}
```

- [ ] **Step 4: Run `RemotePeerStoreTests`**

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Pairing/RemotePeer.swift Alas/Sources/Persistence/Paths.swift AlasTests/Remote/RemotePeerStoreTests.swift
git commit -m "feat(remote): persist outbound peer records"
```

---

### Task 6: Parse pairing links in Swift; peer advertisement types

**Files:**
- Modify: `Alas/Sources/Remote/Pairing/RemotePairingLink.swift`
- Create: `Alas/Sources/Remote/Pairing/RemotePeerAdvertisement.swift`
- Test: `AlasTests/Remote/RemotePairingLinkTests.swift`

**Interfaces:**
- Produces: `struct RemotePairingLinkParts { let origins: [String]; let code: String }`; `RemotePairingLink.parse(_:) -> RemotePairingLinkParts?`; `RemotePairingLink.normalizeOrigin(_:) -> String?`; `struct RemotePeerAdvertisement: Codable { serverId, name, origins, counterCode? }`; `struct RemotePeerPairingRequest { peerServerId, peerName, origins, counterCode?, localDeviceId }`.

- [ ] **Step 1: Write the failing tests**

Append to `RemotePairingLinkTests`:

```swift
    @Test func parseRecoversOriginsInOrderWithBaseFirst() throws {
        let addresses = [
            RemoteAdvertisedAddress(kind: .tailnet, interfaceName: "utun3", host: "100.64.1.5", port: 8765, isRecommended: true),
            RemoteAdvertisedAddress(kind: .lan, interfaceName: "en0", host: "192.168.1.20", port: 8765, isRecommended: false),
        ]
        let link = RemotePairingLink.build(base: "http://100.64.1.5:8765", code: "ABC123", addresses: addresses)
        let parts = try #require(RemotePairingLink.parse(link))
        #expect(parts.code == "ABC123")
        #expect(parts.origins == ["http://100.64.1.5:8765", "http://192.168.1.20:8765"])
    }

    @Test func parseLegacyLinkWithoutHostsUsesItsOwnOrigin() throws {
        let parts = try #require(RemotePairingLink.parse("http://192.168.1.20:8765/?code=ABC123"))
        #expect(parts.origins == ["http://192.168.1.20:8765"])
    }

    @Test func parseRejectsNonLinksAndMissingCode() {
        #expect(RemotePairingLink.parse("") == nil)
        #expect(RemotePairingLink.parse("not a link") == nil)
        #expect(RemotePairingLink.parse("http://192.168.1.20:8765/") == nil)
        #expect(RemotePairingLink.parse("ftp://192.168.1.20:8765/?code=A") == nil)
    }

    @Test func normalizeOriginBracketsIPv6AndKeepsPort() {
        #expect(RemotePairingLink.normalizeOrigin("http://[fd7a:115c:a1e0::1]:8765/anything") == "http://[fd7a:115c:a1e0::1]:8765")
        #expect(RemotePairingLink.normalizeOrigin("http://nacho.local:8765") == "http://nacho.local:8765")
        #expect(RemotePairingLink.normalizeOrigin("mailto:x") == nil)
    }
```

- [ ] **Step 2: Run to confirm failure**

`-only-testing AlasTests/RemotePairingLinkTests`. Expected: `parse` unknown.

- [ ] **Step 3: Implement `parse`**

Append inside `enum RemotePairingLink`:

```swift
    /// The inverse of `build`. Origins come back in `hosts` order with the
    /// link's own origin appended as the last fallback; duplicates keep their
    /// first position. Nil when `text` is not an http(s) URL with a `code`.
    static func parse(_ text: String) -> RemotePairingLinkParts? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value?
                  .trimmingCharacters(in: .whitespaces),
              !code.isEmpty
        else { return nil }
        var candidates: [String] = []
        if let hosts = components.queryItems?.first(where: { $0.name == "hosts" })?.value {
            candidates.append(contentsOf: hosts.split(separator: ",").map(String.init))
        }
        candidates.append(trimmed)
        var origins: [String] = []
        for candidate in candidates {
            guard let origin = normalizeOrigin(candidate), !origins.contains(origin) else { continue }
            origins.append(origin)
        }
        return origins.isEmpty ? nil : RemotePairingLinkParts(origins: origins, code: code)
    }

    /// `scheme://host[:port]` for an http(s) URL, IPv6 hosts bracketed.
    static func normalizeOrigin(_ text: String) -> String? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = components.host, !rawHost.isEmpty
        else { return nil }
        // Foundation versions differ on whether an IPv6 host keeps its brackets; normalise both ways.
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let bracketed = host.contains(":") ? "[\(host)]" : host
        if let port = components.port {
            return "\(scheme)://\(bracketed):\(port)"
        }
        return "\(scheme)://\(bracketed)"
    }
```

And above the enum:

```swift
struct RemotePairingLinkParts: Equatable, Sendable {
    let origins: [String]
    let code: String
}
```

- [ ] **Step 4: Create the advertisement types**

`Alas/Sources/Remote/Pairing/RemotePeerAdvertisement.swift`:

```swift
import Foundation

/// The optional `peer` object an Alas instance adds to `POST /pair`. Browsers
/// omit it. `counterCode` is a code the redeeming instance minted on itself so
/// the responder can pair back; the responder's own counter-redeem sends nil.
struct RemotePeerAdvertisement: Codable, Equatable, Sendable {
    let serverId: String
    let name: String
    let origins: [String]
    let counterCode: String?
}

/// What the server hands the app after a peer redeemed a code here.
struct RemotePeerPairingRequest: Equatable, Sendable {
    let peerServerId: String
    let peerName: String
    let origins: [String]
    let counterCode: String?
    /// The `RemoteDevice.id` just created for the peer on this Mac.
    let localDeviceId: String
}
```

- [ ] **Step 5: Run `RemotePairingLinkTests`**

Expected: `TEST SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Pairing/RemotePairingLink.swift Alas/Sources/Remote/Pairing/RemotePeerAdvertisement.swift AlasTests/Remote/RemotePairingLinkTests.swift
git commit -m "feat(remote): parse pairing links and define the peer advertisement"
```

---

### Task 7: `/pair` accepts a peer, replies with identity, fires `onPeerPaired`

**Files:**
- Modify: `Alas/Sources/Remote/Server/RemoteHTTPResponder.swift:37-42, 87-97`
- Modify: `Alas/Sources/Remote/Server/RemoteServer.swift:11-42, 178-222`
- Test: `AlasTests/Remote/RemoteHTTPResponderTests.swift`, `AlasTests/Remote/RemoteServerIntegrationTests.swift`

**Interfaces:**
- Consumes: `redeemPeer` (Task 4), `RemotePeerAdvertisement`, `RemotePeerPairingRequest` (Task 6).
- Produces: `RemoteHTTPResponder.acceptsPeers: @MainActor () -> Bool` (default `{ false }`), `RemoteHTTPResponder.onPeerPaired: (@MainActor (RemotePeerPairingRequest) -> Void)?`, `RemoteServer.onPeerPaired` (same type). `/pair` reply body becomes `{"token","serverId","name"}`.

- [ ] **Step 1: Write the failing responder tests**

Append inside `RemoteHTTPResponderTests`:

```swift
    private final class PeerSink {
        var requests: [RemotePeerPairingRequest] = []
    }

    private func makePeerResponder(pairing: RemotePairingService, accepts: Bool, sink: PeerSink) -> RemoteHTTPResponder {
        var responder = RemoteHTTPResponder(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            diagnostics: {
                RemoteDiagnosticsSnapshot(appName: "Alas", port: 1, addresses: [], usesPlainHTTP: true,
                                          pairedDeviceCount: 0, serverId: "srv-a", name: "Mac A")
            },
            originPolicy: RemoteOriginPolicy(hostPolicy: .loopback, allowedOrigins: [])
        )
        responder.acceptsPeers = { accepts }
        responder.onPeerPaired = { sink.requests.append($0) }
        return responder
    }

    @Test func pairReplyCarriesServerIdentity() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"phone"}"#.utf8)
        let out = makePeerResponder(pairing: pairing, accepts: false, sink: PeerSink())
            .response(for: request("POST", "/pair"), body: body)
        let json = try #require(String(decoding: out, as: UTF8.self).components(separatedBy: "\r\n\r\n").last)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["token"] as? String)?.isEmpty == false)
        #expect(object["serverId"] as? String == "srv-a")
        #expect(object["name"] as? String == "Mac A")
    }

    @Test func pairWithPeerCreatesAnInstanceDeviceAndNotifies() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let body = Data(#"""
        {"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":["http://100.64.1.9:8765"],"counterCode":"C0DE"}}
        """#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: true, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 200 OK"))
        let device = try #require(pairing.devices.first)
        #expect(device.kind == .alasInstance)
        #expect(device.peerServerId == "srv-b")
        #expect(sink.requests == [RemotePeerPairingRequest(
            peerServerId: "srv-b", peerName: "Mac B", origins: ["http://100.64.1.9:8765"],
            counterCode: "C0DE", localDeviceId: device.id)])
    }

    @Test func pairWithPeerIsForbiddenWhenFederationIsOff() {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":[]}}"#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: false, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.isEmpty)
        #expect(sink.requests.isEmpty)
        // The code was not consumed: a plain browser pair with it still works.
        #expect((try? pairing.redeem(code: code, deviceName: "phone")) != nil)
    }
```

- [ ] **Step 2: Write the failing integration test**

Append to `RemoteServerIntegrationTests`:

```swift
    @Test func serverForwardsPeerPairingToTheApp() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: FakeSessionsProvider(),
            identity: { RemoteServerIdentity(serverId: "srv-a", name: "Mac A", hubEnabled: false, federationEnabled: true) }
        )
        final class Sink { var requests: [RemotePeerPairingRequest] = [] }
        let sink = Sink()
        server.onPeerPaired = { sink.requests.append($0) }
        try server.start(port: 0)
        defer { server.stop() }
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)
        let code = pairing.beginPairing()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":["http://127.0.0.1:1"],"counterCode":"X"}}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["serverId"] as? String == "srv-a")
        for _ in 0..<50 where sink.requests.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(sink.requests.first?.peerServerId == "srv-b")
        #expect(sink.requests.first?.counterCode == "X")
    }
```

- [ ] **Step 3: Run to confirm failure**

`-only-testing AlasTests/RemoteHTTPResponderTests -only-testing AlasTests/RemoteServerIntegrationTests`. Expected: `acceptsPeers` unknown.

- [ ] **Step 4: Implement the responder**

In `RemoteHTTPResponder.swift`, add after `var originPolicy: RemoteOriginPolicy = .loopback` (line 42):

```swift
    /// Whether `POST /pair` may carry a `peer` object. Off means a peer
    /// request gets 403 and its code stays unconsumed.
    var acceptsPeers: @MainActor () -> Bool = { false }
    /// Fired after a peer redeemed a code here, so the app can pair back.
    var onPeerPaired: (@MainActor (RemotePeerPairingRequest) -> Void)? = nil
    /// The identity this Mac advertises. Shared with the `hello` frame so a
    /// pairing reply and the socket that follows it can never disagree.
    /// Nil means "no identity configured" and omits both keys from the reply.
    var identity: (@MainActor () -> RemoteServerIdentity)?
```

Replace `pairResponse` (lines 87-97):

```swift
    /// A real Mac advertises a handful of addresses (tailnet, LAN, a couple of
    /// interfaces); anything beyond this is a probe list, not a peer.
    private static let maxPeerOrigins = 8
    /// Upper bound on peer-supplied display strings, which are stored and shown.
    private static let maxPeerTextLength = 200

    private func pairResponse(body: Data, extraHeaders: [(String, String)]) -> Data {
        struct PairRequest: Decodable {
            let code: String
            let deviceName: String
            let peer: RemotePeerAdvertisement?
        }
        struct PairReply: Encodable {
            let token: String
            let serverId: String?
            let name: String?
        }
        let unauthorized = Self.http(status: "401 Unauthorized", contentType: "application/json",
                                     body: Data(#"{"error":"pairing failed"}"#.utf8), extraHeaders: extraHeaders)
        func forbidden(_ error: String) -> Data {
            Self.http(status: "403 Forbidden", contentType: "application/json",
                      body: Data(#"{"error":"\#(error)"}"#.utf8), extraHeaders: extraHeaders)
        }
        guard let pr = try? JSONDecoder().decode(PairRequest.self, from: body) else { return unauthorized }
        let token: String
        if let peer = pr.peer {
            guard acceptsPeers() else { return forbidden("federation disabled") }
            // Everything in `peer` is attacker-controlled and only the 1 MB
            // body cap bounds it. Reject an implausible advertisement BEFORE
            // redeeming, so a rejected request leaves the pairing code
            // unconsumed: `origins` is walked sequentially by the pair-back
            // with a POST each, which would otherwise turn one code into a
            // port scan of the local network; an empty `serverId` collapses
            // every peer onto one identity; and `name`/`deviceName` are both
            // adopted into records and shown in Settings.
            guard peer.origins.count <= Self.maxPeerOrigins,
                  !peer.serverId.isEmpty,
                  peer.name.count <= Self.maxPeerTextLength,
                  pr.deviceName.count <= Self.maxPeerTextLength
            else { return forbidden("peer rejected") }
            guard let result = try? pairing.redeemPeer(code: pr.code, deviceName: pr.deviceName,
                                                       peerServerId: peer.serverId) else { return unauthorized }
            token = result.token
            onPeerPaired?(RemotePeerPairingRequest(
                peerServerId: peer.serverId, peerName: peer.name, origins: peer.origins,
                counterCode: peer.counterCode, localDeviceId: result.deviceId))
        } else {
            guard let issued = try? pairing.redeem(code: pr.code, deviceName: pr.deviceName) else { return unauthorized }
            token = issued
        }
        // Identity comes from the same closure that builds `hello`, so a
        // pairing reply and the socket that follows it cannot disagree. Nil
        // (an unset fixture) omits both keys, leaving the body exactly
        // `{"token":"…"}` for the browser path.
        let id = identity?()
        let reply = PairReply(
            token: token,
            serverId: id?.serverId.isEmpty == false ? id?.serverId : nil,
            name: id.map(\.name))
        let payload = (try? JSONEncoder().encode(reply)) ?? Data(#"{"token":"\#(token)"}"#.utf8)
        return Self.http(status: "200 OK", contentType: "application/json", body: payload, extraHeaders: extraHeaders)
    }
```

- [ ] **Step 5: Forward from the server**

`RemoteServer.swift`: after `var onConnectionDeviceCountsChange` (line 42) add:

```swift
    /// Fired on the main actor after another Alas instance paired here.
    var onPeerPaired: (@MainActor (RemotePeerPairingRequest) -> Void)?
```

In `accept(_:)` replace the `let responder = RemoteHTTPResponder(...)` (lines 181-186) with:

```swift
        let identity = self.identityProvider
        var configured = RemoteHTTPResponder(
            pairing: pairing,
            assets: assets,
            diagnostics: { self.diagnosticsProvider(self.port) },
            originPolicy: originPolicy
        )
        configured.acceptsPeers = { identity().federationEnabled }
        configured.identity = identity
        configured.onPeerPaired = { [weak self] request in self?.onPeerPaired?(request) }
        let responder = configured   // immutable copy so the escaping closure below captures a value
```

and delete the later duplicate `let identity = self.identityProvider` line (188) since it now sits above. The existing `responder: { req, body in responder.response(for: req, body: body) }` argument stays as is.

- [ ] **Step 6: Run the two suites**

Expected: `TEST SUCCEEDED`. The pre-existing `pairResponseCarriesCORSHeaders` test still passes because the reply is still JSON with a `token` key.

- [ ] **Step 7: Check the web client still pairs**

`Alas/Resources/RemoteWeb/hub-links.js` reads `token` from the `/pair` reply and ignores unknown keys. Run the node suite to be sure nothing asserts on the exact body:

```bash
scripts/tests/remote-web-hub/run.sh
```

Expected: all node tests pass.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/Remote/Server/RemoteHTTPResponder.swift Alas/Sources/Remote/Server/RemoteServer.swift AlasTests/Remote/RemoteHTTPResponderTests.swift AlasTests/Remote/RemoteServerIntegrationTests.swift
git commit -m "feat(remote): accept peer advertisements on /pair and reply with identity"
```

---

### Task 8: `RemotePeerPairer` (outbound `POST /pair`)

**Files:**
- Create: `Alas/Sources/Remote/Peer/RemotePeerPairer.swift`
- Create: `AlasTests/Remote/RemotePeerPairerTests.swift`

**Interfaces:**
- Consumes: `RemotePeerAdvertisement` (Task 6).
- Produces: `struct RemotePeerPairer { init(fetch:timeout:); static let live; func pair(origins:code:deviceName:advertisement:) async -> Outcome }` with `enum Outcome { case paired(token:serverId:name:origin:), expiredCode, originRejected, unreachable }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Alas

struct RemotePeerPairerTests {
    private final class Recorder {
        var requests: [URLRequest] = []
    }

    private func pairer(_ script: [String: (Int, String)], recorder: Recorder) -> RemotePeerPairer {
        RemotePeerPairer(fetch: { req in
            recorder.requests.append(req)
            let key = "\(req.url!.host!):\(req.url!.port!)"
            guard let (status, body) = script[key] else { throw URLError(.cannotConnectToHost) }
            let http = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        }, timeout: 1)
    }

    private let ad = RemotePeerAdvertisement(serverId: "srv-b", name: "Mac B", origins: ["http://10.0.0.2:8765"], counterCode: "C1")

    @Test func fallsThroughUnreachableOriginsAndReturnsTheAnsweringOne() async throws {
        let recorder = Recorder()
        let p = pairer(["10.0.0.9:8765": (200, #"{"token":"tok","serverId":"srv-a","name":"Mac A"}"#)], recorder: recorder)
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .paired(token: "tok", serverId: "srv-a", name: "Mac A", origin: "http://10.0.0.9:8765"))
        #expect(recorder.requests.count == 2)
        let body = try #require(recorder.requests.last?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["code"] as? String == "ABC")
        #expect(object["deviceName"] as? String == "Mac B")
        let peer = try #require(object["peer"] as? [String: Any])
        #expect(peer["serverId"] as? String == "srv-b")
        #expect(peer["counterCode"] as? String == "C1")
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test func expiredCodeStopsAtTheFirstAnsweringOrigin() async {
        let recorder = Recorder()
        let p = pairer(["10.0.0.1:8765": (401, #"{"error":"pairing failed"}"#), "10.0.0.9:8765": (200, "{}")], recorder: recorder)
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .expiredCode)
        #expect(recorder.requests.count == 1)
    }

    @Test func forbiddenIsOriginRejected() async {
        let p = pairer(["10.0.0.1:8765": (403, "{}")], recorder: Recorder())
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .originRejected)
    }

    @Test func nothingAnsweringIsUnreachable() async {
        let p = pairer([:], recorder: Recorder())
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.2:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .unreachable)
    }

    @Test func replyWithoutTokenIsSkipped() async {
        let p = pairer(["10.0.0.1:8765": (200, #"{"nope":true}"#)], recorder: Recorder())
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765"], code: "ABC", deviceName: "Mac B", advertisement: nil)
        #expect(outcome == .unreachable)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

`-only-testing AlasTests/RemotePeerPairerTests`. Expected: `RemotePeerPairer` unknown.

- [ ] **Step 3: Implement**

`Alas/Sources/Remote/Peer/RemotePeerPairer.swift`:

```swift
import Foundation

/// Redeems a pairing code on another Mac, trying each origin in order the way
/// `hub-links.js` does: a network failure moves on, a 401 means the code is
/// dead everywhere, a 403 means that Mac refuses peers or this address.
struct RemotePeerPairer {
    enum Outcome: Equatable, Sendable {
        case paired(token: String, serverId: String?, name: String?, origin: String)
        case expiredCode
        case originRejected
        case unreachable
    }

    // Not `@Sendable`: tests inject closures that record into plain classes,
    // and every caller is on the main actor.
    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)

    let fetch: Fetch
    let timeout: TimeInterval

    init(fetch: @escaping Fetch, timeout: TimeInterval = 4) {
        self.fetch = fetch
        self.timeout = timeout
    }

    static let live = RemotePeerPairer(fetch: { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    })

    func pair(origins: [String], code: String, deviceName: String,
              advertisement: RemotePeerAdvertisement?) async -> Outcome {
        struct Body: Encodable {
            let code: String
            let deviceName: String
            let peer: RemotePeerAdvertisement?
        }
        struct Reply: Decodable {
            let token: String
            let serverId: String?
            let name: String?
        }
        let body = try? JSONEncoder().encode(Body(code: code, deviceName: deviceName, peer: advertisement))
        for origin in origins {
            // Origins reach this type from two directions: a link the user
            // pasted, and a peer's self-reported advertisement, which is
            // attacker-controlled. Normalizing here means neither path can
            // dial a non-http(s) scheme or smuggle a path, query or userinfo
            // into the request target.
            guard let normalized = RemotePairingLink.normalizeOrigin(origin),
                  let url = URL(string: normalized + "/pair") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.httpBody = body
            // No Content-Type on purpose: same "simple request" shape as the web client.
            guard let (data, http) = try? await fetch(request) else { continue }
            switch http.statusCode {
            case 200:
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { continue }
                return .paired(token: reply.token, serverId: reply.serverId, name: reply.name, origin: normalized)
            case 401:
                return .expiredCode
            case 403:
                return .originRejected
            default:
                continue
            }
        }
        return .unreachable
    }
}
```

- [ ] **Step 4: Run `RemotePeerPairerTests`**

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Peer/RemotePeerPairer.swift AlasTests/Remote/RemotePeerPairerTests.swift
git commit -m "feat(remote): add the outbound peer pairer with origin fallback"
```

---

### Task 9: `RemotePeerConnection` (outbound WebSocket)

**Files:**
- Create: `Alas/Sources/Remote/Peer/RemotePeerConnection.swift`
- Create: `AlasTests/Remote/RemotePeerConnectionTests.swift`

**Interfaces:**
- Consumes: `RemoteClientMessage.helloAck` (Task 2), `RemoteServerMessage.hello` with five fields (Task 1).
- Produces:

```swift
@MainActor protocol RemotePeerConnecting: AnyObject {
    var state: RemotePeerConnection.State { get }
    func connect()
    func disconnect()
    func send(_ message: RemoteClientMessage)
}
@MainActor final class RemotePeerConnection: RemotePeerConnecting {
    enum State: Equatable { case idle, connecting, online, offline, unauthorized, incompatible(remoteVersion: Int), identityMismatch(expected: String, actual: String) }
    enum Event { case stateChanged(State); case hello(serverId: String, name: String, protocolVersion: Int, federationEnabled: Bool); case originChanged(String); case message(RemoteServerMessage) }
    struct Config { var handshakeTimeout: TimeInterval = 4; var initialBackoff: TimeInterval = 1.5; var maxBackoff: TimeInterval = 30; var localProtocolVersion: Int = RemoteProtocolVersion.current }
    init(origins: [String], lastOrigin: String?, token: String, expectedServerId: String? = nil, config: Config = Config(), session: URLSession = .shared, onEvent: @escaping @MainActor (Event) -> Void)
    private(set) var lastOrigin: String?
    static func socketURL(for origin: String) -> URL?
}
```

`expectedServerId` is the identity the record was paired with. When set it
gates two things: the `/health` probe only counts as proof the paired Mac is
up if it reports that id, and a socket whose `hello` reports a different id is
refused with the terminal `identityMismatch` state instead of being adopted.
Both matter because whoever answers a stored origin would otherwise decide who
this link is talking to.

- [ ] **Step 1: Write the failing tests**

These run against a real in-process `RemoteServer`, the same way `RemoteServerIntegrationTests` does.

```swift
import Testing
import Foundation
@testable import Alas

@MainActor
struct RemotePeerConnectionTests {
    private enum TimeoutError: Error { case timedOut }

    @MainActor
    private final class Events {
        var all: [RemotePeerConnection.Event] = []
        var states: [RemotePeerConnection.State] { all.compactMap { if case .stateChanged(let s) = $0 { return s } else { return nil } } }
        var hellos: [String] { all.compactMap { if case .hello(let id, _, _, _) = $0 { return id } else { return nil } } }
        var helloNames: [String] { all.compactMap { if case .hello(_, let name, _, _) = $0 { return name } else { return nil } } }
        var helloVersions: [Int] { all.compactMap { if case .hello(_, _, let v, _) = $0 { return v } else { return nil } } }
        /// Without this the `federationEnabled` the link forwards is untested,
        /// so mixing up the `hello` frame's trailing fields stays green.
        var helloFederation: [Bool] { all.compactMap { if case .hello(_, _, _, let f) = $0 { return f } else { return nil } } }
        var origins: [String] { all.compactMap { if case .originChanged(let o) = $0 { return o } else { return nil } } }
        var messages: [RemoteServerMessage] { all.compactMap { if case .message(let m) = $0 { return m } else { return nil } } }
    }

    /// `serverId` is what `/health` reports. Nil reproduces the default
    /// diagnostics snapshot exactly, so it changes nothing for the tests that
    /// do not care; the health-identity tests set it.
    private func startServer(pairing: RemotePairingService,
                             provider: RemoteSessionsProvider = FakeSessionsProvider(),
                             serverId: String? = nil) async throws -> (RemoteServer, String) {
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: provider,
            diagnostics: { port in
                RemoteDiagnosticsSnapshot(appName: "Alas", port: port, addresses: [],
                                          usesPlainHTTP: true, pairedDeviceCount: 0, serverId: serverId)
            },
            identity: { RemoteServerIdentity(serverId: "srv-a", name: "Mac A", hubEnabled: false, federationEnabled: true) }
        )
        try server.start(port: 0)
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)
        return (server, "http://127.0.0.1:\(port)")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw TimeoutError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func fastConfig(localVersion: Int = RemoteProtocolVersion.current) -> RemotePeerConnection.Config {
        var config = RemotePeerConnection.Config()
        config.handshakeTimeout = 2
        config.initialBackoff = 0.2
        config.maxBackoff = 0.5
        config.localProtocolVersion = localVersion
        return config
    }

    @Test func connectsReceivesHelloAcksAndGoesOnline() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .online }
        #expect(events.hellos == ["srv-a"])
        #expect(events.helloNames == ["Mac A"])
        #expect(events.helloVersions == [RemoteProtocolVersion.current])
        // `startServer`'s identity sets federationEnabled: true.
        #expect(events.helloFederation == [true])
        #expect(events.origins == [origin])
        #expect(link.lastOrigin == origin)
        #expect(events.states.first == .connecting)
    }

    @Test func fallsBackToTheNextOriginWhenTheFirstIsDead() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: ["http://127.0.0.1:1", origin], lastOrigin: "http://127.0.0.1:1", token: token, config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .online }
        #expect(link.lastOrigin == origin)
    }

    @Test func rejectedTokenIsUnauthorizedAndStopsRetrying() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: "not-a-token", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .unauthorized }
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(events.states.filter { $0 == .connecting }.count == 1)
    }

    @Test func deadServerIsOfflineAndRetries() async throws {
        let events = Events()
        let link = RemotePeerConnection(origins: ["http://127.0.0.1:1"], lastOrigin: nil, token: "t", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { events.states.filter { $0 == .connecting }.count >= 2 }
        #expect(events.states.contains(.offline))
    }

    @Test func protocolMismatchIsIncompatible() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig(localVersion: 99)) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .incompatible(remoteVersion: RemoteProtocolVersion.current) }
    }

    @Test func forwardsServerMessagesAfterHello() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "s1", title: "T", agentId: "claude", status: "idle", canDrive: false)]
        let (server, origin) = try await startServer(pairing: pairing, provider: provider)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .online }
        link.send(.listSessions)
        try await waitUntil { !events.messages.isEmpty }
        #expect(events.messages.first == .sessionList(sessions: provider.summaries))
    }

    @Test func disconnectReturnsToIdle() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig()) { _ in }
        link.connect()
        try await waitUntil { link.state == .online }
        link.disconnect()
        #expect(link.state == .idle)
    }

    @Test func disconnectImmediatelyAfterConnectSettlesIdle() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig()) { events.all.append($0) }
        link.connect()
        link.disconnect()
        #expect(link.state == .idle)
        // disconnect() clears `runner` and sets .idle synchronously, but the
        // task connect() spawned is still queued and has not run its body
        // yet. Give it a real chance to start — without the cancellation
        // guard at the top of run(), it announces .connecting right back on
        // top of the .idle disconnect() just set, and with `runner` already
        // nil nothing is left to move the state again. A bare `waitUntil`
        // can't catch this: it checks its condition before ever suspending,
        // so it would see the already-idle state and return before the
        // orphaned task got to run at all.
        for _ in 0..<25 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(link.state == .idle)
        #expect(!events.states.contains(.connecting))
    }

    @Test func aDisconnectedLinkIsNotResurrectedByAnEarlierReconnectTimer() async throws {
        let events = Events()
        let link = RemotePeerConnection(origins: ["http://127.0.0.1:1"], lastOrigin: nil, token: "t", config: fastConfig()) { events.all.append($0) }
        link.connect()
        // First attempt fails and arms a reconnect timer.
        try await waitUntil { link.state == .offline }
        // A connect() while that timer is pending used to drop it without
        // cancelling, so the next failure's timer became the only one
        // disconnect() could reach.
        link.connect()
        try await waitUntil { events.states.filter { $0 == .offline }.count >= 2 }
        link.disconnect()
        #expect(link.state == .idle)
        // Well past both backoff delays: an orphaned timer would have redialled.
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(link.state == .idle)
    }

    @Test func healthProbeFromAnUnexpectedServerDoesNotRevokeTheLink() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, origin) = try await startServer(pairing: pairing, serverId: "srv-a")
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: "not-a-token",
                                        expectedServerId: "srv-somewhere-else", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        // The upgrade is refused and the address answers 200, but as a Mac we
        // never paired with — so this is "unreachable peer", not "revoked".
        try await waitUntil { link.state == .offline }
        #expect(!events.states.contains(.unauthorized))
    }

    @Test func helloFromAnotherIdentityIsRefusedAndNeverRetried() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        // The server's `hello` reports "srv-a" (see `startServer`'s identity);
        // this link was written for a different Mac, so the socket must be
        // dropped rather than adopted.
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token,
                                        expectedServerId: "srv-elsewhere", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .identityMismatch(expected: "srv-elsewhere", actual: "srv-a") }
        // Terminal: no online state, no `hello` event handed to the owner, and
        // well past two backoff delays no second attempt.
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(!events.states.contains(.online))
        #expect(events.hellos.isEmpty)
        #expect(events.states.filter { $0 == .connecting }.count == 1)
    }

    @Test func healthProbeFromTheExpectedServerStillReportsUnauthorized() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, origin) = try await startServer(pairing: pairing, serverId: "srv-a")
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: "not-a-token",
                                        expectedServerId: "srv-a", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .unauthorized }
        #expect(events.states.filter { $0 == .connecting }.count == 1)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

`-only-testing AlasTests/RemotePeerConnectionTests`. Expected: `RemotePeerConnection` unknown.

- [ ] **Step 3: Implement**

`Alas/Sources/Remote/Peer/RemotePeerConnection.swift`:

```swift
import Foundation

@MainActor
protocol RemotePeerConnecting: AnyObject {
    var state: RemotePeerConnection.State { get }
    func connect()
    func disconnect()
    func send(_ message: RemoteClientMessage)
}

/// One outbound WebSocket to a paired Mac. Mirrors `hub-links.js`: try the
/// last good origin then the rest with a handshake timeout, expect `hello`
/// first, answer `helloAck`, tell "revoked" from "unreachable" with a
/// `/health` probe, and back off between attempts. On top of that it refuses
/// any socket whose `hello` reports an identity other than `expectedServerId`.
///
/// **The owner must call `disconnect()`.** Dropping the last reference is not
/// enough: an in-flight `run()` resolves its weak `self` to a strong one for
/// the whole call and stays suspended in `pump` for the entire online
/// lifetime, so a connected link cannot deallocate, and there is no `deinit`
/// to close the socket. Releasing an owner without disconnecting leaks the
/// object, its task, and an open socket to the peer.
@MainActor
final class RemotePeerConnection: RemotePeerConnecting {
    enum State: Equatable, Sendable {
        case idle
        case connecting
        case online
        case offline
        case unauthorized
        case incompatible(remoteVersion: Int)
        /// The socket's `hello` reported an identity other than the one this
        /// link was created for. Terminal and never retried: the address is
        /// answering for somebody else, so redialing it can only keep talking
        /// to the wrong Mac.
        case identityMismatch(expected: String, actual: String)
    }

    enum Event {
        case stateChanged(State)
        case hello(serverId: String, name: String, protocolVersion: Int, federationEnabled: Bool)
        case originChanged(String)
        case message(RemoteServerMessage)
    }

    struct Config {
        var handshakeTimeout: TimeInterval = 4
        var initialBackoff: TimeInterval = 1.5
        var maxBackoff: TimeInterval = 30
        var localProtocolVersion: Int = RemoteProtocolVersion.current
    }

    private(set) var state: State = .idle
    private(set) var lastOrigin: String?

    private let origins: [String]
    /// The peer's token. Travels only as the WebSocket subprotocol; it is
    /// never logged, never part of an error, and never in the URL.
    private let token: String
    /// The `serverId` this peer is expected to report. When set, a `/health`
    /// probe only counts as proof the paired Mac is up if it reports this id,
    /// and a socket whose `hello` reports a different id is refused outright
    /// rather than adopted.
    private let expectedServerId: String?
    private let config: Config
    private let session: URLSession
    private let onEvent: @MainActor (Event) -> Void
    private var socket: URLSessionWebSocketTask?
    private var runner: Task<Void, Never>?
    private var reconnectTimer: Task<Void, Never>?
    private var backoff: TimeInterval

    init(origins: [String], lastOrigin: String?, token: String, expectedServerId: String? = nil,
         config: Config = Config(), session: URLSession = .shared,
         onEvent: @escaping @MainActor (Event) -> Void) {
        self.origins = origins
        self.lastOrigin = lastOrigin
        self.token = token
        self.expectedServerId = expectedServerId
        self.config = config
        self.session = session
        self.onEvent = onEvent
        self.backoff = config.initialBackoff
    }

    func connect() {
        guard runner == nil else { return }
        // A pending reconnect belongs to an attempt this call supersedes.
        // Letting it go without cancelling would orphan it: `disconnect()`
        // only knows about the newest timer, so a dropped one would still
        // fire and redial a link the owner had torn down.
        reconnectTimer?.cancel()
        reconnectTimer = nil
        runner = Task { [weak self] in await self?.run() }
    }

    func disconnect() {
        runner?.cancel()
        runner = nil
        reconnectTimer?.cancel()
        reconnectTimer = nil
        closeSocket(.goingAway)
        setState(.idle)
    }

    func send(_ message: RemoteClientMessage) {
        guard state == .online, let socket, let data = try? JSONEncoder().encode(message) else { return }
        socket.send(.data(data)) { _ in }
    }

    // MARK: - Lifecycle

    private func run() async {
        // This body does not start until the main actor yields, so a
        // `disconnect()` can land first. Announcing `.connecting` then would
        // strand the link there: the task returns immediately afterwards with
        // `runner` already nil, and nothing would ever move the state again.
        if Task.isCancelled { return }
        setState(.connecting)
        var ordered: [String] = []
        for origin in [lastOrigin].compactMap({ $0 }) + origins where !ordered.contains(origin) {
            ordered.append(origin)
        }
        for origin in ordered {
            if Task.isCancelled { return }
            guard let url = Self.socketURL(for: origin) else { continue }
            let candidate = session.webSocketTask(with: url, protocols: [token])
            candidate.resume()
            let first: RemoteServerMessage
            switch await receive(from: candidate, timeout: config.handshakeTimeout) {
            case .message(let message):
                first = message
            case .failed:
                if Task.isCancelled { return }
                let alive = await healthOK(origin)
                // A disconnect() during the probe already moved us to .idle;
                // reporting .unauthorized on top of it would resurrect a link
                // the caller just tore down.
                if Task.isCancelled { return }
                if alive {
                    // The Mac answers HTTP but refused the upgrade: our token is gone.
                    setState(.unauthorized)
                    runner = nil
                    return
                }
                continue
            case .noUsableFrame:
                // The upgrade itself succeeded, so the token is fine — the
                // peer was merely slow or opened with a frame this build
                // cannot read. Probing `/health` here would call a live
                // pairing revoked; move on and let backoff retry instead.
                if Task.isCancelled { return }
                continue
            }
            // disconnect() cannot close this socket — it is not `self.socket`
            // until the handshake succeeds — so close it here rather than
            // leaving it open and flipping a torn-down link back online.
            if Task.isCancelled {
                candidate.cancel(with: .goingAway, reason: nil)
                return
            }
            guard case .hello(let version, let serverId, let name, _, let federationEnabled) = first else {
                candidate.cancel(with: .protocolError, reason: nil)
                continue
            }
            if version != config.localProtocolVersion {
                candidate.cancel(with: .goingAway, reason: nil)
                setState(.incompatible(remoteVersion: version))
                runner = nil
                return
            }
            // The `hello` on the socket that carries traffic — not only the
            // `/health` probe — has to prove this is the Mac the record was
            // written for. Whoever answers the origin would otherwise decide
            // the link's identity, and the manager would adopt it: a reused
            // address or a squatter could silently take a peer's place. Not
            // retried, because backoff against a wrong Mac never converges.
            if let expectedServerId, serverId != expectedServerId {
                candidate.cancel(with: .policyViolation, reason: nil)
                setState(.identityMismatch(expected: expectedServerId, actual: serverId))
                runner = nil
                return
            }
            socket = candidate
            if origin != lastOrigin {
                lastOrigin = origin
                onEvent(.originChanged(origin))
            }
            onEvent(.hello(serverId: serverId, name: name, protocolVersion: version, federationEnabled: federationEnabled))
            if let ack = try? JSONEncoder().encode(RemoteClientMessage.helloAck(protocolVersion: config.localProtocolVersion)) {
                candidate.send(.data(ack)) { _ in }
            }
            backoff = config.initialBackoff
            setState(.online)
            await pump(candidate)
            // A runner cancelled by disconnect() can reach here long after a
            // newer runner adopted a socket of its own, so close only the one
            // this attempt owns — never whatever happens to be current.
            closeSocket(.goingAway, ifCurrent: candidate)
            if Task.isCancelled { return }
            scheduleReconnect()
            return
        }
        if Task.isCancelled { return }
        scheduleReconnect()
    }

    private func pump(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let raw = try? await socket.receive() else { return }
            let payload: Data
            switch raw {
            case .data(let d): payload = d
            case .string(let s): payload = Data(s.utf8)
            @unknown default: continue
            }
            // Messages this build does not know are skipped, so a newer peer
            // never kills the link.
            guard let message = try? JSONDecoder().decode(RemoteServerMessage.self, from: payload) else { continue }
            onEvent(.message(message))
        }
    }

    /// What a handshake's first frame produced. `failed` is kept apart from
    /// `noUsableFrame` because only a failed receive can mean the peer refused
    /// the upgrade: a timeout or an unreadable frame both prove the socket was
    /// accepted, so probing `/health` on those would report a slow peer — or
    /// one a protocol revision ahead — as having revoked our pairing.
    private enum Handshake {
        case message(RemoteServerMessage)
        case failed
        case noUsableFrame
    }

    private func receive(from socket: URLSessionWebSocketTask, timeout: TimeInterval) async -> Handshake {
        await withTaskGroup(of: Handshake.self) { group in
            group.addTask {
                guard let raw = try? await socket.receive() else { return .failed }
                let payload: Data
                switch raw {
                case .data(let d): payload = d
                case .string(let s): payload = Data(s.utf8)
                @unknown default: return .noUsableFrame
                }
                guard let message = try? JSONDecoder().decode(RemoteServerMessage.self, from: payload) else {
                    return .noUsableFrame
                }
                return .message(message)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .noUsableFrame
            }
            let first = await group.next() ?? .failed
            switch first {
            case .message:
                break
            case .failed, .noUsableFrame:
                // `URLSessionWebSocketTask.receive()` does not observe task
                // cancellation, so on the timeout branch the group would wait
                // on it forever against a peer that upgraded and then went
                // quiet. Cancelling the socket is what ends that wait; the
                // caller discards this socket on every non-message outcome.
                socket.cancel(with: .goingAway, reason: nil)
            }
            group.cancelAll()
            return first
        }
    }

    /// Whether `origin` answers as the paired Mac. A 2xx alone only proves
    /// that *something* serves HTTP at this address, which is why `/health`
    /// reports a `serverId`: when this link knows which one to expect, an
    /// unrelated Alas — or any web server — on a reused address must not be
    /// read as "the paired Mac refused us", since that state is terminal.
    private func healthOK(_ origin: String) async -> Bool {
        struct Health: Decodable { let serverId: String? }
        guard let normalized = RemotePairingLink.normalizeOrigin(origin),
              let url = URL(string: normalized + "/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = config.handshakeTimeout
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        guard let expectedServerId else { return true }
        guard let health = try? JSONDecoder().decode(Health.self, from: data) else { return false }
        return health.serverId == expectedServerId
    }

    private func scheduleReconnect() {
        setState(.offline)
        runner = nil
        let delay = backoff
        backoff = min(backoff * 2, config.maxBackoff)
        // Never overwrite a live timer without cancelling it; the field is
        // all `disconnect()` has to reach them by.
        reconnectTimer?.cancel()
        reconnectTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTimer = nil
            self.connect()
        }
    }

    /// Closes the adopted socket. `ifCurrent` guards callers that own a
    /// particular socket: passing it makes the close a no-op unless that is
    /// still the adopted one, so a stale runner cannot cancel a live link's.
    private func closeSocket(_ code: URLSessionWebSocketTask.CloseCode,
                             ifCurrent expected: URLSessionWebSocketTask? = nil) {
        if let expected, socket !== expected { return }
        socket?.cancel(with: code, reason: nil)
        socket = nil
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onEvent(.stateChanged(new))
    }

    static func socketURL(for origin: String) -> URL? {
        // Origins reach a peer link from a stored record whose address the
        // peer itself advertised, so normalize before dialing: anything but
        // a bare http(s) origin is refused, and no path, query or userinfo
        // can be smuggled into the request target.
        guard let normalized = RemotePairingLink.normalizeOrigin(origin),
              var components = URLComponents(string: normalized) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        return components.url
    }
}
```

- [ ] **Step 4: Run `RemotePeerConnectionTests`**

Expected: `TEST SUCCEEDED`. If `rejectedTokenIsUnauthorizedAndStopsRetrying` flakes because `URLSessionWebSocketTask` surfaces the 401 slower than the handshake timeout, raise `handshakeTimeout` in `fastConfig` to 4; do not loosen the assertion.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Peer/RemotePeerConnection.swift AlasTests/Remote/RemotePeerConnectionTests.swift
git commit -m "feat(remote): add the outbound peer WebSocket connection"
```

---

### Task 10: `RemotePeerManager`

**Files:**
- Create: `Alas/Sources/Remote/Peer/RemotePeerManager.swift`
- Create: `AlasTests/Remote/RemotePeerManagerTests.swift`

**Interfaces:**
- Consumes: `RemotePeerStore`, `RemotePeer` (Task 5); `RemotePairingLink.parse`, `RemotePeerAdvertisement`, `RemotePeerPairingRequest` (Task 6); `RemotePeerPairer` (Task 8); `RemotePeerConnecting`, `RemotePeerConnection.Event` (Task 9); `RemotePairingService.beginPairing/revoke/devices`.
- Produces:

```swift
@MainActor @Observable final class RemotePeerManager {
    struct LocalIdentity { let serverId: String; let name: String; let origins: [String] }
    enum AddError: Error, Equatable { case invalidLink, expiredCode, originRejected, unreachable, noLocalAddress }
    private(set) var peers: [RemotePeer]
    private(set) var states: [String: RemotePeerConnection.State]
    var onRevokeDevice: (@MainActor (String) -> Void)?
    init(store:pairing:pairer: = .live, localIdentity:, makeConnection: = default, now: = { Date() })
    func addPeer(link: String) async -> AddError?
    func handleInboundPeer(_ request: RemotePeerPairingRequest) async
    func forget(peerId: String)
    func connectAll()
    func disconnectAll()
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Alas

@MainActor
struct RemotePeerManagerTests {
    @MainActor
    final class FakeLink: RemotePeerConnecting {
        var state: RemotePeerConnection.State = .idle
        var connectCalls = 0
        var disconnectCalls = 0
        let emit: @MainActor (RemotePeerConnection.Event) -> Void
        init(emit: @escaping @MainActor (RemotePeerConnection.Event) -> Void) { self.emit = emit }
        func connect() { connectCalls += 1 }
        func disconnect() { disconnectCalls += 1 }
        func send(_ message: RemoteClientMessage) {}
    }

    final class Links {
        var byPeerId: [String: FakeLink] = [:]
    }

    final class Requests {
        var seen: [URLRequest] = []
    }

    private let identity = RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "Mac B", origins: ["http://10.0.0.2:8765"])
    private let linkFromA = "http://10.0.0.1:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.1%3A8765"

    private func pairer(_ script: [String: (Int, String)], requests: Requests) -> RemotePeerPairer {
        RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            let key = "\(req.url!.host!):\(req.url!.port!)"
            guard let (status, body) = script[key] else { throw URLError(.cannotConnectToHost) }
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
    }

    private func makeManager(store: InMemoryPeerStore = InMemoryPeerStore(),
                             pairing: RemotePairingService = RemotePairingService(store: InMemoryDeviceStore()),
                             pairer: RemotePeerPairer, links: Links,
                             identity: RemotePeerManager.LocalIdentity? = nil) -> RemotePeerManager {
        let identity = identity ?? self.identity
        return RemotePeerManager(
            store: store, pairing: pairing, pairer: pairer,
            localIdentity: { identity },
            makeConnection: { peer, onEvent in
                let link = FakeLink(emit: onEvent)
                links.byPeerId[peer.id] = link
                return link
            },
            now: { Date(timeIntervalSince1970: 1000) })
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        // Two statements, not one: a `#require` nested inside another
        // `#require` is rejected as a recursive macro expansion.
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func invalidLinkIsRejectedWithoutNetwork() async {
        let requests = Requests()
        let manager = makeManager(pairer: pairer([:], requests: requests), links: Links())
        #expect(await manager.addPeer(link: "nope") == .invalidLink)
        #expect(requests.seen.isEmpty)
        #expect(manager.peers.isEmpty)
    }

    @Test func addPeerPairsStoresAndAdvertisesACounterCode() async throws {
        let requests = Requests()
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let store = InMemoryPeerStore()
        let links = Links()
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: links)
        manager.connectAll()
        #expect(await manager.addPeer(link: linkFromA) == nil)
        let peer = try #require(manager.peers.first)
        #expect(peer.serverId == "srv-a")
        #expect(peer.name == "Mac A")
        #expect(peer.token == "tokA")
        #expect(peer.origins == ["http://10.0.0.1:8765"])
        #expect(peer.lastOrigin == "http://10.0.0.1:8765")
        #expect(store.saved == manager.peers)
        #expect(links.byPeerId[peer.id]?.connectCalls == 1)

        let sent = try body(of: try #require(requests.seen.first))
        let ad = try #require(sent["peer"] as? [String: Any])
        #expect(ad["serverId"] as? String == "srv-b")
        #expect(ad["origins"] as? [String] == ["http://10.0.0.2:8765"])
        let counterCode = try #require(ad["counterCode"] as? String)
        // The counter-code is a real code on this Mac: A can redeem it.
        #expect((try? pairing.redeem(code: counterCode, deviceName: "Mac A")) != nil)
    }

    @Test func addPeerSurfacesPairerOutcomes() async {
        let expired = makeManager(pairer: pairer(["10.0.0.1:8765": (401, "{}")], requests: Requests()), links: Links())
        #expect(await expired.addPeer(link: linkFromA) == .expiredCode)
        let forbidden = makeManager(pairer: pairer(["10.0.0.1:8765": (403, "{}")], requests: Requests()), links: Links())
        #expect(await forbidden.addPeer(link: linkFromA) == .originRejected)
        let dead = makeManager(pairer: pairer([:], requests: Requests()), links: Links())
        #expect(await dead.addPeer(link: linkFromA) == .unreachable)
    }

    // With nothing to advertise, the far side's pair-back has nothing to dial
    // and revokes the device it just minted. Reporting success and then
    // "revoked" blames the other Mac for a local misconfiguration, so the add
    // is refused up front — before a counter-code is even minted.
    @Test func addPeerWithNoAdvertisableAddressIsRefusedBeforeAnyNetworkCall() async {
        let requests = Requests()
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let manager = makeManager(
            pairing: pairing,
            pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
            links: Links(),
            identity: RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "Mac B", origins: []))
        #expect(await manager.addPeer(link: linkFromA) == .noLocalAddress)
        #expect(requests.seen.isEmpty)
        #expect(manager.peers.isEmpty)
        #expect(pairing.devices.isEmpty)
    }

    @Test func inboundPeerWithCounterCodePairsBackWithoutNesting() async throws {
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests), links: Links())
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: "CC", localDeviceId: "dev-a"))
        let peer = try #require(manager.peers.first)
        #expect(peer.serverId == "srv-a")
        #expect(peer.token == "tokA")
        #expect(peer.localDeviceId == "dev-a")
        let sent = try body(of: try #require(requests.seen.first))
        #expect(sent["code"] as? String == "CC")
        let ad = try #require(sent["peer"] as? [String: Any])
        #expect(ad["counterCode"] == nil)
    }

    @Test func inboundPeerWithoutCounterCodeLinksTheDeviceRecord() async throws {
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests), links: Links())
        _ = await manager.addPeer(link: linkFromA)
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil, localDeviceId: "dev-a"))
        #expect(manager.peers.count == 1)
        #expect(manager.peers.first?.localDeviceId == "dev-a")
        #expect(requests.seen.count == 1)
    }

    @Test func forgetRevokesTheInboundDeviceAndDisconnects() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        var revoked: [String] = []
        let links = Links()
        let manager = makeManager(pairing: pairing,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
                                  links: links)
        manager.onRevokeDevice = { revoked.append($0) }
        manager.connectAll()
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: "CC", localDeviceId: inbound.deviceId))
        let peer = try #require(manager.peers.first)
        manager.forget(peerId: peer.id)
        #expect(manager.peers.isEmpty)
        #expect(manager.states[peer.id] == nil)
        #expect(links.byPeerId[peer.id]?.disconnectCalls == 1)
        #expect(revoked == [inbound.deviceId])
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    @Test func rePairingAnExistingPeerReplacesTheTokenMergesOriginsAndSwapsTheLink() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-a", addedAt: Date(timeIntervalSince1970: 1))])
        let links = Links()
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.9:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
                                  links: links)
        manager.connectAll()
        let oldLink = try #require(links.byPeerId["p1"])
        #expect(await manager.addPeer(link: "http://10.0.0.9:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765") == nil)
        #expect(manager.peers.count == 1)
        let peer = try #require(manager.peers.first)
        #expect(peer.id == "p1")
        #expect(peer.token == "tokA")
        #expect(peer.name == "Mac A")
        #expect(peer.origins == ["http://10.0.0.1:8765", "http://10.0.0.9:8765"])
        #expect(peer.lastOrigin == "http://10.0.0.9:8765")
        #expect(peer.localDeviceId == "dev-a")
        #expect(store.saved == manager.peers)
        // The stale link must be torn down, not left running alongside a
        // second one dialing the same peer with the new token.
        #expect(oldLink.disconnectCalls == 1)
        let newLink = try #require(links.byPeerId["p1"])
        #expect(newLink !== oldLink)
        #expect(newLink.connectCalls == 1)
    }

    @Test func forgetRevokesByPeerServerIdWhenNoLocalDeviceIdWasRecorded() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "Mac A", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: nil, token: "t", protocolVersion: nil, localDeviceId: nil, addedAt: Date())])
        var revoked: [String] = []
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: pairer([:], requests: Requests()), links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        manager.forget(peerId: "p1")
        #expect(manager.peers.isEmpty)
        #expect(revoked == [inbound.deviceId])
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    // The safety property that replaces the eviction `redeemPeer` used to do:
    // a peer redeem no longer invalidates an earlier record for the same
    // identity, so re-pairing can leave several device rows. Forgetting the
    // peer must take all of them, or a superseded token would stay valid
    // after the user revoked the peer.
    @Test func forgetRevokesEveryDeviceCarryingThePeersIdentity() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let first = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let second = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let other = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac C", peerServerId: "srv-c")
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "Mac A", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: nil, token: "t", protocolVersion: nil,
                               localDeviceId: first.deviceId, addedAt: Date())])
        var revoked: [String] = []
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: pairer([:], requests: Requests()), links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        manager.forget(peerId: "p1")
        #expect(pairing.validate(token: first.token) == nil)
        #expect(pairing.validate(token: second.token) == nil)
        #expect(revoked.sorted() == [first.deviceId, second.deviceId].sorted())
        // A different peer's access is untouched.
        #expect(pairing.validate(token: other.token) == other.deviceId)
    }

    @Test func linkEventsUpdateStateNameVersionAndOrigin() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765", "http://10.0.0.5:8765"],
                               lastOrigin: nil, token: "t", protocolVersion: nil, localDeviceId: nil, addedAt: Date())])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        let link = try #require(links.byPeerId["p1"])
        link.emit(.stateChanged(.online))
        link.emit(.hello(serverId: "srv-a", name: "Mac A", protocolVersion: 1, federationEnabled: true))
        link.emit(.originChanged("http://10.0.0.5:8765"))
        #expect(manager.states["p1"] == .online)
        #expect(manager.peers.first?.name == "Mac A")
        #expect(manager.peers.first?.protocolVersion == 1)
        #expect(manager.peers.first?.lastOrigin == "http://10.0.0.5:8765")
        #expect(store.saved.first?.lastOrigin == "http://10.0.0.5:8765")
    }

    // A `hello` is whatever answered the origin. Adopting its identity would
    // let a reassigned address or a squatter re-key the record, and because
    // `forget` revokes devices by identity the user would then revoke the
    // wrong peer's access while the impostor kept its own.
    @Test func helloNeverRewritesTheStoredServerId() throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: nil, token: "t", protocolVersion: nil, localDeviceId: nil, addedAt: Date())])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        let link = try #require(links.byPeerId["p1"])
        link.emit(.hello(serverId: "srv-impostor", name: "Mac A", protocolVersion: 1, federationEnabled: true))
        #expect(manager.peers.first?.serverId == "srv-a")
        #expect(store.saved.first?.serverId == "srv-a")
        // The cosmetic fields are still adopted.
        #expect(manager.peers.first?.name == "Mac A")
        #expect(manager.peers.first?.protocolVersion == 1)
    }

    @Test func connectAllIsIdempotentAndDisconnectAllTearsDown() {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "A", origins: ["http://10.0.0.1:8765"], lastOrigin: nil,
                               token: "t", protocolVersion: nil, localDeviceId: nil, addedAt: Date())])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        manager.connectAll()
        #expect(links.byPeerId["p1"]?.connectCalls == 1)
        manager.disconnectAll()
        #expect(links.byPeerId["p1"]?.disconnectCalls == 1)
        #expect(manager.states.isEmpty)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

`-only-testing AlasTests/RemotePeerManagerTests`. Expected: `RemotePeerManager` unknown.

- [ ] **Step 3: Implement**

`Alas/Sources/Remote/Peer/RemotePeerManager.swift`:

```swift
import Foundation
import Observation

/// Owns this Mac's outbound peers: the persisted records, one link each, and
/// both halves of reciprocal pairing. Session traffic over the links is
/// consumed by a later `FederatedSessionsProvider`; for now `.message`
/// events are dropped.
///
/// **The owner must call `disconnectAll()` before releasing this manager.**
/// It holds a `RemotePeerConnection` per peer, and dropping the last reference
/// to one of those is not enough to close it: a connected link keeps itself,
/// its task, and an authenticated socket to the peer alive until `disconnect()`
/// is called. Releasing the manager without `disconnectAll()` leaks one of each
/// per connected peer.
@MainActor
@Observable
final class RemotePeerManager {
    struct LocalIdentity: Equatable, Sendable {
        let serverId: String
        let name: String
        let origins: [String]
    }

    enum AddError: Error, Equatable {
        case invalidLink
        case expiredCode
        case originRejected
        case unreachable
        /// This Mac advertises no address a peer could dial back on, so the
        /// exchange cannot complete even if the far side is reachable.
        case noLocalAddress
    }

    typealias MakeConnection = @MainActor (RemotePeer, @escaping @MainActor (RemotePeerConnection.Event) -> Void) -> any RemotePeerConnecting

    private(set) var peers: [RemotePeer]
    private(set) var states: [String: RemotePeerConnection.State] = [:]
    /// Called with a `RemoteDevice.id` when forgetting a peer should also cut
    /// its live inbound socket. Nothing sets it yet; the owner that adopts this
    /// manager is expected to point it at `RemoteServer.disconnectDevice`,
    /// since revoking the device record alone leaves an open socket authorized.
    @ObservationIgnored var onRevokeDevice: (@MainActor (String) -> Void)?

    private let store: RemotePeerStore
    private let pairing: RemotePairingService
    private let pairer: RemotePeerPairer
    private let localIdentity: @MainActor () -> LocalIdentity
    private let makeConnection: MakeConnection
    private let now: () -> Date
    @ObservationIgnored private var connections: [String: any RemotePeerConnecting] = [:]
    @ObservationIgnored private var isActive = false

    init(store: RemotePeerStore,
         pairing: RemotePairingService,
         pairer: RemotePeerPairer = .live,
         localIdentity: @escaping @MainActor () -> LocalIdentity,
         makeConnection: @escaping MakeConnection = { peer, onEvent in
             // `expectedServerId` binds the link to the identity this record
             // was paired with: the socket's `hello` must report it or the
             // connection is refused, and the /health probe must report it
             // before a refused upgrade counts as "our token was revoked".
             // Without it, whatever answers a stored address decides both.
             RemotePeerConnection(
                 origins: peer.origins,
                 lastOrigin: peer.lastOrigin,
                 token: peer.token,
                 expectedServerId: peer.serverId,
                 onEvent: onEvent)
         },
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.pairing = pairing
        self.pairer = pairer
        self.localIdentity = localIdentity
        self.makeConnection = makeConnection
        self.now = now
        self.peers = store.load()
    }

    // MARK: - Pairing

    /// Pastes another Mac's pairing link: redeems its code there while
    /// offering a counter-code so that Mac pairs back with us.
    func addPeer(link: String) async -> AddError? {
        guard let parts = RemotePairingLink.parse(link) else { return .invalidLink }
        let me = localIdentity()
        // With no advertisable address the counter-code is unusable: the far
        // side's pair-back finds nothing to dial, gives up, and revokes the
        // device it just minted for us. Reporting success here and failing
        // moments later on "revoked" would blame the wrong machine, so refuse
        // before minting a code and point the user at their own settings.
        guard !me.origins.isEmpty else { return .noLocalAddress }
        let counterCode = pairing.beginPairing()
        let advertisement = RemotePeerAdvertisement(serverId: me.serverId, name: me.name, origins: me.origins, counterCode: counterCode)
        switch await pairer.pair(origins: parts.origins, code: parts.code, deviceName: me.name, advertisement: advertisement) {
        case .paired(let token, let serverId, let name, let origin):
            // An origin is an address, never an identity. Standing in for a
            // missing `serverId` with one would key the record — and the
            // `/health` probe's expected id, and the device records `forget`
            // revokes — on a string no peer will ever report, so the record
            // could never be matched again or revoked. A reply with no usable
            // identity is not a peer we can hold, so refuse the add. Only the
            // display name falls back to the origin.
            guard let serverId, !serverId.isEmpty else { return .unreachable }
            upsert(serverId: serverId, name: name ?? origin, origins: parts.origins,
                   lastOrigin: origin, token: token, localDeviceId: nil)
            return nil
        case .expiredCode: return .expiredCode
        case .originRejected: return .originRejected
        case .unreachable: return .unreachable
        }
    }

    /// The server saw another Mac redeem a code here. With a counter-code we
    /// are the responder and pair back; without one we are the initiator and
    /// only learn which local device record represents the peer.
    func handleInboundPeer(_ request: RemotePeerPairingRequest) async {
        if let counterCode = request.counterCode {
            let me = localIdentity()
            let advertisement = RemotePeerAdvertisement(serverId: me.serverId, name: me.name, origins: me.origins, counterCode: nil)
            guard case .paired(let token, _, _, let origin) = await pairer.pair(
                origins: request.origins, code: counterCode, deviceName: me.name, advertisement: advertisement)
            else {
                // The peer already holds a token for this Mac: it was minted
                // before this branch ran. Returning empty-handed would leave it
                // standing access with no peer record to forget it by, so take
                // the inbound grant back and let the exchange start over.
                pairing.revoke(deviceId: request.localDeviceId)
                onRevokeDevice?(request.localDeviceId)
                return
            }
            upsert(serverId: request.peerServerId, name: request.peerName, origins: request.origins,
                   lastOrigin: origin, token: token, localDeviceId: request.localDeviceId)
        } else if let index = peers.firstIndex(where: { $0.serverId == request.peerServerId }) {
            peers[index].localDeviceId = request.localDeviceId
            store.save(peers)
        }
    }

    func forget(peerId: String) {
        guard let index = peers.firstIndex(where: { $0.id == peerId }) else { return }
        let peer = peers.remove(at: index)
        connections[peerId]?.disconnect()
        connections[peerId] = nil
        states[peerId] = nil
        // Revoke by the peer's identity rather than by the stored
        // `localDeviceId`. That id is a snapshot taken before an HTTP round
        // trip, and a peer redeem adds a device row without removing earlier
        // ones for the same `peerServerId` — so a peer that re-paired in the
        // meantime is represented by several devices, at most one of which
        // the record remembers, and revoking the remembered id alone would
        // leave live tokens behind. Sweeping the identity is also what makes
        // that additive redeem safe. The stored id is still revoked as a
        // hint, for records written before the peer's device carried a
        // `peerServerId`.
        var deviceIds = pairing.devices
            .filter { $0.kind == .alasInstance && $0.peerServerId == peer.serverId }
            .map(\.id)
        if let hint = peer.localDeviceId, !deviceIds.contains(hint) { deviceIds.append(hint) }
        for deviceId in deviceIds {
            pairing.revoke(deviceId: deviceId)
            onRevokeDevice?(deviceId)
        }
        store.save(peers)
    }

    // MARK: - Links

    func connectAll() {
        isActive = true
        for peer in peers where connections[peer.id] == nil {
            connect(peer)
        }
    }

    func disconnectAll() {
        isActive = false
        for connection in connections.values { connection.disconnect() }
        connections = [:]
        states = [:]
    }

    private func connect(_ peer: RemotePeer) {
        connections[peer.id]?.disconnect()
        let id = peer.id
        let connection = makeConnection(peer) { [weak self] event in self?.handle(event, peerId: id) }
        connections[id] = connection
        connection.connect()
    }

    private func handle(_ event: RemotePeerConnection.Event, peerId: String) {
        switch event {
        case .stateChanged(let state):
            states[peerId] = state
        case .hello(_, let name, let protocolVersion, _):
            guard let index = peers.firstIndex(where: { $0.id == peerId }) else { return }
            // The identity is deliberately NOT adopted from the frame. It is
            // the key everything else hangs off — the link's expected id, the
            // `/health` check, and the device records `forget` revokes — so
            // letting the far side rewrite it would mean whoever answers the
            // origin decides who this record is. The connection this manager
            // builds is handed the record's `serverId` and refuses a socket
            // reporting a different one, so in practice the frame's id
            // already matches; ignoring it here is the backstop. Name and
            // protocol version are cosmetic and safe to take from the peer.
            peers[index].name = name
            peers[index].protocolVersion = protocolVersion
            store.save(peers)
        case .originChanged(let origin):
            guard let index = peers.firstIndex(where: { $0.id == peerId }) else { return }
            peers[index].lastOrigin = origin
            store.save(peers)
        case .message:
            break
        }
    }

    private func upsert(serverId: String, name: String, origins: [String], lastOrigin: String,
                        token: String, localDeviceId: String?) {
        let peer: RemotePeer
        if let index = peers.firstIndex(where: { $0.serverId == serverId }) {
            var merged = peers[index].origins
            for origin in origins where !merged.contains(origin) { merged.append(origin) }
            peers[index].name = name
            peers[index].origins = merged
            peers[index].lastOrigin = lastOrigin
            peers[index].token = token
            if let localDeviceId { peers[index].localDeviceId = localDeviceId }
            peer = peers[index]
        } else {
            peer = RemotePeer(id: UUID().uuidString, serverId: serverId, name: name, origins: origins,
                              lastOrigin: lastOrigin, token: token, protocolVersion: nil,
                              localDeviceId: localDeviceId, addedAt: now())
            peers.append(peer)
        }
        store.save(peers)
        if isActive { connect(peer) }
    }
}
```

- [ ] **Step 4: Run `RemotePeerManagerTests`**

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Peer/RemotePeerManager.swift AlasTests/Remote/RemotePeerManagerTests.swift
git commit -m "feat(remote): add the peer manager with reciprocal pairing"
```

---

### Task 11: Wire the manager into `AppState`

**Files:**
- Modify: `Alas/Sources/App/AppState.swift:455-480, 570-640`
- Modify: `Alas/Sources/Settings/AdvancedPane.swift` (the row added in Task 1)

**Interfaces:**
- Consumes: `RemotePeerManager` (Task 10), `RemoteServer.onPeerPaired` (Task 7).
- Produces: `AppState.remotePeers: RemotePeerManager`, `AppState.syncRemotePeers()`.

- [ ] **Step 1: Add the manager**

After the `remotePairing` declaration (`AppState.swift:460-461`):

```swift
    /// Outbound peers (other Macs running Alas). Lazy like `remotePairing`.
    @ObservationIgnored
    private(set) lazy var remotePeers: RemotePeerManager = {
        let manager = RemotePeerManager(
            store: FilePeerStore(),
            pairing: remotePairing,
            localIdentity: { [weak self] in
                RemotePeerManager.LocalIdentity(
                    serverId: self?.config.remote.serverId ?? "",
                    name: self?.remoteDisplayName ?? "Alas",
                    // Loopback is meaningless to another Mac; everything else is in rank order.
                    origins: self?.remoteAdvertisedAddresses.filter { $0.kind != .localhost }.map(\.url) ?? [])
            })
        manager.onRevokeDevice = { [weak self] deviceId in
            self?.remoteServer?.disconnectDevice(deviceId)
        }
        return manager
    }()
```

- [ ] **Step 2: Hook the server and lifecycle**

In `syncRemoteServer()`:

Inside `guard remoteServer == nil else { ... }` add `syncRemotePeers()` after `refreshRemoteAccessState()`.

After `server.onConnectionDeviceCountsChange = ...` add:

```swift
            server.onPeerPaired = { [weak self] request in
                Task { @MainActor in await self?.remotePeers.handleInboundPeer(request) }
            }
```

After `lastRemoteError = nil` inside the `do` block add `syncRemotePeers()`.

In the `else` (disabled) branch, before `remoteServer?.stop()` add
`if remoteServer != nil { remotePeers.disconnectAll() }`. The guard is the
point: `remotePeers` is lazy and its initializer also takes `remotePairing`,
so an unconditional call would build both and read `remote-peers.json` and
`remote-devices.json` on every ordinary launch with the flags off. Links only
exist while a server is up, so there is nothing to tear down otherwise. The
check is safe there because the line that nils `remoteServer` comes after it.

Add the method after `syncRemoteServer()`:

```swift
    /// Keeps peer links alive only while the server is up and the experiment
    /// is on; peers stay stored either way.
    func syncRemotePeers() {
        if config.remote.enabled, config.remote.federationEnabled, remoteServer != nil {
            remotePeers.connectAll()
        } else if remoteServer != nil {
            // Same reason as `syncRemoteServer`'s disabled branch: without a
            // server no link was ever opened, and reaching for `remotePeers`
            // would force the lazy manager and its stores into existence.
            remotePeers.disconnectAll()
        }
    }
```

- [ ] **Step 3: Make the toggle drive the links**

In the "Remote peers" `AlasToggle` setter from Task 1, after `state.saveConfig()` add `state.syncRemotePeers()` before `broadcastHello()`.

- [ ] **Step 4: Build**

Run the build-only command. Expected: `exit=0`.

- [ ] **Step 5: Run the app-level remote suite**

`-only-testing AlasTests/RemoteAppStateAccessTests`. Expected: `TEST SUCCEEDED` (it constructs `AppState`; the lazy manager must not touch disk until used).

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/App/AppState.swift Alas/Sources/Settings/AdvancedPane.swift
git commit -m "feat(remote): keep peer links in step with the server and the flag"
```

---

### Task 12: Peers section in Settings → Remote

**Files:**
- Modify: `Alas/Sources/Remote/Settings/RemoteServerPane.swift` (after the "Paired devices" group, line 204; helpers near line 255)

**Interfaces:**
- Consumes: `AppState.remotePeers` (Task 11), `RemotePeerConnection.State`, `RemotePeerManager.AddError`.

- [ ] **Step 1: Add state**

Next to `@State private var pairingCode` at the top of the view:

```swift
    @State private var peerLink = ""
    @State private var peerError: String?
    @State private var isAddingPeer = false
```

- [ ] **Step 2: Add the group**

After the "Paired devices" `SettingsGroup` closes (line 204):

```swift
            if state.config.remote.enabled, state.config.remote.federationEnabled {
                SettingsGroup(title: "Peers") {
                    if state.remotePeers.peers.isEmpty {
                        SettingsRow(name: "No peers", desc: "Paste another Mac's pairing link below. Both Macs end up paired with each other.") {
                            EmptyView()
                        }
                    }
                    ForEach(state.remotePeers.peers) { peer in
                        SettingsRow(name: peer.name, desc: peerStatus(peer)) {
                            AlasButton(title: "Forget", style: .subtle) {
                                state.remotePeers.forget(peerId: peer.id)
                            }
                        }
                    }
                    SettingsRow(name: "Add peer", desc: "Copy the pairing link from the other Mac's Remote settings and paste it here.") {
                        HStack(spacing: 8) {
                            AlasField(text: $peerLink, placeholder: "http://…/?code=…&hosts=…")
                                .frame(minWidth: 260)
                            AlasButton(title: isAddingPeer ? "Adding…" : "Add", style: .subtle) {
                                addPeer()
                            }
                            .disabled(isAddingPeer || peerLink.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let peerError {
                        Text(peerError)
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("danger"))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                }
            }
```

If `theme.color("danger")` does not exist in `Theme`, use the colour the "Error" row at lines 38-42 uses.

- [ ] **Step 3: Add the helpers**

Next to `copyAddress` (line 255):

```swift
    private func peerStatus(_ peer: RemotePeer) -> String {
        switch state.remotePeers.states[peer.id] ?? .idle {
        case .online: return "Online via \(peer.lastOrigin ?? peer.origins.first ?? "")"
        case .connecting: return "Connecting…"
        case .offline: return "Offline. Retrying."
        case .unauthorized: return "This Mac's token was revoked there. Forget and pair again."
        case .incompatible(let version): return "Needs a matching Alas version (protocol \(version))."
        case .identityMismatch:
            return "A different Mac answered at that address. Forget this peer and pair again."
        case .idle: return "Not connected"
        }
    }

    private func addPeer() {
        isAddingPeer = true
        peerError = nil
        let link = peerLink
        Task { @MainActor in
            let error = await state.remotePeers.addPeer(link: link)
            isAddingPeer = false
            switch error {
            case nil:
                peerLink = ""
            case .invalidLink?:
                peerError = "That doesn't look like an Alas pairing link."
            case .expiredCode?:
                peerError = "That code expired. Tap Pair a device on the other Mac and copy a fresh link."
            case .originRejected?:
                peerError = "That Mac doesn't accept peers. Turn on Remote peers in its Advanced settings."
            case .unreachable?:
                peerError = "Couldn't reach that Mac at any of its addresses."
            case .noLocalAddress?:
                peerError = "This Mac has no address the other Mac could reach it at. Check the addresses above in Remote settings."
            }
        }
    }
```

- [ ] **Step 4: Mark Alas peers in "Paired devices"**

In the `ForEach(state.remotePairing.devices)` row (line 159-162), prefix the description with `"Alas peer. "` when `device.kind == .alasInstance`:

```swift
                        let prefix = device.kind == .alasInstance ? "Alas peer. " : ""
```

and use `prefix + <existing description expression>` where the row builds its `desc`.

- [ ] **Step 5: Build**

Run the build-only command. Expected: `exit=0`.

- [ ] **Step 6: Manual check on two Macs (or two builds on one Mac with distinct ports and Application Support dirs)**

1. On both: Settings → Remote, enable remote control. Settings → Advanced, turn on "Remote peers".
2. On Mac A: Pair a device → Copy pairing link.
3. On Mac B: Settings → Remote → Peers → paste → Add. Expect B's row for A to reach "Online via http://…" within a few seconds, and A's Peers group to show B online without any action on A.
4. On A, Paired devices lists "Mac B" with the "Alas peer." prefix. Same on B for A.
5. On A: Forget B. Expect A's row gone, B's row for A to go "Offline" then, after B reconnects and is refused, "revoked".
6. Turn off "Remote peers" on B: rows disappear and links drop. Turn it back on: they reconnect without re-pairing.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Remote/Settings/RemoteServerPane.swift
git commit -m "feat(remote): add the Peers section to Remote settings"
```

---

## Follow-on plans (not in this document)

Each is its own plan file, in this order:

1. **Bonjour discovery** (`docs/superpowers/plans/…-federation-phase-2-discovery.md`): `NWListener.service` with `_alas._tcp` plus `NWBrowser`, a "Discoverable on this network" toggle, and a browsed list in the Peers group that feeds `addPeer` by fetching `/remote-info` for the pairing link's `hosts`. Still needs a code from the other Mac.
2. **FederatedSessionsProvider** (`…-federation-phase-3-gateway.md`): composes the local `RemoteSessionsProvider` with `RemotePeerManager` links, namespaces IDs as `serverId:sessionId`, forwards subscribe/prompt/permission traffic, refuses to re-export rows that already carry a `serverId`, and adds optional `serverId`/`serverName` to `RemoteSessionSummary`. Also the native sidebar view of peer sessions.
3. **Web client grouping** (`…-federation-phase-4-web.md`): group `sessionList` rows by `serverId` in `app.js`, and let `hub-links.js` take badge counts from a gateway's pushed list when the active server's `hello` says `federationEnabled`.
