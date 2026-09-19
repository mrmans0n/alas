# Remote Hub: Multi-Server Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one installed remote web client pair with several Macs, show which are online and need attention, and switch between them, behind an experiment flag.

**Architecture:** The Mac gains a stable identity, a `hello` handshake frame, an Origin policy with CORS on the pairing and health routes, and a richer pairing link. The web client gains two DOM-free modules, a persisted server registry and a link manager owning one socket per server, while `app.js` keeps driving the active link through its existing `send`/`handle` path. Hub UI is rendered only when the active Mac's `hello` says `hubEnabled`.

**Tech Stack:** Swift 5.9+/SwiftUI, Network.framework server, Swift Testing; vanilla JS client with node unit tests under `scripts/tests/`.

**Spec:** `docs/superpowers/specs/2026-09-19-remote-hub-multi-server-design.md`

## Global Constraints

- Code, comments, logs, UI strings in English. No agent attribution in commits.
- Tests use `import Testing`, never XCTest.
- Protocol version constant is `1`; `hello` is the first frame on every socket.
- Pairing link shape: `http://<preferred-host>:<port>/?code=<CODE>&hosts=<origin1>,<origin2>,…` with each origin percent-encoded and the base origin always first.
- Client storage key `alas.remote.hub`, schema version `1`; legacy key `alas.remote.token` is migrated then removed.
- Timeouts: handshake and pairing attempt 4 s per origin; idle poll 30 s; reconnect backoff 1.5 s doubling to 30 s; existing 5 s escalation grace unchanged.
- Link states: `idle`, `connecting`, `online`, `offline`, `unauthorized`.
- Config field names: `remote.serverId`, `remote.displayName`, `remote.hubEnabled` (default false), `remote.allowedOrigins`.
- Every `?v=` bump touches both `index.html` and `sw.js`; `sw.js` cache name bumps too.
- Local Swift test invocation (see Testing notes at the end of this file):

  ```bash
  export ALAS_ZMX_OPTIONAL=1 ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_TARGET_ARCH=arm64
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' \
    ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing AlasTests/<Suite> test > /tmp/alas-test.log 2>&1
  grep -E "Test run with|TEST (SUCCEEDED|FAILED)|error:" /tmp/alas-test.log | tail -20
  ```

  If the "Build zmx" phase fails on network, run `git submodule deinit -f ThirdParty/zmx` first and `git submodule update --init ThirdParty/zmx` when done.

---

## File Structure

**Swift, modified**
- `Alas/Sources/Persistence/AppConfig.swift` — `Remote` gains `allowedOrigins`, `serverId`, `displayName`, `hubEnabled`, `ensureServerId()`.
- `Alas/Sources/Settings/AdvancedPane.swift` — "Remote hub" experiment toggle.
- `Alas/Sources/Remote/Protocol/RemoteProtocol.swift` — `RemoteProtocolVersion`, `RemoteServerIdentity`, `.hello` case.
- `Alas/Sources/Remote/Settings/RemoteNetwork.swift` — `isPrivateOrLocalHost(_:)`.
- `Alas/Sources/Remote/Server/RemoteHTTPResponder.swift` — CORS, `OPTIONS /pair`, `extraHeaders`, snapshot identity fields.
- `Alas/Sources/Remote/Server/RemoteConnection.swift` — Origin gate, `hello` after 101.
- `Alas/Sources/Remote/Server/RemoteServer.swift` — origin policy + identity plumbing.
- `Alas/Sources/App/AppState.swift` — origin policy, identity, `ensureServerId` on enable.
- `Alas/Sources/Remote/Settings/RemoteServerPane.swift` — Server name field, Copy pairing link.

**Swift, created**
- `Alas/Sources/Remote/Server/RemoteOriginPolicy.swift` — browser Origin allow/deny.
- `Alas/Sources/Remote/Pairing/RemotePairingLink.swift` — pure link builder.
- Tests: `AlasTests/Remote/RemoteOriginPolicyTests.swift`, `RemoteHTTPResponderTests.swift`, `RemotePairingLinkTests.swift`; extended `RemoteConfigTests`, `RemoteProtocolTests`, `RemoteServerIntegrationTests`, `RemoteWebAssetTests`.

**Client, created**
- `Alas/Resources/RemoteWeb/hub-registry.js` — persisted registry, link parsing, merge, counts (pure).
- `Alas/Resources/RemoteWeb/hub-links.js` — per-server sockets, origin fallback, polling, probing, pairing HTTP (deps injected).
- `scripts/tests/remote-web-hub/{run.sh,test-hub-registry.js,test-hub-links.js}`.

**Client, modified**
- `Alas/Resources/RemoteWeb/app.js` — active link hooks, pairing, switching, Settings tab UI.
- `Alas/Resources/RemoteWeb/index.html`, `sw.js`, `style.css`, `.github/workflows/build.yml`.

---

### Task 1: Config fields and the experiment toggle

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift:58-87`
- Modify: `Alas/Sources/Settings/AdvancedPane.swift:18-46`
- Test: `AlasTests/Remote/RemoteConfigTests.swift`

**Interfaces:**
- Produces: `AppConfig.Remote.allowedOrigins: [String]`, `serverId: String`, `displayName: String`, `hubEnabled: Bool`, `mutating func ensureServerId() -> Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `AlasTests/Remote/RemoteConfigTests.swift` inside the struct:

```swift
    @Test func remoteConfigHubFieldsDefault() {
        let cfg = AppConfig.defaults
        #expect(cfg.remote.allowedOrigins == [])
        #expect(cfg.remote.serverId == "")
        #expect(cfg.remote.displayName == "")
        #expect(cfg.remote.hubEnabled == false)
    }

    @Test func ensureServerIdAssignsOnceAndStaysStable() {
        var remote = AppConfig.Remote()
        #expect(remote.ensureServerId() == true)
        let first = remote.serverId
        #expect(!first.isEmpty)
        #expect(remote.ensureServerId() == false)
        #expect(remote.serverId == first)
    }

    @Test func remoteConfigHubFieldsRoundTripJSON() throws {
        var cfg = AppConfig.defaults
        cfg.remote.allowedOrigins = ["https://app.alas.build"]
        cfg.remote.serverId = "srv-1"
        cfg.remote.displayName = "Studio Mac"
        cfg.remote.hubEnabled = true
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(back.remote.allowedOrigins == ["https://app.alas.build"])
        #expect(back.remote.serverId == "srv-1")
        #expect(back.remote.displayName == "Studio Mac")
        #expect(back.remote.hubEnabled == true)
    }

    @Test func oldRemoteConfigWithoutHubFieldsDecodesDefaults() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var remote = try #require(json["remote"] as? [String: Any])
        for key in ["allowedOrigins", "serverId", "displayName", "hubEnabled"] { remote.removeValue(forKey: key) }
        json["remote"] = remote
        let back = try JSONDecoder().decode(AppConfig.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(back.remote.allowedOrigins == [])
        #expect(back.remote.serverId == "")
        #expect(back.remote.displayName == "")
        #expect(back.remote.hubEnabled == false)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the Global Constraints command with `-only-testing AlasTests/RemoteConfigTests`.
Expected: compile error, `Remote` has no member `allowedOrigins` / `ensureServerId`.

- [ ] **Step 3: Implement the config fields**

Replace the `Remote` struct in `AppConfig.swift` (lines 58–87) with:

```swift
    struct Remote: Codable, Equatable {
        var enabled: Bool = false
        var port: UInt16 = 0          // 0 = OS-assigned
        var allowedHosts: [String] = []
        var preferredAdvertisedHost: String? = nil
        /// Browser origins allowed to pair with and connect to this Mac, in
        /// addition to private-network and Host-allowlisted origins.
        var allowedOrigins: [String] = []
        /// Stable identity advertised in the WebSocket `hello`. Empty until
        /// `ensureServerId()` assigns one.
        var serverId: String = ""
        /// Name advertised in `hello`. Empty means "use the computer name".
        var displayName: String = ""
        /// Experiment: lets the remote web client pair with several Macs.
        var hubEnabled: Bool = false

        init(
            enabled: Bool = false,
            port: UInt16 = 0,
            allowedHosts: [String] = [],
            preferredAdvertisedHost: String? = nil,
            allowedOrigins: [String] = [],
            serverId: String = "",
            displayName: String = "",
            hubEnabled: Bool = false
        ) {
            self.enabled = enabled
            self.port = port
            self.allowedHosts = allowedHosts
            self.preferredAdvertisedHost = preferredAdvertisedHost
            self.allowedOrigins = allowedOrigins
            self.serverId = serverId
            self.displayName = displayName
            self.hubEnabled = hubEnabled
        }

        enum CodingKeys: String, CodingKey {
            case enabled, port, allowedHosts, preferredAdvertisedHost
            case allowedOrigins, serverId, displayName, hubEnabled
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
            port = (try? c.decode(UInt16.self, forKey: .port)) ?? 0
            allowedHosts = (try? c.decode([String].self, forKey: .allowedHosts)) ?? []
            preferredAdvertisedHost = try? c.decodeIfPresent(String.self, forKey: .preferredAdvertisedHost)
            allowedOrigins = (try? c.decode([String].self, forKey: .allowedOrigins)) ?? []
            serverId = (try? c.decode(String.self, forKey: .serverId)) ?? ""
            displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
            hubEnabled = (try? c.decode(Bool.self, forKey: .hubEnabled)) ?? false
        }

        /// Assigns a fresh UUID when `serverId` is empty. Returns true when it changed.
        @discardableResult
        mutating func ensureServerId() -> Bool {
            guard serverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            serverId = UUID().uuidString
            return true
        }
    }
```

- [ ] **Step 4: Add the experiment toggle**

In `AdvancedPane.swift`, after the "Needs attention" `SettingsRow` (ends line 46) and before `if let recovery`, add:

```swift
                    SettingsRow(
                        name: "Remote hub",
                        desc: "Lets the remote web client pair with several Macs and switch between them."
                    ) {
                        AlasToggle(on: Binding(
                            get: { state.config.remote.hubEnabled },
                            set: { enabled in
                                state.config.remote.hubEnabled = enabled
                                state.saveConfig()
                            }
                        ))
                    }
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `-only-testing AlasTests/RemoteConfigTests`. Expected: all tests pass, including the four new ones.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Persistence/AppConfig.swift Alas/Sources/Settings/AdvancedPane.swift AlasTests/Remote/RemoteConfigTests.swift
git commit -m "feat(remote): add server identity, display name, and hub experiment config"
```

---

### Task 2: Protocol version and the `hello` message

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift:1-2, 345-346, 398-406, 410, 578`
- Modify: `Alas/Sources/Remote/Server/RemoteHTTPResponder.swift:3-10`
- Test: `AlasTests/Remote/RemoteProtocolTests.swift`

**Interfaces:**
- Produces: `RemoteProtocolVersion.current: Int`, `RemoteServerIdentity(serverId:name:hubEnabled:)`, `RemoteServerMessage.hello(protocolVersion:serverId:name:hubEnabled:)`, `RemoteServerMessage.hello(_ identity:)`, `RemoteDiagnosticsSnapshot.serverId/name` (optional, default nil).

- [ ] **Step 1: Write the failing tests**

Append inside `RemoteProtocolTests`:

```swift
    @Test func helloRoundTripsAndEncodesIdentityFields() throws {
        let hello = RemoteServerMessage.hello(RemoteServerIdentity(serverId: "srv-1", name: "Nacho's Mac", hubEnabled: true))
        #expect(try roundTrip(hello) == hello)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any])
        #expect(object["type"] as? String == "hello")
        #expect(object["protocolVersion"] as? Int == RemoteProtocolVersion.current)
        #expect(object["serverId"] as? String == "srv-1")
        #expect(object["name"] as? String == "Nacho's Mac")
        #expect(object["hubEnabled"] as? Bool == true)
    }

    @Test func helloWithoutHubFlagDecodesDisabled() throws {
        let data = Data(#"{"type":"hello","protocolVersion":1,"serverId":"s","name":"n"}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: data)
        #expect(decoded == .hello(protocolVersion: 1, serverId: "s", name: "n", hubEnabled: false))
    }

    @Test func diagnosticsSnapshotDecodesWithoutIdentityFields() throws {
        let data = Data(#"{"appName":"Alas","port":8765,"addresses":[],"usesPlainHTTP":true,"pairedDeviceCount":0}"#.utf8)
        let snapshot = try JSONDecoder().decode(RemoteDiagnosticsSnapshot.self, from: data)
        #expect(snapshot.serverId == nil)
        #expect(snapshot.name == nil)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `-only-testing AlasTests/RemoteProtocolTests`. Expected: compile error, no `RemoteProtocolVersion` / `.hello`.

- [ ] **Step 3: Add the version, identity, and message case**

At the top of `RemoteProtocol.swift`, after `import Foundation`:

```swift
/// Wire protocol version advertised in `hello`. Bump only for changes an
/// older client or server cannot tolerate; additive optional fields do not
/// count.
enum RemoteProtocolVersion {
    static let current = 1
}

/// What a Mac says about itself in the first frame of every socket.
struct RemoteServerIdentity: Equatable, Sendable {
    let serverId: String
    let name: String
    let hubEnabled: Bool
}
```

In `enum RemoteServerMessage`, add as the first case (before `sessionList`):

```swift
    /// First frame after a successful upgrade, before any reply.
    case hello(protocolVersion: Int, serverId: String, name: String, hubEnabled: Bool)
```

Add `protocolVersion, serverId, name, hubEnabled` to the `CodingKeys` enum (a new line after `case metadataNote, commitsTruncated`):

```swift
        case protocolVersion, serverId, name, hubEnabled
```

In `init(from:)`, add before `case "sessionList"`:

```swift
        case "hello":
            self = .hello(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                serverId: try c.decode(String.self, forKey: .serverId),
                name: try c.decode(String.self, forKey: .name),
                hubEnabled: try c.decodeIfPresent(Bool.self, forKey: .hubEnabled) ?? false)
```

In `encode(to:)`, add before `case .sessionList`:

```swift
        case .hello(let protocolVersion, let serverId, let name, let hubEnabled):
            try c.encode("hello", forKey: .type)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(serverId, forKey: .serverId)
            try c.encode(name, forKey: .name)
            try c.encode(hubEnabled, forKey: .hubEnabled)
```

At the end of the file:

```swift
extension RemoteServerMessage {
    static func hello(_ identity: RemoteServerIdentity) -> RemoteServerMessage {
        .hello(
            protocolVersion: RemoteProtocolVersion.current,
            serverId: identity.serverId,
            name: identity.name,
            hubEnabled: identity.hubEnabled)
    }
}
```

- [ ] **Step 4: Extend the diagnostics snapshot**

Replace `RemoteDiagnosticsSnapshot` in `RemoteHTTPResponder.swift` (lines 3–10):

```swift
/// Safe, user-facing remote diagnostics served by `/remote-info`.
struct RemoteDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let appName: String
    let port: UInt16?
    let addresses: [RemoteAdvertisedAddress]
    let usesPlainHTTP: Bool
    let pairedDeviceCount: Int
    let serverId: String?
    let name: String?

    init(
        appName: String,
        port: UInt16?,
        addresses: [RemoteAdvertisedAddress],
        usesPlainHTTP: Bool,
        pairedDeviceCount: Int,
        serverId: String? = nil,
        name: String? = nil
    ) {
        self.appName = appName
        self.port = port
        self.addresses = addresses
        self.usesPlainHTTP = usesPlainHTTP
        self.pairedDeviceCount = pairedDeviceCount
        self.serverId = serverId
        self.name = name
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `-only-testing AlasTests/RemoteProtocolTests`. Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Protocol/RemoteProtocol.swift Alas/Sources/Remote/Server/RemoteHTTPResponder.swift AlasTests/Remote/RemoteProtocolTests.swift
git commit -m "feat(remote): add the hello handshake message and protocol version"
```

---

### Task 3: Origin policy

**Files:**
- Modify: `Alas/Sources/Remote/Settings/RemoteNetwork.swift:194-202`
- Create: `Alas/Sources/Remote/Server/RemoteOriginPolicy.swift`
- Test: `AlasTests/Remote/RemoteOriginPolicyTests.swift`

**Interfaces:**
- Consumes: `RemoteAccessPolicy.allows(hostHeader:)`, `RemoteNetwork.normalizedHost(_:)`.
- Produces: `RemoteNetwork.isPrivateOrLocalHost(_ host: String) -> Bool`; `RemoteOriginPolicy(hostPolicy:allowedOrigins:)`, `.loopback`, `allows(originHeader: String?) -> Bool`, `static parse(_:) -> ParsedOrigin?` with `.normalized`.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/Remote/RemoteOriginPolicyTests.swift`:

```swift
import Testing
@testable import Alas

struct RemoteOriginPolicyTests {
    private let policy = RemoteOriginPolicy(
        hostPolicy: RemoteAccessPolicy(allowedHosts: ["localhost", "127.0.0.1", "::1", "proxy.example.com"]),
        allowedOrigins: ["https://app.alas.build"]
    )

    @Test func allowsAbsentOrigin() {
        #expect(policy.allows(originHeader: nil))
        #expect(policy.allows(originHeader: ""))
        #expect(policy.allows(originHeader: "   "))
    }

    @Test func allowsPrivateNetworkOrigins() {
        for origin in [
            "http://192.168.1.20:8765", "http://10.0.0.5:8765", "http://172.16.4.4:8765",
            "http://100.64.1.5:8765", "http://[fd7a:115c:a1e0::1]:8765", "http://[fc00::1]:8765",
            "http://localhost:8765", "http://127.0.0.1:8765", "http://[::1]:8765",
            "http://169.254.1.1:8765", "http://[fe80::1]:8765",
        ] {
            #expect(policy.allows(originHeader: origin), "\(origin)")
        }
    }

    @Test func allowsDotLocalAndHostAllowlistedNames() {
        #expect(policy.allows(originHeader: "http://nacho-mbp.local:8765"))
        #expect(policy.allows(originHeader: "https://proxy.example.com"))
        #expect(policy.allows(originHeader: "https://PROXY.example.com:443"))
    }

    @Test func allowsConfiguredOriginsExactly() {
        #expect(policy.allows(originHeader: "https://app.alas.build"))
        #expect(!policy.allows(originHeader: "https://app.alas.build:444"))
        #expect(!policy.allows(originHeader: "http://app.alas.build"))
    }

    @Test func rejectsPublicAndMalformedOrigins() {
        for origin in [
            "https://evil.example", "http://8.8.8.8:8765", "null", "file://",
            "http://192.168.1.20:8765/path", "ftp://192.168.1.20", "http://user@192.168.1.20:8765",
        ] {
            #expect(!policy.allows(originHeader: origin), "\(origin)")
        }
    }

    @Test func parseNormalizesSchemeHostAndPort() {
        #expect(RemoteOriginPolicy.parse("HTTP://Nacho-MBP.local:8765")?.normalized == "http://nacho-mbp.local:8765")
        #expect(RemoteOriginPolicy.parse("http://[::1]:8765")?.host == "::1")
        #expect(RemoteOriginPolicy.parse("http://[::1]:8765")?.normalized == "http://[::1]:8765")
        #expect(RemoteOriginPolicy.parse("https://app.alas.build")?.port == nil)
    }

    @Test func privateHostClassifierCoversLoopbackLinkLocalAndPrivateRanges() {
        for host in ["localhost", "127.0.0.1", "127.5.5.5", "::1", "10.1.1.1", "192.168.0.1", "172.31.0.1",
                     "100.64.0.1", "100.127.255.255", "169.254.9.9", "fe80::1", "fd7a:115c:a1e0::1", "fc00::1"] {
            #expect(RemoteNetwork.isPrivateOrLocalHost(host), host)
        }
        for host in ["8.8.8.8", "100.128.0.1", "example.com", "2001:db8::1", ""] {
            #expect(!RemoteNetwork.isPrivateOrLocalHost(host), host)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `-only-testing AlasTests/RemoteOriginPolicyTests`. Expected: compile error.

- [ ] **Step 3: Add the host classifier**

In `RemoteNetwork.swift`, after `normalizedHost` (line 179) add:

```swift
    /// True for hosts a browser on the user's own network would be served
    /// from: loopback, link-local, RFC 1918, Tailscale CGNAT/ULA, and IPv6
    /// unique-local. Public addresses and DNS names are false.
    static func isPrivateOrLocalHost(_ host: String) -> Bool {
        let normalized = normalizedHost(host)
        if normalized == "localhost" || normalized == "::1" { return true }
        if let octets = ipv4Octets(normalized) {
            if octets[0] == 127 { return true }
            if octets[0] == 169 && octets[1] == 254 { return true }
            return isLANIPv4(normalized) || isTailnetIPv4(normalized)
        }
        if let bytes = ipv6Bytes(normalized) {
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }   // fe80::/10
            return isLANIPv6(normalized) || isTailnetIPv6(normalized)
        }
        return false
    }
```

- [ ] **Step 4: Create the policy**

Create `Alas/Sources/Remote/Server/RemoteOriginPolicy.swift`:

```swift
import Foundation

/// Decides whether a browser `Origin` may pair with, probe, or open a socket
/// to this Mac. An absent Origin (non-browser clients, same-origin
/// navigations) is allowed. A present Origin must be a private-network or
/// `.local` host, a host the `RemoteAccessPolicy` allowlist already trusts,
/// or an explicitly configured origin. Applied alongside the Host check,
/// never instead of it.
struct RemoteOriginPolicy: Equatable, Sendable {
    struct ParsedOrigin: Equatable, Sendable {
        let scheme: String
        let host: String      // lowercased, no brackets
        let port: Int?

        /// `scheme://host[:port]` with IPv6 hosts bracketed.
        var normalized: String {
            "\(scheme)://\(hostHeader)" + (port.map { ":\($0)" } ?? "")
        }

        /// The shape `RemoteAccessPolicy.allows(hostHeader:)` expects.
        var hostHeader: String { host.contains(":") ? "[\(host)]" : host }
    }

    private let hostPolicy: RemoteAccessPolicy
    private let allowedOrigins: Set<String>

    init(hostPolicy: RemoteAccessPolicy, allowedOrigins: [String]) {
        self.hostPolicy = hostPolicy
        self.allowedOrigins = Set(allowedOrigins.compactMap { Self.parse($0)?.normalized })
    }

    static let loopback = RemoteOriginPolicy(hostPolicy: .loopback, allowedOrigins: [])

    func allows(originHeader: String?) -> Bool {
        guard let raw = originHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return true
        }
        guard let origin = Self.parse(raw) else { return false }
        if allowedOrigins.contains(origin.normalized) { return true }
        if hostPolicy.allows(hostHeader: origin.hostHeader) { return true }
        if RemoteNetwork.isPrivateOrLocalHost(origin.host) { return true }
        return origin.host.hasSuffix(".local")
    }

    /// Accepts only a bare origin: http(s) scheme, host, optional port, and
    /// nothing else (no path, query, fragment, or credentials).
    static func parse(_ raw: String) -> ParsedOrigin? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else { return nil }
        let host = RemoteNetwork.normalizedHost(rawHost)
        guard !host.isEmpty else { return nil }
        return ParsedOrigin(scheme: scheme, host: host, port: components.port)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `-only-testing AlasTests/RemoteOriginPolicyTests`. Expected: pass. If `parseNormalizesSchemeHostAndPort` fails on the IPv6 case because `URLComponents.host` keeps brackets on this OS, `RemoteNetwork.normalizedHost` already strips them, so check `hostHeader` re-adds exactly one pair.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Settings/RemoteNetwork.swift Alas/Sources/Remote/Server/RemoteOriginPolicy.swift AlasTests/Remote/RemoteOriginPolicyTests.swift
git commit -m "feat(remote): add a browser Origin policy for cross-origin hub access"
```

---
### Task 4: CORS and preflight on the pairing and health routes

**Files:**
- Modify: `Alas/Sources/Remote/Server/RemoteHTTPResponder.swift`
- Test: `AlasTests/Remote/RemoteHTTPResponderTests.swift` (new)

**Interfaces:**
- Consumes: `RemoteOriginPolicy.allows(originHeader:)` (Task 3).
- Produces: `RemoteHTTPResponder.originPolicy` (defaulted property, memberwise init label `originPolicy:` after `diagnostics:`), `RemoteHTTPResponder.http(status:contentType:body:extraHeaders:)`, `corsHeaders(for:) -> [(String, String)]`.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/Remote/RemoteHTTPResponderTests.swift`:

```swift
import Testing
import Foundation
@testable import Alas

@MainActor
struct RemoteHTTPResponderTests {
    private let privateOrigin = "http://192.168.1.20:8765"

    private func makeResponder(pairing: RemotePairingService = RemotePairingService(store: InMemoryDeviceStore())) -> RemoteHTTPResponder {
        RemoteHTTPResponder(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            diagnostics: {
                RemoteDiagnosticsSnapshot(appName: "Alas", port: 1, addresses: [], usesPlainHTTP: true, pairedDeviceCount: 0)
            },
            originPolicy: RemoteOriginPolicy(hostPolicy: .loopback, allowedOrigins: [])
        )
    }

    private func request(_ method: String, _ path: String, origin: String? = nil) -> HTTPRequest {
        var headers = ["host": "127.0.0.1"]
        if let origin { headers["origin"] = origin }
        return HTTPRequest(method: method, path: path, query: [:], headers: headers)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func healthCarriesCORSHeadersForAnAllowedOrigin() {
        let out = text(makeResponder().response(for: request("GET", "/health", origin: privateOrigin), body: Data()))
        #expect(out.hasPrefix("HTTP/1.1 200 OK"))
        #expect(out.contains("Access-Control-Allow-Origin: \(privateOrigin)\r\n"))
        #expect(out.contains("Vary: Origin\r\n"))
    }

    @Test func healthWithoutOriginHasNoCORSHeaders() {
        let out = text(makeResponder().response(for: request("GET", "/health"), body: Data()))
        #expect(out.hasPrefix("HTTP/1.1 200 OK"))
        #expect(!out.contains("Access-Control-Allow-Origin"))
    }

    // The connection layer rejects disallowed origins before the responder
    // runs; the responder must still never echo one back.
    @Test func healthWithDisallowedOriginNeverEchoesIt() {
        let out = text(makeResponder().response(for: request("GET", "/health", origin: "https://evil.example"), body: Data()))
        #expect(!out.contains("Access-Control-Allow-Origin"))
    }

    @Test func optionsPairPreflightAnswers204WithAllowances() {
        let out = text(makeResponder().response(for: request("OPTIONS", "/pair", origin: privateOrigin), body: Data()))
        #expect(out.hasPrefix("HTTP/1.1 204 No Content"))
        #expect(out.contains("Access-Control-Allow-Origin: \(privateOrigin)\r\n"))
        #expect(out.contains("Access-Control-Allow-Methods: POST, OPTIONS\r\n"))
        #expect(out.contains("Access-Control-Allow-Headers: content-type\r\n"))
        #expect(out.contains("Access-Control-Max-Age: 600\r\n"))
    }

    @Test func pairResponseCarriesCORSHeaders() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"phone"}"#.utf8)
        let out = text(makeResponder(pairing: pairing).response(for: request("POST", "/pair", origin: privateOrigin), body: body))
        #expect(out.hasPrefix("HTTP/1.1 200 OK"))
        #expect(out.contains("Access-Control-Allow-Origin: \(privateOrigin)\r\n"))
        #expect(out.contains(#""token":"#))
    }

    @Test func failedPairStillCarriesCORSHeaders() {
        let out = text(makeResponder().response(for: request("POST", "/pair", origin: privateOrigin), body: Data(#"{"code":"NOPE","deviceName":"x"}"#.utf8)))
        #expect(out.hasPrefix("HTTP/1.1 401 Unauthorized"))
        #expect(out.contains("Access-Control-Allow-Origin: \(privateOrigin)\r\n"))
    }

    @Test func extraHeadersLandInsideTheHeaderBlock() {
        let out = text(RemoteHTTPResponder.http(status: "200 OK", contentType: "text/plain", body: Data("x".utf8), extraHeaders: [("X-Test", "1")]))
        let headerBlock = out.components(separatedBy: "\r\n\r\n")[0]
        #expect(headerBlock.contains("X-Test: 1"))
        #expect(out.hasSuffix("\r\n\r\nx"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `-only-testing AlasTests/RemoteHTTPResponderTests`. Expected: compile error (`originPolicy`, `extraHeaders`).

- [ ] **Step 3: Implement**

Replace `struct RemoteHTTPResponder` (currently lines 12–71) with:

```swift
/// Builds HTTP/1.1 responses for non-WebSocket requests: the static web
/// client bundle, safe diagnostics routes, and the pairing endpoint. Pure
/// given its inputs. `/pair` and `/health` are reachable cross-origin from a
/// hub served by another Mac, so they carry CORS headers for origins the
/// `originPolicy` allows; everything else stays same-origin only.
@MainActor
struct RemoteHTTPResponder {
    let pairing: RemotePairingService
    let assets: RemoteWebAssets
    let diagnostics: () -> RemoteDiagnosticsSnapshot
    var originPolicy: RemoteOriginPolicy = .loopback

    func response(for req: HTTPRequest, body: Data) -> Data {
        let cors = corsHeaders(for: req)
        if req.method == "OPTIONS", req.path == "/pair" {
            return Self.http(
                status: "204 No Content", contentType: "text/plain", body: Data(),
                extraHeaders: cors + [
                    ("Access-Control-Allow-Methods", "POST, OPTIONS"),
                    ("Access-Control-Allow-Headers", "content-type"),
                    ("Access-Control-Max-Age", "600"),
                ])
        }
        if req.method == "GET", req.path == "/health" {
            return Self.json(["ok": true], extraHeaders: cors)
        }
        if req.method == "GET", req.path == "/remote-info" {
            let data = (try? JSONEncoder().encode(diagnostics())) ?? Data(#"{"error":"encode"}"#.utf8)
            return Self.http(status: "200 OK", contentType: "application/json; charset=utf-8", body: data)
        }
        if req.method == "POST", req.path == "/pair" {
            return pairResponse(body: body, extraHeaders: cors)
        }
        if req.method == "GET" {
            let path = req.path == "/" ? "/index.html" : req.path
            if let asset = assets.asset(forPath: path) {
                return Self.http(status: "200 OK", contentType: asset.contentType, body: asset.data)
            }
        }
        return Self.http(status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
    }

    /// `Access-Control-Allow-Origin` echoing the request's Origin when the
    /// policy allows it; empty for absent or disallowed origins.
    func corsHeaders(for req: HTTPRequest) -> [(String, String)] {
        guard let origin = req.headers["origin"], !origin.isEmpty,
              originPolicy.allows(originHeader: origin) else { return [] }
        return [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")]
    }

    private static func json(_ object: [String: Bool], extraHeaders: [(String, String)] = []) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data(#"{"ok":false}"#.utf8)
        return http(status: "200 OK", contentType: "application/json; charset=utf-8", body: data, extraHeaders: extraHeaders)
    }

    private func pairResponse(body: Data, extraHeaders: [(String, String)]) -> Data {
        struct PairRequest: Decodable { let code: String
        let deviceName: String }
        guard let pr = try? JSONDecoder().decode(PairRequest.self, from: body),
              let token = try? pairing.redeem(code: pr.code, deviceName: pr.deviceName) else {
            return Self.http(status: "401 Unauthorized", contentType: "application/json",
                             body: Data(#"{"error":"pairing failed"}"#.utf8), extraHeaders: extraHeaders)
        }
        return Self.http(status: "200 OK", contentType: "application/json",
                         body: Data(#"{"token":"\#(token)"}"#.utf8), extraHeaders: extraHeaders)
    }

    /// Pure response framing — `nonisolated` so the connection state machine can
    /// build error responses from its serial network queue without hopping to
    /// MainActor (it touches no actor state).
    nonisolated static func http(
        status: String,
        contentType: String,
        body: Data,
        extraHeaders: [(String, String)] = []
    ) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in extraHeaders {
            head += "\(name): \(value)\r\n"
        }
        // Never cache: the web bundle changes between builds and a stale cached
        // page can silently point at a dead server / hide an update.
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `-only-testing AlasTests/RemoteHTTPResponderTests`. Expected: pass. Also run `-only-testing AlasTests/RemoteServerIntegrationTests` to confirm nothing regressed (the responder's memberwise init still accepts the three-argument form).

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Server/RemoteHTTPResponder.swift AlasTests/Remote/RemoteHTTPResponderTests.swift
git commit -m "feat(remote): answer pairing and health cross-origin for allowed origins"
```

---

### Task 5: Origin gate and `hello` on the socket; server and AppState wiring

**Files:**
- Modify: `Alas/Sources/Remote/Server/RemoteConnection.swift:18-79, 154-176, 238-258`
- Modify: `Alas/Sources/Remote/Server/RemoteServer.swift:25-64, 145-194`
- Modify: `Alas/Sources/App/AppState.swift:508-524, 542-595`
- Test: `AlasTests/Remote/RemoteServerIntegrationTests.swift`

**Interfaces:**
- Consumes: `RemoteOriginPolicy`, `RemoteServerIdentity`, `RemoteServerMessage.hello(_:)`, `RemoteHTTPResponder.originPolicy`, `AppConfig.Remote.ensureServerId()`.
- Produces: `RemoteConnection.init(... accessPolicy:originPolicy:makeGateway:makeHello:...)`, `RemoteConnection.isOriginGated(path:isUpgrade:)`, `RemoteServer.init(... accessPolicy:originPolicy:diagnostics:identity:)`, `RemoteServer.updateOriginPolicy(_:)`, `AppState.remoteDisplayName`, `AppState.remoteServerIdentity()`.

- [ ] **Step 1: Write the failing tests**

In `RemoteServerIntegrationTests`, add a helper after `startServer`:

```swift
    private func receiveServerMessage(_ task: URLSessionWebSocketTask) async throws -> RemoteServerMessage {
        let received = try await task.receive()
        let payload: Data
        switch received {
        case .data(let d): payload = d
        case .string(let s): payload = Data(s.utf8)
        @unknown default: throw TimeoutError.timedOut
        }
        return try JSONDecoder().decode(RemoteServerMessage.self, from: payload)
    }
```

Add these tests:

```swift
    @Test func helloIsTheFirstFrameAfterUpgrade() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: FakeSessionsProvider(),
            identity: { RemoteServerIdentity(serverId: "srv-1", name: "Test Mac", hubEnabled: true) }
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
        #expect(first == .hello(protocolVersion: RemoteProtocolVersion.current, serverId: "srv-1", name: "Test Mac", hubEnabled: true))
        task.cancel(with: .goingAway, reason: nil)
    }

    @Test func webSocketWithPublicOriginIsRejectedBeforeTokenValidation() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "io.alas.tests.remote.ws-rejected-origin")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        let request = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1",
            "Origin: https://evil.example",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(token)"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        try await send(request, on: conn)
        let response = try await receiveHTTPResponse(from: conn, on: queue)
        let text = try #require(String(data: response, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.first?.lastSeenAt == nil)
        try await waitForConnectionClose(from: conn, on: queue)
    }

    @Test func webSocketWithPrivateOriginUpgrades() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "io.alas.tests.remote.ws-private-origin")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        let request = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1",
            "Origin: http://192.168.1.20:8765",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(token)"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        try await send(request, on: conn)
        let response = try await receiveHTTPResponse(from: conn, on: queue)
        let text = try #require(String(data: response, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 101 Switching Protocols"))
    }

    @Test func healthWithPrivateOriginCarriesCORSHeader() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "io.alas.tests.remote.health-cors")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        try await send("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://192.168.1.20:8765\r\n\r\n", on: conn)
        let response = try await receiveHTTPResponse(from: conn, on: queue)
        let text = try #require(String(data: response, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(text.contains("Access-Control-Allow-Origin: http://192.168.1.20:8765\r\n"))
    }
```

Update `pairThenWebSocketSubscribeReceivesSnapshot`: `hello` now precedes the snapshot. Replace the block from `// The server emits text frames` through `#expect(msgs.contains { $0.text == "hello-remote" })` with:

```swift
        // `hello` is always the first frame; the snapshot follows it.
        let first = try await receiveServerMessage(task)
        guard case .hello = first else {
            Issue.record("expected hello first, got \(first)")
            task.cancel(with: .goingAway, reason: nil)
            server.stop()
            return
        }
        let second = try await receiveServerMessage(task)
        guard case .transcriptSnapshot(_, _, _, let msgs, _, _, _, _) = second else {
            Issue.record("expected snapshot frame, got \(second)")
            task.cancel(with: .goingAway, reason: nil)
            server.stop()
            return
        }
        #expect(msgs.contains { $0.text == "hello-remote" })
```

- [ ] **Step 2: Run to verify it fails**

Run: `-only-testing AlasTests/RemoteServerIntegrationTests`. Expected: compile error (`identity:` label).

- [ ] **Step 3: RemoteConnection — origin gate and hello**

Add stored properties after `accessPolicy` (line 24):

```swift
    private let originPolicy: RemoteOriginPolicy
    private let makeHello: @MainActor () -> RemoteServerMessage?
```

Change the initializer signature and body:

```swift
    init(conn: NWConnection,
         queue: DispatchQueue,
         responder: @escaping @MainActor (HTTPRequest, Data) -> Data,
         authorize: @escaping @MainActor (String) -> String?,
         accessPolicy: RemoteAccessPolicy,
         originPolicy: RemoteOriginPolicy = .loopback,
         makeGateway: @escaping @MainActor (@escaping (RemoteServerMessage) -> Void) -> RemoteSessionGateway,
         makeHello: @escaping @MainActor () -> RemoteServerMessage? = { nil },
         onAuthenticated: ((RemoteConnection, String) -> Void)? = nil,
         onClose: @escaping (RemoteConnection) -> Void = { _ in }) {
        self.conn = conn
        self.queue = queue
        self.responder = responder
        self.authorize = authorize
        self.accessPolicy = accessPolicy
        self.originPolicy = originPolicy
        self.makeGateway = makeGateway
        self.makeHello = makeHello
        self.onAuthenticated = onAuthenticated
        self.onClose = onClose
    }
```

In `drain()`, replace lines 163–176 (from `let headerByteCount` through the upgrade `if` block) with:

```swift
        let headerByteCount = inbound.count - peek.count   // bytes through CRLFCRLF
        let isUpgrade = req.headers["upgrade"]?.lowercased() == "websocket"
        // Routes a hub served by another Mac reaches cross-origin carry a
        // browser Origin; reject disallowed ones before any handler runs.
        if Self.isOriginGated(path: req.path, isUpgrade: isUpgrade),
           !originPolicy.allows(originHeader: req.headers["origin"]) {
            sendAndClose(RemoteHTTPResponder.http(
                status: "403 Forbidden",
                contentType: "text/plain",
                body: Data("forbidden origin".utf8)
            ))
            return
        }
        if isUpgrade {
            inbound.removeFirst(headerByteCount)
            guard req.method == "GET", req.path == "/ws" else {
                sendAndClose(RemoteHTTPResponder.http(
                    status: "404 Not Found",
                    contentType: "text/plain",
                    body: Data("not found".utf8)
                ))
                return
            }
            handleUpgrade(req)
            return
        }
```

Add after `drain()`:

```swift
    /// Static assets and `/remote-info` stay Host-allowlist only; the socket,
    /// pairing, and health routes are what a cross-origin hub needs.
    static func isOriginGated(path: String, isUpgrade: Bool) -> Bool {
        isUpgrade || path == "/pair" || path == "/health"
    }
```

Replace the `Task { @MainActor ... }` block inside `completeUpgrade` (lines 249–257) with:

```swift
        Task { @MainActor [weak self] in
            guard let self else { return }
            let gateway = self.makeGateway { [weak self] msg in self?.sendServerMessage(msg) }
            let helloFrame = self.makeHello()
                .flatMap { try? JSONEncoder().encode($0) }
                .map { WebSocketFrame.encode(opcode: .text, payload: $0) }
            self.onQueue { [weak self] in
                guard let self else { return }
                self.gateway = gateway
                self.send(Data(head.utf8)) { [weak self] in
                    guard let self else { return }
                    // `hello` is the first frame on every socket: the gateway
                    // has not seen a client message yet, and its own sends hop
                    // through `onQueue` behind this one.
                    if let helloFrame {
                        self.send(helloFrame) { [weak self] in self?.drainFrames() }
                    } else {
                        self.drainFrames()
                    }
                }
            }
        }
```

- [ ] **Step 4: RemoteServer — policy and identity plumbing**

Add stored properties after `accessPolicy` (line 28):

```swift
    private var originPolicy: RemoteOriginPolicy
    private let identityProvider: @MainActor () -> RemoteServerIdentity
```

Change the initializer:

```swift
    init(
        pairing: RemotePairingService,
        assets: RemoteWebAssets,
        provider: RemoteSessionsProvider,
        accessPolicy: RemoteAccessPolicy = .loopback,
        originPolicy: RemoteOriginPolicy = .loopback,
        diagnostics: @escaping @MainActor (UInt16?) -> RemoteDiagnosticsSnapshot = { port in
            RemoteDiagnosticsSnapshot(
                appName: "Alas",
                port: port,
                addresses: [],
                usesPlainHTTP: true,
                pairedDeviceCount: 0
            )
        },
        identity: @escaping @MainActor () -> RemoteServerIdentity = {
            RemoteServerIdentity(serverId: "", name: "Alas", hubEnabled: false)
        }
    ) {
        self.pairing = pairing
        self.assets = assets
        self.provider = provider
        self.accessPolicy = accessPolicy
        self.originPolicy = originPolicy
        self.diagnosticsProvider = diagnostics
        self.identityProvider = identity
    }
```

Add after `updateAccessPolicy`:

```swift
    func updateOriginPolicy(_ policy: RemoteOriginPolicy) {
        originPolicy = policy
        for (oid, conn) in connections where connectionDevice[oid] == nil {
            conn.cancel()
        }
    }
```

In `accept`, build the responder with the policy and pass both new closures:

```swift
        let responder = RemoteHTTPResponder(
            pairing: pairing,
            assets: assets,
            diagnostics: { self.diagnosticsProvider(self.port) },
            originPolicy: originPolicy
        )
        let provider = self.provider   // captured strongly; the server owns it for its lifetime
        let identity = self.identityProvider
        let conn = RemoteConnection(
            conn: nwConn,
            queue: queue,
            responder: { req, body in responder.response(for: req, body: body) },
            authorize: { [weak self] token in
                guard let self, let id = self.pairing.validate(token: token) else { return nil }
                self.pairing.touch(deviceId: id)
                return id
            },
            accessPolicy: accessPolicy,
            originPolicy: originPolicy,
            makeGateway: { send in
                RemoteSessionGateway(provider: provider, send: send)
            },
            makeHello: { RemoteServerMessage.hello(identity()) },
            onAuthenticated: { [weak self] conn, did in
```

(keep the existing `onAuthenticated`/`onClose` bodies).

- [ ] **Step 5: AppState — origin policy, identity, server id**

After `makeRemoteAccessPolicy()` (line 518) add:

```swift
    private func makeRemoteOriginPolicy(interfaces: [RemoteNetworkInterface]) -> RemoteOriginPolicy {
        RemoteOriginPolicy(
            hostPolicy: makeRemoteAccessPolicy(interfaces: interfaces),
            allowedOrigins: config.remote.allowedOrigins
        )
    }

    private func makeRemoteOriginPolicy() -> RemoteOriginPolicy {
        makeRemoteOriginPolicy(interfaces: makeRemoteInterfaces())
    }

    /// Name advertised to remote clients: the configured display name, else
    /// the computer name.
    var remoteDisplayName: String {
        let configured = config.remote.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        return Host.current().localizedName ?? RemoteNetwork.machineHostName() ?? "Alas"
    }

    func remoteServerIdentity() -> RemoteServerIdentity {
        RemoteServerIdentity(
            serverId: config.remote.serverId,
            name: remoteDisplayName,
            hubEnabled: config.remote.hubEnabled
        )
    }
```

In `refreshRemoteAccessState()` add after the `updateAccessPolicy` line:

```swift
        remoteServer?.updateOriginPolicy(makeRemoteOriginPolicy(interfaces: interfaces))
```

In `syncRemoteServer()`, first line inside `if config.remote.enabled {`:

```swift
            if config.remote.ensureServerId() { saveConfig() }
```

In the `RemoteServer(` construction, add `originPolicy: makeRemoteOriginPolicy(),` after `accessPolicy: makeRemoteAccessPolicy(),`, extend the diagnostics snapshot with `serverId: self?.config.remote.serverId, name: self?.remoteDisplayName`, and add after the diagnostics closure:

```swift
                identity: { [weak self] in
                    self?.remoteServerIdentity() ?? RemoteServerIdentity(serverId: "", name: "Alas", hubEnabled: false)
                }
```

- [ ] **Step 6: Run to verify it passes**

Run: `-only-testing AlasTests/RemoteServerIntegrationTests` and `-only-testing AlasTests/RemoteAppStateAccessTests`. Expected: pass, including the four new tests and the updated snapshot test.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Remote/Server/RemoteConnection.swift Alas/Sources/Remote/Server/RemoteServer.swift Alas/Sources/App/AppState.swift AlasTests/Remote/RemoteServerIntegrationTests.swift
git commit -m "feat(remote): send hello on upgrade and gate cross-origin routes by Origin"
```

---

### Task 6: Pairing link builder, Server name field, Copy pairing link

**Files:**
- Create: `Alas/Sources/Remote/Pairing/RemotePairingLink.swift`
- Modify: `Alas/Sources/Remote/Settings/RemoteServerPane.swift:86-110, 229-232`
- Test: `AlasTests/Remote/RemotePairingLinkTests.swift` (new)

**Interfaces:**
- Consumes: `RemoteAdvertisedAddress.url`, `AppState.remoteDisplayName`, `AlasField`.
- Produces: `RemotePairingLink.build(base:code:addresses:) -> String`, `RemotePairingLink.encodeOrigin(_:)`.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/Remote/RemotePairingLinkTests.swift`:

```swift
import Testing
@testable import Alas

struct RemotePairingLinkTests {
    private func address(_ kind: RemoteAdvertisedAddress.Kind, _ host: String) -> RemoteAdvertisedAddress {
        RemoteAdvertisedAddress(kind: kind, interfaceName: nil, host: host, port: 8765, isRecommended: false)
    }

    @Test func linkKeepsTheBaseFirstAndListsEveryAddress() {
        let link = RemotePairingLink.build(
            base: "http://100.64.1.5:8765",
            code: "ABC123",
            addresses: [address(.lan, "192.168.1.20"), address(.tailnet, "100.64.1.5")]
        )
        #expect(link == "http://100.64.1.5:8765/?code=ABC123&hosts=http%3A%2F%2F100.64.1.5%3A8765,http%3A%2F%2F192.168.1.20%3A8765")
    }

    @Test func linkWithoutAddressesStillCarriesTheBase() {
        let link = RemotePairingLink.build(base: "http://localhost:8765", code: "X", addresses: [])
        #expect(link == "http://localhost:8765/?code=X&hosts=http%3A%2F%2Flocalhost%3A8765")
    }

    @Test func ipv6OriginsAreBracketedAndEncoded() {
        let link = RemotePairingLink.build(base: "http://[fd7a::1]:8765", code: "X", addresses: [])
        #expect(link.hasSuffix("&hosts=http%3A%2F%2F%5Bfd7a%3A%3A1%5D%3A8765"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `-only-testing AlasTests/RemotePairingLinkTests`. Expected: compile error.

- [ ] **Step 3: Create the builder**

```swift
import Foundation

/// The string encoded in the pairing QR and copied by "Copy pairing link":
///
///     http://<preferred-host>:<port>/?code=<CODE>&hosts=<origin1>,<origin2>,…
///
/// A fresh phone scanning it lands on `base` and pairs as before; a hub
/// pastes it and tries every origin in `hosts` in order, preferred first.
enum RemotePairingLink {
    static func build(base: String, code: String, addresses: [RemoteAdvertisedAddress]) -> String {
        var origins = [base]
        for address in addresses where !origins.contains(address.url) {
            origins.append(address.url)
        }
        let hosts = origins.map(encodeOrigin).joined(separator: ",")
        return "\(base)/?code=\(code)&hosts=\(hosts)"
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything outside RFC 3986 unreserved characters, so
    /// the comma separating origins is never ambiguous.
    static func encodeOrigin(_ origin: String) -> String {
        origin.addingPercentEncoding(withAllowedCharacters: unreserved) ?? origin
    }
}
```

- [ ] **Step 4: Update the Remote pane**

Replace the "Pair a device" row and QR block (lines 94–110) with:

```swift
                        SettingsRow(
                            name: "Server name",
                            desc: "Shown on paired devices. Leave empty to use this Mac's name."
                        ) {
                            AlasField(
                                text: Binding(
                                    get: { state.config.remote.displayName },
                                    set: { value in
                                        state.config.remote.displayName = value
                                        state.saveConfig()
                                    }
                                ),
                                placeholder: state.remoteDisplayName
                            )
                        }
                        SettingsRow(name: "Pair a device", desc: "Show a QR code to pair a new phone or tablet.") {
                            AlasButton(
                                title: pairingCode == nil ? "Show pairing QR" : "New code",
                                style: .subtle
                            ) {
                                pairingCode = state.remotePairing.beginPairing()
                            }
                        }
                        if let code = pairingCode {
                            let link = pairingLink(code: code, port: port)
                            QRView(text: link)
                                .frame(width: 180, height: 180)
                                .padding(.top, 8)
                            AlasButton(title: "Copy pairing link", style: .subtle) {
                                copyAddress(link)
                            }
                            .padding(.top, 6)
                            Text("Refreshes automatically — scan it, or paste the copied link into Alas remote on another device to add this Mac.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.color("fg-dim"))
                                .padding(.bottom, 8)
                        }
```

Add after `pairingURL(port:)`:

```swift
    private func pairingLink(code: String, port: UInt16) -> String {
        RemotePairingLink.build(
            base: pairingURL(port: port),
            code: code,
            addresses: state.remoteAdvertisedAddresses
        )
    }
```

- [ ] **Step 5: Run to verify it passes and the app builds**

Run: `-only-testing AlasTests/RemotePairingLinkTests`. Expected: pass. Then the build command from CLAUDE.md with the arm64 env vars to confirm the pane compiles.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Pairing/RemotePairingLink.swift Alas/Sources/Remote/Settings/RemoteServerPane.swift AlasTests/Remote/RemotePairingLinkTests.swift
git commit -m "feat(remote): encode every advertised address in the pairing link and add a copy button"
```

---
### Task 7: `hub-registry.js` — persisted registry, link parsing, counts

**Files:**
- Create: `Alas/Resources/RemoteWeb/hub-registry.js`
- Create: `scripts/tests/remote-web-hub/run.sh`, `scripts/tests/remote-web-hub/test-hub-registry.js`
- Modify: `.github/workflows/build.yml:736-738` (add a step)

**Interfaces:**
- Produces `globalThis.RemoteHubRegistry` with: `HUB_STORAGE_KEY`, `LEGACY_TOKEN_KEY`, `normalizeOrigin(input)`, `parsePairingLink(text)`, `parseManualPairing(address, code)`, `load(storage, pageOrigin, pageHostname, now)`, `save(storage, doc)`, `upsertPaired(doc, {origins, token, now})`, `applyHello(doc, clientId, hello)`, `forgetServer(doc, id)`, `setActive(doc, id)`, `setLastOrigin(doc, id, origin)`, `fallbackActiveId(doc, onlineIds)`, `attentionCounts(sessions)`, `otherAttentionTotal(links, activeId)`.
- Document shape: `{ version: 1, activeId, servers: [{ id, serverId, name, origins, lastOrigin, token, protocolVersion, hubEnabled, addedAt }] }`.

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/remote-web-hub/run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
node "$(dirname "$0")/test-hub-registry.js"
node "$(dirname "$0")/test-hub-links.js"
```

Run `chmod +x scripts/tests/remote-web-hub/run.sh`. Until Task 8 exists, run the registry file directly.

Create `scripts/tests/remote-web-hub/test-hub-registry.js`:

```js
const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/hub-registry.js");

const registry = globalThis.RemoteHubRegistry;

function fakeStorage(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    getItem: (key) => (map.has(key) ? map.get(key) : null),
    setItem: (key, value) => map.set(key, String(value)),
    removeItem: (key) => map.delete(key),
    dump: () => Object.fromEntries(map),
  };
}

// --- normalizeOrigin ---------------------------------------------------------

assert.equal(registry.normalizeOrigin("100.64.1.5:8765"), "http://100.64.1.5:8765");
assert.equal(registry.normalizeOrigin("http://100.64.1.5:8765"), "http://100.64.1.5:8765");
assert.equal(registry.normalizeOrigin("HTTP://Nacho-MBP.local:8765/"), "http://nacho-mbp.local:8765");
assert.equal(registry.normalizeOrigin("[::1]:8765"), "http://[::1]:8765");
assert.equal(registry.normalizeOrigin("nacho-mbp.local"), "http://nacho-mbp.local:8765", "no port → Alas default port");
assert.equal(registry.normalizeOrigin("https://app.alas.build"), "https://app.alas.build", "https keeps its default port");
assert.equal(registry.normalizeOrigin("ftp://x:1"), null);
assert.equal(registry.normalizeOrigin("http://user:pw@host:1"), null);
assert.equal(registry.normalizeOrigin(""), null);
assert.equal(registry.normalizeOrigin("not a url at all"), null);

// --- parsePairingLink --------------------------------------------------------

const full = registry.parsePairingLink(
  "http://100.64.1.5:8765/?code=ABC123&hosts=http%3A%2F%2F100.64.1.5%3A8765,http%3A%2F%2F192.168.1.20%3A8765"
);
assert.deepEqual(full, { origins: ["http://100.64.1.5:8765", "http://192.168.1.20:8765"], code: "ABC123" });

const legacy = registry.parsePairingLink("http://192.168.1.20:8765/?code=XYZ");
assert.deepEqual(legacy, { origins: ["http://192.168.1.20:8765"], code: "XYZ" }, "legacy link → its own origin");

const lastFallback = registry.parsePairingLink("http://192.168.1.20:8765/?code=Q&hosts=http%3A%2F%2F10.0.0.2%3A8765");
assert.deepEqual(lastFallback.origins, ["http://10.0.0.2:8765", "http://192.168.1.20:8765"], "link origin is the last fallback");

assert.equal(registry.parsePairingLink("http://192.168.1.20:8765/"), null, "no code → not a pairing link");
assert.equal(registry.parsePairingLink("garbage"), null);
assert.equal(registry.parsePairingLink(""), null);

assert.deepEqual(registry.parseManualPairing("192.168.1.20", " ABC "), { origins: ["http://192.168.1.20:8765"], code: "ABC" });
assert.equal(registry.parseManualPairing("192.168.1.20", ""), null);
assert.equal(registry.parseManualPairing("", "ABC"), null);

// --- load / migrate ----------------------------------------------------------

{
  const storage = fakeStorage({ "alas.remote.token": "legacy-token" });
  const doc = registry.load(storage, "http://192.168.1.20:8765", "192.168.1.20", 1000);
  assert.equal(doc.version, 1);
  assert.equal(doc.servers.length, 1);
  const [server] = doc.servers;
  assert.equal(server.token, "legacy-token");
  assert.deepEqual(server.origins, ["http://192.168.1.20:8765"]);
  assert.equal(server.lastOrigin, "http://192.168.1.20:8765");
  assert.equal(server.name, "192.168.1.20");
  assert.equal(server.serverId, null);
  assert.equal(server.addedAt, 1000);
  assert.equal(doc.activeId, server.id);
  assert.equal(storage.getItem("alas.remote.token"), null, "legacy key removed");
  assert.ok(storage.getItem("alas.remote.hub"), "migrated document persisted");
}

{
  const storage = fakeStorage();
  const doc = registry.load(storage, "http://192.168.1.20:8765", "192.168.1.20", 1);
  assert.deepEqual(doc, { version: 1, activeId: null, servers: [] });
  assert.equal(storage.getItem("alas.remote.hub"), null, "nothing persisted for an empty hub");
}

{
  const storage = fakeStorage({ "alas.remote.hub": "{not json" });
  const doc = registry.load(storage, "http://a:1", "a", 1);
  assert.deepEqual(doc.servers, []);
}

{
  const storage = fakeStorage({
    "alas.remote.hub": JSON.stringify({
      version: 1,
      activeId: "gone",
      servers: [
        { id: "c-1", token: "t", origins: ["10.0.0.1:8765", "http://10.0.0.1:8765"], lastOrigin: "nope" },
        { id: "c-bad", origins: [] },
      ],
    }),
  });
  const doc = registry.load(storage, "http://a:1", "a", 1);
  assert.equal(doc.servers.length, 1, "entries without a token or origins are dropped");
  assert.deepEqual(doc.servers[0].origins, ["http://10.0.0.1:8765"], "origins normalized and deduped");
  assert.equal(doc.servers[0].lastOrigin, "http://10.0.0.1:8765", "unknown lastOrigin falls back to the first origin");
  assert.equal(doc.activeId, "c-1", "dangling activeId falls back to the first server");
}

// --- upsertPaired ------------------------------------------------------------

{
  const doc = { version: 1, activeId: null, servers: [] };
  const first = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765", "http://100.64.0.1:8765"], token: "t1", now: 5 });
  assert.equal(first.rePaired, false);
  assert.equal(doc.servers.length, 1);
  assert.equal(doc.activeId, first.server.id, "first server becomes active");
  assert.equal(first.server.lastOrigin, "http://10.0.0.1:8765");

  const again = registry.upsertPaired(doc, { origins: ["http://100.64.0.1:8765", "http://172.16.0.9:8765"], token: "t2", now: 6 });
  assert.equal(again.rePaired, true, "overlapping origin → re-pair in place");
  assert.equal(again.server.id, first.server.id);
  assert.equal(again.server.token, "t2");
  assert.deepEqual(again.server.origins, ["http://100.64.0.1:8765", "http://172.16.0.9:8765", "http://10.0.0.1:8765"]);
  assert.equal(again.server.lastOrigin, "http://100.64.0.1:8765");

  const other = registry.upsertPaired(doc, { origins: ["http://10.0.0.2:8765"], token: "t3", now: 7 });
  assert.equal(other.rePaired, false);
  assert.equal(doc.servers.length, 2);
  assert.equal(doc.activeId, first.server.id, "active server is not changed by adding another");
}

// --- applyHello --------------------------------------------------------------

{
  const doc = { version: 1, activeId: null, servers: [] };
  const { server } = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "t1", now: 1 });
  const result = registry.applyHello(doc, server.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio", hubEnabled: true });
  assert.equal(result.mergedFromId, null);
  assert.equal(server.serverId, "srv-A");
  assert.equal(server.name, "Studio");
  assert.equal(server.protocolVersion, 1);
  assert.equal(server.hubEnabled, true);

  const blankName = registry.applyHello(doc, server.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "  " });
  assert.equal(blankName.server.name, "Studio", "blank hello name keeps the previous name");
  assert.equal(blankName.server.hubEnabled, false, "missing hubEnabled means off");

  assert.equal(registry.applyHello(doc, "nope", { type: "hello", serverId: "x", name: "y" }), null);
}

{
  // The same Mac paired twice (e.g. once by LAN address, once by tailnet):
  // the hello's serverId reveals the twin; the older entry survives.
  const doc = { version: 1, activeId: null, servers: [] };
  const older = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "old", now: 1 }).server;
  registry.applyHello(doc, older.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio" });
  const newer = registry.upsertPaired(doc, { origins: ["http://100.64.0.1:8765"], token: "new", now: 2 }).server;
  registry.setActive(doc, newer.id);
  const result = registry.applyHello(doc, newer.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio" });
  assert.equal(result.mergedFromId, newer.id);
  assert.equal(result.server.id, older.id);
  assert.equal(doc.servers.length, 1);
  assert.equal(result.server.token, "new", "merged entry takes the fresh token");
  assert.deepEqual(result.server.origins, ["http://100.64.0.1:8765", "http://10.0.0.1:8765"]);
  assert.equal(result.server.lastOrigin, "http://100.64.0.1:8765");
  assert.equal(doc.activeId, older.id, "active id follows the surviving entry");
}

// --- forget / active / lastOrigin -------------------------------------------

{
  const doc = { version: 1, activeId: null, servers: [] };
  const a = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "a", now: 1 }).server;
  const b = registry.upsertPaired(doc, { origins: ["http://10.0.0.2:8765"], token: "b", now: 2 }).server;
  registry.setActive(doc, b.id);
  assert.equal(doc.activeId, b.id);
  registry.setActive(doc, "missing");
  assert.equal(doc.activeId, b.id, "unknown id is ignored");

  registry.setLastOrigin(doc, a.id, "http://10.0.0.1:8765");
  assert.equal(a.lastOrigin, "http://10.0.0.1:8765");
  registry.setLastOrigin(doc, a.id, "http://not-listed:1");
  assert.equal(a.lastOrigin, "http://10.0.0.1:8765", "lastOrigin must be one of the server's origins");

  registry.forgetServer(doc, b.id);
  assert.equal(doc.servers.length, 1);
  assert.equal(doc.activeId, null, "forgetting the active server clears activeId");
  assert.equal(registry.fallbackActiveId(doc, []), a.id, "no online servers → first remaining");
  registry.forgetServer(doc, a.id);
  assert.equal(registry.fallbackActiveId(doc, []), null);
}

{
  const doc = { version: 1, activeId: null, servers: [] };
  const a = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "a", now: 1 }).server;
  const b = registry.upsertPaired(doc, { origins: ["http://10.0.0.2:8765"], token: "b", now: 2 }).server;
  assert.equal(registry.fallbackActiveId(doc, [b.id]), b.id, "first ONLINE server wins");
  assert.equal(registry.fallbackActiveId(doc, [a.id, b.id]), a.id, "ties break in registry order");
}

// --- counts ------------------------------------------------------------------

assert.deepEqual(
  registry.attentionCounts([
    { id: "1", status: "awaitingPermission" },
    { id: "2", status: "awaitingInput" },
    { id: "3", status: "streaming" },
    { id: "4", status: "idle" },
    { id: "5", status: "awaitingPermission", isActive: false },
    null,
  ]),
  { attention: 2, running: 1 }
);
assert.deepEqual(registry.attentionCounts(undefined), { attention: 0, running: 0 });
assert.equal(
  registry.otherAttentionTotal(
    [{ id: "a", counts: { attention: 2, running: 0 } }, { id: "b", counts: { attention: 3, running: 1 } }, { id: "c", counts: { attention: 1, running: 0 } }],
    "b"
  ),
  3,
  "sums attention across every server but the active one"
);

console.log("hub-registry tests passed");
```

- [ ] **Step 2: Run to verify it fails**

Run: `node scripts/tests/remote-web-hub/test-hub-registry.js`
Expected: `Cannot find module '.../hub-registry.js'`.

- [ ] **Step 3: Create the module**

Create `Alas/Resources/RemoteWeb/hub-registry.js`:

```js
// Pure state for the multi-server hub: the persisted server registry,
// pairing-link parsing, and aggregation over session lists. No DOM access,
// no timers, no sockets — those live in hub-links.js and app.js. Mirrors the
// shape of repo-filter.js / session-ordering.js so node can load it directly.

const HUB_STORAGE_KEY = "alas.remote.hub";
const LEGACY_TOKEN_KEY = "alas.remote.token";
const HUB_SCHEMA_VERSION = 1;
const DEFAULT_PORT = "8765";
const ATTENTION_STATUSES = new Set(["awaitingPermission", "awaitingInput"]);

function safeParse(text) {
  try { return JSON.parse(text); } catch (_) { return null; }
}

function newClientId() {
  return "c-" + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}

function stripScheme(text) {
  return text.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "");
}

// `new URL` drops default ports, so "did the user name a port" is decided on
// the raw text: `host:8765`, `[::1]:8765`, `http://host:80` all count.
function hasExplicitPort(text) {
  const authority = stripScheme(text).split(/[/?#]/)[0];
  const afterHost = authority.startsWith("[") ? authority.slice(authority.indexOf("]") + 1) : authority;
  return /:\d+$/.test(afterHost);
}

// "100.64.1.5:8765", "http://100.64.1.5:8765", "[::1]:8765", "nacho.local"
// → "http://100.64.1.5:8765". A missing scheme means http; a missing port on
// http means Alas's default port. Null for anything that is not an http(s)
// origin.
function normalizeOrigin(input) {
  const text = String(input || "").trim();
  if (!text) return null;
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(text) ? text : "http://" + text;
  let url;
  try { url = new URL(withScheme); } catch (_) { return null; }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (!url.hostname || url.username || url.password) return null;
  if (!url.port && url.protocol === "http:" && !hasExplicitPort(withScheme)) url.port = DEFAULT_PORT;
  return url.origin;
}

function uniqueOrigins(origins) {
  const out = [];
  for (const origin of origins || []) {
    const normalized = normalizeOrigin(origin);
    if (normalized && !out.includes(normalized)) out.push(normalized);
  }
  return out;
}

// The string encoded in the QR / Copy button:
//   http://<host>:<port>/?code=<CODE>&hosts=<origin>,<origin>,…
// or a legacy link without `hosts`. Returns { origins, code } with the
// `hosts` order preserved (preferred first) and the link's own origin as the
// last fallback, or null when the text is not a pairing link.
function parsePairingLink(text) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return null;
  let url;
  try { url = new URL(trimmed); } catch (_) { return null; }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  const code = (url.searchParams.get("code") || "").trim();
  if (!code) return null;
  const candidates = [];
  const hosts = url.searchParams.get("hosts");
  if (hosts) candidates.push(...hosts.split(","));
  candidates.push(url.origin);
  const origins = uniqueOrigins(candidates);
  return origins.length ? { origins, code } : null;
}

function parseManualPairing(address, code) {
  const origin = normalizeOrigin(address);
  const trimmedCode = String(code || "").trim();
  if (!origin || !trimmedCode) return null;
  return { origins: [origin], code: trimmedCode };
}

function emptyDocument() {
  return { version: HUB_SCHEMA_VERSION, activeId: null, servers: [] };
}

function makeServer({ origins, token, name, now }) {
  const normalized = uniqueOrigins(origins);
  return {
    id: newClientId(),
    serverId: null,
    name: name || normalized[0],
    origins: normalized,
    lastOrigin: normalized[0],
    token,
    protocolVersion: null,
    hubEnabled: false,
    addedAt: now,
  };
}

// Drops entries that cannot connect (no token, no usable origin), normalizes
// origins, and repairs a dangling activeId.
function normalizeDocument(doc) {
  const servers = (doc.servers || [])
    .filter((s) => s && typeof s.id === "string" && typeof s.token === "string" && Array.isArray(s.origins))
    .map((s) => {
      const origins = uniqueOrigins(s.origins);
      const lastOrigin = normalizeOrigin(s.lastOrigin);
      return {
        ...s,
        origins,
        lastOrigin: lastOrigin && origins.includes(lastOrigin) ? lastOrigin : origins[0],
        hubEnabled: s.hubEnabled === true,
      };
    })
    .filter((s) => s.origins.length > 0);
  const activeId = servers.some((s) => s.id === doc.activeId) ? doc.activeId : (servers[0] ? servers[0].id : null);
  return { version: HUB_SCHEMA_VERSION, activeId, servers };
}

// `storage` is anything with localStorage's getItem/setItem/removeItem. A
// pre-hub client stored one token for the page's own origin; fold it into a
// single server entry once and drop the old key.
function load(storage, pageOrigin, pageHostname, now) {
  const parsed = safeParse(storage.getItem(HUB_STORAGE_KEY) || "");
  if (parsed && parsed.version === HUB_SCHEMA_VERSION && Array.isArray(parsed.servers)) {
    return normalizeDocument(parsed);
  }
  const doc = emptyDocument();
  const legacyToken = storage.getItem(LEGACY_TOKEN_KEY);
  if (legacyToken) {
    const server = makeServer({ origins: [pageOrigin], token: legacyToken, name: pageHostname, now });
    doc.servers.push(server);
    doc.activeId = server.id;
    storage.removeItem(LEGACY_TOKEN_KEY);
    save(storage, doc);
  }
  return doc;
}

function save(storage, doc) {
  storage.setItem(HUB_STORAGE_KEY, JSON.stringify(doc));
}

// Records a successful pairing. A server that already shares any of the
// origins is re-paired in place (new token, merged origin list, new origins
// first); otherwise a new entry is appended and becomes active when nothing
// was.
function upsertPaired(doc, { origins, token, now }) {
  const normalized = uniqueOrigins(origins);
  const existing = doc.servers.find((s) => s.origins.some((o) => normalized.includes(o)));
  if (existing) {
    existing.token = token;
    existing.origins = uniqueOrigins([...normalized, ...existing.origins]);
    existing.lastOrigin = normalized[0];
    return { server: existing, rePaired: true };
  }
  const server = makeServer({ origins: normalized, token, now });
  doc.servers.push(server);
  if (!doc.activeId) doc.activeId = server.id;
  return { server, rePaired: false };
}

// Applies a `hello` to the entry that received it. When another entry already
// carries the same serverId (the same Mac paired twice under different
// addresses) the OLDER entry survives with the fresh token and the union of
// origins; the caller drops the link for `mergedFromId`.
function applyHello(doc, clientId, hello) {
  const server = doc.servers.find((s) => s.id === clientId);
  if (!server) return null;
  const serverId = typeof hello.serverId === "string" && hello.serverId ? hello.serverId : null;
  const helloName = typeof hello.name === "string" ? hello.name.trim() : "";
  const name = helloName || server.name;
  const protocolVersion = Number.isInteger(hello.protocolVersion) ? hello.protocolVersion : null;
  const hubEnabled = hello.hubEnabled === true;
  const twin = serverId ? doc.servers.find((s) => s.id !== clientId && s.serverId === serverId) : null;
  if (twin) {
    twin.token = server.token;
    twin.origins = uniqueOrigins([...server.origins, ...twin.origins]);
    twin.lastOrigin = server.lastOrigin;
    twin.name = name;
    twin.protocolVersion = protocolVersion;
    twin.hubEnabled = hubEnabled;
    doc.servers = doc.servers.filter((s) => s.id !== clientId);
    if (doc.activeId === clientId) doc.activeId = twin.id;
    return { server: twin, mergedFromId: clientId };
  }
  server.serverId = serverId;
  server.name = name;
  server.protocolVersion = protocolVersion;
  server.hubEnabled = hubEnabled;
  return { server, mergedFromId: null };
}

function forgetServer(doc, id) {
  doc.servers = doc.servers.filter((s) => s.id !== id);
  if (doc.activeId === id) doc.activeId = null;
}

function setActive(doc, id) {
  if (doc.servers.some((s) => s.id === id)) doc.activeId = id;
}

function setLastOrigin(doc, id, origin) {
  const server = doc.servers.find((s) => s.id === id);
  const normalized = normalizeOrigin(origin);
  if (server && normalized && server.origins.includes(normalized)) server.lastOrigin = normalized;
}

// Launch/forget fallback: the first server (registry order) that is online,
// else the first server at all, else null.
function fallbackActiveId(doc, onlineIds) {
  const online = doc.servers.find((s) => onlineIds.includes(s.id));
  if (online) return online.id;
  return doc.servers[0] ? doc.servers[0].id : null;
}

// Derived from a `sessionList` payload. Closed sessions never need attention.
function attentionCounts(sessions) {
  const counts = { attention: 0, running: 0 };
  for (const session of sessions || []) {
    if (!session || session.isActive === false) continue;
    if (ATTENTION_STATUSES.has(session.status)) counts.attention += 1;
    else if (session.status === "streaming") counts.running += 1;
  }
  return counts;
}

// Badge on the Settings tab: attention across every server except the one
// being viewed. `links` is any array of { id, counts }.
function otherAttentionTotal(links, activeId) {
  let total = 0;
  for (const link of links || []) {
    if (link.id !== activeId) total += (link.counts && link.counts.attention) || 0;
  }
  return total;
}

globalThis.RemoteHubRegistry = {
  HUB_STORAGE_KEY,
  LEGACY_TOKEN_KEY,
  normalizeOrigin,
  parsePairingLink,
  parseManualPairing,
  load,
  save,
  upsertPaired,
  applyHello,
  forgetServer,
  setActive,
  setLastOrigin,
  fallbackActiveId,
  attentionCounts,
  otherAttentionTotal,
};
```

- [ ] **Step 4: Run to verify it passes**

Run: `node scripts/tests/remote-web-hub/test-hub-registry.js`
Expected: `hub-registry tests passed`.

- [ ] **Step 5: Wire CI**

In `.github/workflows/build.yml`, after the "Test remote web worktree creation" step (line 738), add:

```yaml
      - name: Test remote web hub
        if: ${{ !cancelled() }}
        run: bash scripts/tests/remote-web-hub/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add Alas/Resources/RemoteWeb/hub-registry.js scripts/tests/remote-web-hub .github/workflows/build.yml
git commit -m "feat(remote-web): add the hub server registry module"
```

---

### Task 8: `hub-links.js` — one socket per server, origin fallback, probing, pairing

**Files:**
- Create: `Alas/Resources/RemoteWeb/hub-links.js`
- Create: `scripts/tests/remote-web-hub/test-hub-links.js`

**Interfaces:**
- Consumes: `globalThis.RemoteHubRegistry.attentionCounts` (Task 7).
- Produces `globalThis.RemoteHubLinks = { createLinks, wsUrl, HANDSHAKE_TIMEOUT_MS, PAIR_TIMEOUT_MS, IDLE_POLL_MS, INITIAL_RECONNECT_MS, MAX_RECONNECT_MS }`.
- `createLinks(deps, hooks)` returns `{ add(server), remove(id), update(server), get(id), all(), activeLink(), setActive(id), sendActive(obj), connect(id), connectAll(), suspendIdle(), setVisible(bool), retry(id), pair(origins, code, deviceName) }`.
- `deps = { createSocket(url, protocols), fetch(url, init), setTimeout(fn, ms), clearTimeout(id) }`.
- `hooks = { onStateChange(link), onHello(link, hello), onLegacy(link), onMessage(link, msg), onCounts(link) }` (all optional).
- Link fields read by app.js: `id, role ("active"|"idle"), state, counts {attention, running}, legacy, lastOrigin, socket`.
- `pair` rejects with an `Error` whose `reason` is `"expired"`, `"origin"`, or `"net"`; resolves `{ origin, token }`.

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/remote-web-hub/test-hub-links.js`:

```js
const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/hub-registry.js");
require("../../../Alas/Resources/RemoteWeb/hub-links.js");

const { createLinks, HANDSHAKE_TIMEOUT_MS, IDLE_POLL_MS, INITIAL_RECONNECT_MS, MAX_RECONNECT_MS } = globalThis.RemoteHubLinks;

function makeClock() {
  let now = 0;
  let seq = 0;
  const timers = new Map();
  return {
    setTimeout(fn, ms) { const id = ++seq; timers.set(id, { at: now + ms, fn }); return id; },
    clearTimeout(id) { timers.delete(id); },
    pending() { return timers.size; },
    async tick(ms) {
      const target = now + ms;
      for (;;) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        now = due[1].at;
        timers.delete(due[0]);
        due[1].fn();
        await settle();
      }
      now = target;
    },
  };
}

// Let promise chains (probes, pairing) run to completion.
async function settle() { for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r)); }

class FakeSocket {
  constructor(url, protocols) { this.url = url; this.protocols = protocols; this.readyState = 0; this.sent = []; this.closed = false; }
  send(text) { this.sent.push(JSON.parse(text)); }
  close() { this.closed = true; this.readyState = 3; }
  open() { this.readyState = 1; if (this.onopen) this.onopen(); }
  message(obj) { if (this.onmessage) this.onmessage({ data: JSON.stringify(obj) }); }
  drop() { this.readyState = 3; if (this.onclose) this.onclose(); }
}

function harness({ fetchImpl } = {}) {
  const clock = makeClock();
  const sockets = [];
  const events = [];
  const links = createLinks(
    {
      createSocket: (url, protocols) => { const s = new FakeSocket(url, protocols); sockets.push(s); return s; },
      fetch: fetchImpl || (() => Promise.reject(new Error("unreachable"))),
      setTimeout: clock.setTimeout,
      clearTimeout: clock.clearTimeout,
    },
    {
      onStateChange: (l) => events.push([l.id, l.state, l.role]),
      onHello: (l, hello) => events.push([l.id, "hello", hello.serverId]),
      onLegacy: (l) => events.push([l.id, "legacy"]),
      onMessage: (l, m) => events.push([l.id, "msg", m.type]),
      onCounts: (l) => events.push([l.id, "counts", l.counts.attention, l.counts.running]),
    }
  );
  return { clock, sockets, events, links };
}

const serverA = { id: "a", origins: ["http://10.0.0.1:8765", "http://100.64.0.1:8765"], lastOrigin: "http://100.64.0.1:8765", token: "tok-a" };
const serverB = { id: "b", origins: ["http://10.0.0.2:8765"], lastOrigin: "http://10.0.0.2:8765", token: "tok-b" };

(async () => {
  // --- origin order and fallback --------------------------------------------
  {
    const { clock, sockets, links } = harness();
    links.add(serverA);
    links.setActive("a");
    links.connect("a");
    assert.equal(sockets.length, 1);
    assert.equal(sockets[0].url, "ws://100.64.0.1:8765/ws", "lastOrigin is tried first");
    assert.deepEqual(sockets[0].protocols, ["tok-a"], "token rides as the subprotocol");
    assert.equal(links.get("a").state, "connecting");

    await clock.tick(HANDSHAKE_TIMEOUT_MS);
    assert.equal(sockets[0].closed, true, "handshake timeout abandons the socket");
    assert.equal(sockets.length, 2);
    assert.equal(sockets[1].url, "ws://10.0.0.1:8765/ws", "next origin in order");

    sockets[1].open();
    assert.equal(links.get("a").state, "online");
    assert.equal(links.get("a").lastOrigin, "http://10.0.0.1:8765", "the origin that answered is promoted");
  }

  // --- hello / legacy / active message routing ------------------------------
  {
    const { sockets, events, links } = harness();
    links.add(serverA);
    links.setActive("a");
    links.connect("a");
    sockets[0].open();
    sockets[0].message({ type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio" });
    assert.ok(events.some((e) => e[0] === "a" && e[1] === "hello" && e[2] === "srv-A"));
    assert.equal(links.get("a").legacy, false);
    sockets[0].message({ type: "sessionList", sessions: [{ id: "s", status: "awaitingInput" }] });
    assert.ok(events.some((e) => e[1] === "counts" && e[2] === 1), "active link still derives counts");
    assert.ok(events.some((e) => e[1] === "msg" && e[2] === "sessionList"), "active link forwards sessionList to the app");
    sockets[0].message({ type: "transcriptDelta" });
    assert.ok(events.some((e) => e[1] === "msg" && e[2] === "transcriptDelta"));
  }
  {
    const { sockets, events, links } = harness();
    links.add(serverA);
    links.setActive("a");
    links.connect("a");
    sockets[0].open();
    sockets[0].message({ type: "sessionList", sessions: [] });
    assert.equal(links.get("a").legacy, true, "a first frame that is not hello marks the server legacy");
    assert.ok(events.some((e) => e[1] === "legacy"));
    assert.ok(events.some((e) => e[1] === "msg" && e[2] === "sessionList"), "the legacy first frame is still delivered");
  }

  // --- idle polling and counts ----------------------------------------------
  {
    const { clock, sockets, events, links } = harness();
    links.add(serverA);
    links.add(serverB);
    links.setActive("a");
    links.connect("b");
    sockets[0].open();
    assert.deepEqual(sockets[0].sent, [{ type: "listSessions" }], "idle link asks for the list on open");
    sockets[0].message({ type: "hello", protocolVersion: 1, serverId: "srv-B", name: "Laptop" });
    sockets[0].message({ type: "sessionList", sessions: [{ id: "1", status: "awaitingPermission" }, { id: "2", status: "streaming" }] });
    assert.deepEqual(links.get("b").counts, { attention: 1, running: 1 });
    assert.ok(!events.some((e) => e[0] === "b" && e[1] === "msg"), "idle links never forward messages to the app");
    await clock.tick(IDLE_POLL_MS);
    assert.equal(sockets[0].sent.length, 2, "polls again after IDLE_POLL_MS");
    sockets[0].message({ type: "sessionList", sessions: [{ id: "1", status: "awaitingPermission" }, { id: "2", status: "streaming" }] });
    assert.equal(events.filter((e) => e[0] === "b" && e[1] === "counts").length, 1, "unchanged counts do not re-notify");
  }

  // --- unauthorized vs offline ----------------------------------------------
  {
    const { clock, sockets, links } = harness({ fetchImpl: () => Promise.resolve({ ok: true, status: 200 }) });
    links.add(serverB);
    links.setActive("b");
    links.connect("b");
    sockets[0].drop();
    await settle();
    assert.equal(links.get("b").state, "unauthorized", "socket refused but /health answers → token revoked");
    assert.equal(clock.pending(), 0, "no reconnect timer while unauthorized");
    links.connect("b");
    assert.equal(sockets.length, 1, "connect() is a no-op while unauthorized");
    links.retry("b");
    assert.equal(sockets.length, 2, "retry() clears unauthorized and reconnects");
  }
  {
    const { clock, sockets, links } = harness();
    links.add(serverB);
    links.setActive("b");
    links.connect("b");
    sockets[0].drop();
    await settle();
    assert.equal(links.get("b").state, "offline", "socket refused and /health unreachable → offline");
    await clock.tick(INITIAL_RECONNECT_MS - 1);
    assert.equal(sockets.length, 1);
    await clock.tick(1);
    assert.equal(sockets.length, 2, "reconnects after the initial delay");
    sockets[1].drop();
    await settle();
    await clock.tick(INITIAL_RECONNECT_MS * 2);
    assert.equal(sockets.length, 3, "delay doubles");
    for (let i = 0; i < 8; i++) { sockets[sockets.length - 1].drop(); await settle(); await clock.tick(MAX_RECONNECT_MS); }
    const before = sockets.length;
    sockets[sockets.length - 1].drop();
    await settle();
    await clock.tick(MAX_RECONNECT_MS - 1);
    assert.equal(sockets.length, before, "capped at MAX_RECONNECT_MS");
    await clock.tick(1);
    assert.equal(sockets.length, before + 1);
    sockets[sockets.length - 1].open();
    sockets[sockets.length - 1].drop();
    await settle();
    await clock.tick(INITIAL_RECONNECT_MS);
    assert.equal(sockets.length, before + 2, "a successful open resets the backoff");
  }

  // --- visibility ------------------------------------------------------------
  {
    const { clock, sockets, links } = harness();
    links.add(serverA);
    links.add(serverB);
    links.setActive("a");
    links.connectAll();
    sockets[0].open();
    sockets[1].open();
    links.setVisible(false);
    assert.equal(links.get("a").state, "online", "the active link stays up when hidden");
    assert.equal(sockets[1].closed, true, "idle links close when hidden");
    assert.equal(links.get("b").state, "idle");
    await clock.tick(MAX_RECONNECT_MS);
    assert.equal(sockets.length, 2, "no reconnects while hidden");
    links.setVisible(true);
    assert.equal(sockets.length, 3, "idle links reconnect when visible again");
  }

  // --- role switching --------------------------------------------------------
  {
    const { sockets, links } = harness();
    links.add(serverA);
    links.add(serverB);
    links.setActive("a");
    links.connectAll();
    sockets[0].open();
    sockets[1].open();
    links.sendActive({ type: "listSessions" });
    assert.deepEqual(sockets[0].sent, [{ type: "listSessions" }]);
    const b = links.setActive("b");
    assert.equal(b.role, "active");
    assert.equal(links.get("a").role, "idle");
    assert.ok(sockets[0].sent.length >= 2, "the demoted link starts polling");
    links.sendActive({ type: "subscribe", sessionId: "s" });
    assert.deepEqual(sockets[1].sent[sockets[1].sent.length - 1], { type: "subscribe", sessionId: "s" });
    assert.equal(links.get("b").socket, sockets[1], "switching reuses the existing socket");
  }

  // --- update / remove -------------------------------------------------------
  {
    const { sockets, links } = harness();
    links.add(serverA);
    links.setActive("a");
    links.connect("a");
    sockets[0].open();
    links.update({ ...serverA, token: "tok-a2", origins: ["http://10.0.0.9:8765"], lastOrigin: "http://10.0.0.9:8765" });
    assert.equal(sockets[0].closed, true, "re-pair drops the old socket");
    assert.equal(sockets[1].url, "ws://10.0.0.9:8765/ws");
    assert.deepEqual(sockets[1].protocols, ["tok-a2"]);
    links.remove("a");
    assert.equal(sockets[1].closed, true);
    assert.equal(links.get("a"), null);
    assert.equal(links.activeLink(), null);
  }

  // --- pair ------------------------------------------------------------------
  {
    const calls = [];
    const { links } = harness({
      fetchImpl: (url) => {
        calls.push(url);
        if (url.startsWith("http://10.0.0.1")) return Promise.reject(new Error("net"));
        return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ token: "fresh" }) });
      },
    });
    const result = await links.pair(["http://10.0.0.1:8765", "http://100.64.0.1:8765"], "CODE", "phone");
    assert.deepEqual(result, { origin: "http://100.64.0.1:8765", token: "fresh" });
    assert.deepEqual(calls, ["http://10.0.0.1:8765/pair", "http://100.64.0.1:8765/pair"]);
  }
  {
    const { links } = harness({ fetchImpl: () => Promise.resolve({ ok: false, status: 401 }) });
    await assert.rejects(links.pair(["http://10.0.0.1:8765", "http://10.0.0.2:8765"], "CODE", "phone"), (err) => err.reason === "expired");
  }
  {
    const { links } = harness({ fetchImpl: () => Promise.resolve({ ok: false, status: 403 }) });
    await assert.rejects(links.pair(["http://10.0.0.1:8765"], "CODE", "phone"), (err) => err.reason === "origin");
  }
  {
    const { links } = harness();
    await assert.rejects(links.pair(["http://10.0.0.1:8765", "http://10.0.0.2:8765"], "CODE", "phone"), (err) => err.reason === "net");
  }
  {
    const { clock, links } = harness({ fetchImpl: () => new Promise(() => {}) });
    const pending = links.pair(["http://10.0.0.1:8765"], "CODE", "phone");
    await clock.tick(globalThis.RemoteHubLinks.PAIR_TIMEOUT_MS);
    await assert.rejects(pending, (err) => err.reason === "net");
  }

  console.log("hub-links tests passed");
})().catch((err) => { console.error(err); process.exit(1); });
```

- [ ] **Step 2: Run to verify it fails**

Run: `node scripts/tests/remote-web-hub/test-hub-links.js`
Expected: `Cannot find module '.../hub-links.js'`.

- [ ] **Step 3: Create the module**

Create `Alas/Resources/RemoteWeb/hub-links.js`:

```js
// One WebSocket link per paired server. app.js drives the ACTIVE link through
// sendActive()/onMessage exactly as it drove its single socket; idle links
// only keep attention counts fresh. Sockets, timers, and fetch are injected so
// node tests can drive every transition deterministically.
//
// deps:  { createSocket(url, protocols), fetch(url, init), setTimeout(fn, ms), clearTimeout(id) }
// hooks: { onStateChange(link), onHello(link, hello), onLegacy(link), onMessage(link, msg), onCounts(link) }
// link:  { id, origins, lastOrigin, token, role: "active"|"idle",
//          state: "idle"|"connecting"|"online"|"offline"|"unauthorized",
//          counts: {attention, running}, legacy, socket }

const HANDSHAKE_TIMEOUT_MS = 4000;
const PAIR_TIMEOUT_MS = 4000;
const PROBE_TIMEOUT_MS = 4000;
const IDLE_POLL_MS = 30 * 1000;
const INITIAL_RECONNECT_MS = 1500;
const MAX_RECONNECT_MS = 30000;

function wsUrl(origin) {
  return origin.replace(/^http/i, "ws") + "/ws";
}

function createLinks(deps, hooks) {
  const h = hooks || {};
  const links = new Map();
  let activeId = null;
  let visible = true;

  function notify(link) { if (h.onStateChange) h.onStateChange(link); }
  function setState(link, state) {
    if (link.state === state) return;
    link.state = state;
    notify(link);
  }

  function add(server) {
    const link = {
      id: server.id,
      origins: [...server.origins],
      lastOrigin: server.lastOrigin || server.origins[0],
      token: server.token,
      role: "idle",
      state: "idle",
      socket: null,
      attempt: 0,
      reconnectDelay: INITIAL_RECONNECT_MS,
      reconnectTimer: null,
      pollTimer: null,
      awaitingHello: false,
      legacy: false,
      counts: { attention: 0, running: 0 },
    };
    links.set(link.id, link);
    return link;
  }

  function get(id) { return links.get(id) || null; }
  function all() { return [...links.values()]; }
  function activeLink() { return activeId ? links.get(activeId) || null : null; }

  function clearTimers(link) {
    if (link.reconnectTimer) { deps.clearTimeout(link.reconnectTimer); link.reconnectTimer = null; }
    stopPolling(link);
  }

  function closeSocket(link) {
    const socket = link.socket;
    link.socket = null;
    if (!socket) return;
    socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
    try { socket.close(); } catch (_) {}
  }

  // Invalidates in-flight handshakes (their `attempt` no longer matches) and
  // drops the live socket without changing `state`.
  function teardown(link) {
    link.attempt += 1;
    clearTimers(link);
    closeSocket(link);
  }

  function remove(id) {
    const link = links.get(id);
    if (!link) return;
    teardown(link);
    links.delete(id);
    if (activeId === id) activeId = null;
  }

  // Re-pair: fresh token and origins; drop the old socket and reconnect.
  function update(server) {
    const link = links.get(server.id);
    if (!link) return null;
    teardown(link);
    link.origins = [...server.origins];
    link.lastOrigin = server.lastOrigin || server.origins[0];
    link.token = server.token;
    link.reconnectDelay = INITIAL_RECONNECT_MS;
    link.state = "idle";
    notify(link);
    connect(link.id);
    return link;
  }

  function setActive(id) {
    const previous = activeLink();
    if (previous && previous.id !== id) {
      previous.role = "idle";
      if (previous.state === "online") startPolling(previous);
      notify(previous);
    }
    activeId = id;
    const link = links.get(id);
    if (!link) return null;
    link.role = "active";
    stopPolling(link);
    notify(link);
    return link;
  }

  function sendTo(link, obj) {
    if (link && link.socket && link.socket.readyState === 1) link.socket.send(JSON.stringify(obj));
  }
  function sendActive(obj) { sendTo(activeLink(), obj); }

  function orderedOrigins(link) {
    if (!link.lastOrigin || !link.origins.includes(link.lastOrigin)) return [...link.origins];
    return [link.lastOrigin, ...link.origins.filter((o) => o !== link.lastOrigin)];
  }

  function connect(id) {
    const link = links.get(id);
    if (!link) return;
    if (link.state === "connecting" || link.state === "online" || link.state === "unauthorized") return;
    if (!visible && link.role !== "active") return;
    clearTimers(link);
    closeSocket(link);
    const attempt = ++link.attempt;
    setState(link, "connecting");
    attemptOrigin(link, orderedOrigins(link), 0, attempt);
  }

  // Tries one origin; on timeout or refusal moves to the next. `attempt`
  // guards against a stale handshake adopting a socket after a teardown.
  function attemptOrigin(link, order, index, attempt) {
    if (attempt !== link.attempt) return;
    if (index >= order.length) { onAllOriginsFailed(link, order, attempt); return; }
    const origin = order[index];
    let socket;
    try { socket = deps.createSocket(wsUrl(origin), [link.token]); }
    catch (_) { attemptOrigin(link, order, index + 1, attempt); return; }
    let settled = false;
    const timer = deps.setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.onopen = socket.onclose = socket.onerror = null;
      try { socket.close(); } catch (_) {}
      attemptOrigin(link, order, index + 1, attempt);
    }, HANDSHAKE_TIMEOUT_MS);
    socket.onopen = () => {
      if (settled) return;
      settled = true;
      deps.clearTimeout(timer);
      if (attempt !== link.attempt) { try { socket.close(); } catch (_) {} return; }
      adopt(link, socket, origin);
    };
    socket.onerror = () => {};
    socket.onclose = () => {
      if (settled) return;
      settled = true;
      deps.clearTimeout(timer);
      attemptOrigin(link, order, index + 1, attempt);
    };
  }

  function adopt(link, socket, origin) {
    link.socket = socket;
    link.lastOrigin = origin;
    link.reconnectDelay = INITIAL_RECONNECT_MS;
    link.awaitingHello = true;
    link.legacy = false;
    socket.onmessage = (event) => {
      if (link.socket !== socket) return;
      let msg;
      try { msg = JSON.parse(event.data); } catch (_) { return; }
      receive(link, msg);
    };
    socket.onclose = () => {
      if (link.socket !== socket) return;
      link.socket = null;
      stopPolling(link);
      setState(link, "offline");
      scheduleReconnect(link);
    };
    socket.onerror = () => {};
    setState(link, "online");
    if (link.role === "idle") startPolling(link);
  }

  function receive(link, msg) {
    if (!msg || typeof msg.type !== "string") return;
    if (link.awaitingHello) {
      link.awaitingHello = false;
      if (msg.type === "hello") { if (h.onHello) h.onHello(link, msg); return; }
      // A pre-hub Mac never says hello; treat its first frame as ordinary.
      link.legacy = true;
      if (h.onLegacy) h.onLegacy(link);
    } else if (msg.type === "hello") {
      if (h.onHello) h.onHello(link, msg);
      return;
    }
    if (msg.type === "sessionList") {
      const next = globalThis.RemoteHubRegistry.attentionCounts(msg.sessions);
      if (next.attention !== link.counts.attention || next.running !== link.counts.running) {
        link.counts = next;
        if (h.onCounts) h.onCounts(link);
      }
      if (link.role !== "active") return;
    }
    if (link.role === "active" && h.onMessage) h.onMessage(link, msg);
  }

  function scheduleReconnect(link) {
    if (link.reconnectTimer) return;
    if (!visible && link.role !== "active") return;
    const delay = link.reconnectDelay;
    link.reconnectDelay = Math.min(link.reconnectDelay * 2, MAX_RECONNECT_MS);
    link.reconnectTimer = deps.setTimeout(() => {
      link.reconnectTimer = null;
      connect(link.id);
    }, delay);
  }

  // Every origin refused the handshake. A reachable /health means the Mac is
  // up but rejected the token (revoked → "Pair again"); otherwise the Mac is
  // simply unreachable and we keep retrying.
  function onAllOriginsFailed(link, order, attempt) {
    probeAny(order).then((reachable) => {
      if (attempt !== link.attempt) return;
      if (reachable) { setState(link, "unauthorized"); return; }
      setState(link, "offline");
      scheduleReconnect(link);
    });
  }

  function probeAny(origins) {
    return Promise.all(origins.map(probe)).then((results) => results.some(Boolean));
  }

  function probe(origin) {
    return new Promise((resolve) => {
      let done = false;
      const timer = deps.setTimeout(() => { if (!done) { done = true; resolve(false); } }, PROBE_TIMEOUT_MS);
      Promise.resolve()
        .then(() => deps.fetch(origin + "/health", { method: "GET" }))
        .then(
          (res) => { if (!done) { done = true; deps.clearTimeout(timer); resolve(!!(res && res.ok)); } },
          () => { if (!done) { done = true; deps.clearTimeout(timer); resolve(false); } }
        );
    });
  }

  function startPolling(link) {
    stopPolling(link);
    if (!visible || link.role !== "idle" || link.state !== "online") return;
    sendTo(link, { type: "listSessions" });
    link.pollTimer = deps.setTimeout(() => {
      link.pollTimer = null;
      startPolling(link);
    }, IDLE_POLL_MS);
  }

  function stopPolling(link) {
    if (link.pollTimer) { deps.clearTimeout(link.pollTimer); link.pollTimer = null; }
  }

  function connectAll() {
    for (const link of links.values()) connect(link.id);
  }

  // Closes every non-active socket (page hidden, or hub flag off).
  function suspendIdle() {
    for (const link of links.values()) {
      if (link.role === "active") continue;
      teardown(link);
      if (link.state !== "unauthorized") setState(link, "idle");
    }
  }

  function setVisible(next) {
    visible = !!next;
    if (!visible) { suspendIdle(); return; }
    for (const link of links.values()) {
      if (link.state === "online" && link.role === "idle") startPolling(link);
      else connect(link.id);
    }
  }

  // Manual retry (gate button) or after a re-pair cleared "unauthorized".
  function retry(id) {
    const link = links.get(id);
    if (!link) return;
    teardown(link);
    link.reconnectDelay = INITIAL_RECONNECT_MS;
    link.state = "idle";
    notify(link);
    connect(id);
  }

  function pairError(reason) {
    const err = new Error("pairing failed: " + reason);
    err.reason = reason;
    return err;
  }

  function withTimeout(promise, ms) {
    return new Promise((resolve, reject) => {
      const timer = deps.setTimeout(() => reject(new Error("timeout")), ms);
      Promise.resolve(promise).then(
        (value) => { deps.clearTimeout(timer); resolve(value); },
        (err) => { deps.clearTimeout(timer); reject(err); }
      );
    });
  }

  // Redeems `code` at the first origin that answers. A 401 (expired code)
  // or 403 (origin not allowed) stops immediately; network failures move
  // on to the next origin. The request stays a CORS "simple request" (no
  // explicit Content-Type) so no preflight is needed on the hot path.
  function pair(origins, code, deviceName) {
    const tryAt = (index) => {
      if (index >= origins.length) return Promise.reject(pairError("net"));
      const origin = origins[index];
      return withTimeout(deps.fetch(origin + "/pair", { method: "POST", body: JSON.stringify({ code, deviceName }) }), PAIR_TIMEOUT_MS)
        .then(
          (res) => {
            if (res.status === 401) throw pairError("expired");
            if (res.status === 403) throw pairError("origin");
            if (!res.ok) return tryAt(index + 1);
            return Promise.resolve(res.json()).then((body) => ({ origin, token: body.token }));
          },
          () => tryAt(index + 1)
        );
    };
    return tryAt(0);
  }

  return { add, remove, update, get, all, activeLink, setActive, sendActive, connect, connectAll, suspendIdle, setVisible, retry, pair };
}

globalThis.RemoteHubLinks = {
  createLinks,
  wsUrl,
  HANDSHAKE_TIMEOUT_MS,
  PAIR_TIMEOUT_MS,
  IDLE_POLL_MS,
  INITIAL_RECONNECT_MS,
  MAX_RECONNECT_MS,
};
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash scripts/tests/remote-web-hub/run.sh`
Expected: both `hub-registry tests passed` and `hub-links tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Resources/RemoteWeb/hub-links.js scripts/tests/remote-web-hub/test-hub-links.js
git commit -m "feat(remote-web): add the per-server link manager"
```

---
### Task 9: Drive `app.js` through the link manager (flag off: single-server parity)

**Files:**
- Modify: `Alas/Resources/RemoteWeb/app.js:1, 7, 18-24, 118-249, 3503-3506`
- Modify: `Alas/Resources/RemoteWeb/index.html:241-248`
- Modify: `Alas/Resources/RemoteWeb/sw.js:1-19, 37-49`
- Test: `AlasTests/Remote/RemoteWebAssetTests.swift`

**Interfaces:**
- Consumes: `RemoteHubRegistry.*`, `RemoteHubLinks.createLinks` (Tasks 7–8).
- Produces (app.js, used by Task 10): `hub` (registry document), `links`, `hubUIEnabled`, `send(obj)`, `activeServer()`, `connectedLabel()`, `applyHubFlag(enabled)`, `refreshHubViews()`, `pairAndAdd(input, {activate})`, `pairingErrorMessage(err)`, `resetServerScopedState()`, `switchServer(id)`, `showPairAgainGate(link)`, `showPairGate()`, `retryConnection()`.

- [ ] **Step 1: Write the failing asset tests**

Append inside `RemoteWebAssetTests`:

```swift
    @Test func remoteWebLoadsAndPrecachesTheHubModules() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")
        let registry = try asset("hub-registry.js")
        let links = try asset("hub-links.js")

        try expectLoadsBeforeApp("/hub-registry.js", in: html)
        try expectLoadsBeforeApp("/hub-links.js", in: html)
        try expectReferencedAndPrecached("/hub-registry.js", html: html, sw: sw)
        try expectReferencedAndPrecached("/hub-links.js", html: html, sw: sw)
        // hub-links derives counts through the registry, so it must load second.
        let registryAt = try referencePosition(of: "/hub-registry.js", in: html)
        let linksAt = try referencePosition(of: "/hub-links.js", in: html)
        #expect(registryAt < linksAt)
        #expect(registry.contains("globalThis.RemoteHubRegistry ="))
        #expect(links.contains("globalThis.RemoteHubLinks ="))
        // Pure modules: no DOM access.
        #expect(!registry.contains("document."))
        #expect(!links.contains("document."))
    }

    @Test func serviceWorkerIgnoresCrossOriginRequests() throws {
        let sw = try asset("sw.js")
        let fetchHandler = try #require(sw.range(of: #"self.addEventListener("fetch""#).map { sw[$0.lowerBound...].prefix(600) })
        #expect(fetchHandler.contains("if (url.origin !== self.location.origin) return;"))
    }

    @Test func appDrivesTheActiveLinkThroughTheHubModules() throws {
        let js = try asset("app.js")

        #expect(js.contains("const hub = RemoteHubRegistry.load(localStorage, location.origin, location.hostname, Date.now());"))
        #expect(js.contains("const links = RemoteHubLinks.createLinks({"))
        #expect(js.contains("function send(obj) { links.sendActive(obj); }"))
        #expect(js.contains("function handleLinkStateChange(link)"))
        #expect(js.contains("function handleLinkHello(link, hello)"))
        #expect(js.contains("function onActiveOpen()"))
        #expect(js.contains("function onActiveClose()"))
        #expect(js.contains("function pairAndAdd(input, options)"))
        #expect(js.contains("function resetServerScopedState()"))
        #expect(js.contains("function switchServer(id)"))
        #expect(js.contains("function applyHubFlag(enabled)"))
        #expect(js.contains(#"document.addEventListener("visibilitychange""#))
        // The single-socket client is gone: the only WebSocket construction
        // is the factory handed to the link manager; no token key, no
        // page-level reconnect timer.
        #expect(js.components(separatedBy: "new WebSocket(").count == 2)
        #expect(js.contains("createSocket: (url, protocols) => new WebSocket(url, protocols),"))
        #expect(!js.contains(#"const tokenKey = "alas.remote.token";"#))
        #expect(!js.contains("function scheduleReconnect()"))
        #expect(!js.contains("async function ensureToken()"))
        #expect(!js.contains(#"fetch("/pair""#))
    }

    // The old ?code= flow must survive: a scanned QR (re)pairs and strips the
    // code from the URL before anything else happens.
    @Test func bootStillHonoursAPairingCodeInTheURL() throws {
        let js = try asset("app.js")
        let boot = try #require(js.range(of: "function boot() {").map { js[$0.lowerBound...].prefix(1200) })
        #expect(boot.contains("RemoteHubRegistry.parsePairingLink(location.href)"))
        #expect(boot.contains(#"history.replaceState({}, "", "/");"#))
        #expect(boot.contains("pairAndAdd(fromLink, { activate: true })"))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `-only-testing AlasTests/RemoteWebAssetTests`. Expected: the four new tests fail (files missing from index.html, patterns absent).

- [ ] **Step 3: index.html and sw.js**

In `index.html`, replace the script block (lines 241–248) with:

```html
  <script src="/marked.min.js?v=28"></script>
  <script src="/purify.min.js?v=28"></script>
  <script src="/repo-filter.js?v=2"></script>
  <script src="/session-ordering.js?v=2"></script>
  <script src="/worktree-creation.js?v=1"></script>
  <script src="/changes-view.js?v=8"></script>
  <script src="/file-browser.js?v=3"></script>
  <script src="/hub-registry.js?v=1"></script>
  <script src="/hub-links.js?v=1"></script>
  <script src="/app.js?v=85"></script>
```

In `sw.js`, bump the cache name to `alas-remote-shell-v67`, change `"/app.js?v=84"` to `"/app.js?v=85"`, and add after `"/file-browser.js?v=3",`:

```js
  "/hub-registry.js?v=1",
  "/hub-links.js?v=1",
```

In the `fetch` handler, add as the first statement after `const url = new URL(request.url);`:

```js
  // Cross-origin requests (pairing, health probes, sockets to OTHER Macs
  // from a hub served by this one) are never intercepted or cached.
  if (url.origin !== self.location.origin) return;
```

- [ ] **Step 4: app.js — hub state at the top**

Replace line 1 (`const tokenKey = "alas.remote.token";`) with:

```js
// Multi-server hub state. The registry (persisted) and links (one socket per
// paired Mac) are DOM-free modules; app.js owns the UI and drives the ACTIVE
// link through send()/handle() exactly as the single-server client did.
const hub = RemoteHubRegistry.load(localStorage, location.origin, location.hostname, Date.now());
let hubUIEnabled = false;   // mirrors the active server's `hello.hubEnabled`; gates every hub-only surface
const links = RemoteHubLinks.createLinks({
  createSocket: (url, protocols) => new WebSocket(url, protocols),
  fetch: (url, init) => fetch(url, init),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (id) => clearTimeout(id),
}, {
  onStateChange: (link) => handleLinkStateChange(link),
  onHello: (link, hello) => handleLinkHello(link, hello),
  onLegacy: () => refreshHubViews(),
  onMessage: (link, msg) => handle(msg),
  onCounts: () => refreshHubViews(),
});
```

Change line 7 from `let ws, currentSession = null, messages = new Map();` to `let currentSession = null, messages = new Map();`.

Delete lines 18–24 (`reconnectDelay`, `reconnectTimer`, `connectAttempt`, `pairingPromise`, `pairingController`, `initialReconnectDelay`, `maxReconnectDelay`). Keep `everConnected`, `escalationTimer`, `escalated`, `GRACE_MS`.

- [ ] **Step 5: app.js — escalation fallback and retry**

Replace `armEscalation` (lines 95–102) with:

```js
function armEscalation() {
  if (escalationTimer || escalated) return;   // don't re-arm while pending, or after we've already escalated
  escalationTimer = setTimeout(() => {
    escalationTimer = null;
    if (!everConnected && hubUIEnabled) {
      // Launch fallback: the remembered server is not answering but another
      // paired Mac is — drive that one instead of parking on the outage gate.
      const online = links.all().filter((l) => l.state === "online" && l.id !== hub.activeId).map((l) => l.id);
      const fallback = online.length ? RemoteHubRegistry.fallbackActiveId(hub, online) : null;
      if (fallback && fallback !== hub.activeId) { switchServer(fallback); return; }
    }
    escalated = true;
    showUnreachableGate();
  }, GRACE_MS);
}
```

Replace `scheduleReconnect` and `retryConnection` (lines 118–143) with:

```js
function retryConnection() {
  clearEscalation();               // start a fresh grace budget for the manual retry
  setStatus("Connecting…", "connecting");
  showConnectingGate();
  armEscalation();
  if (hub.activeId) links.retry(hub.activeId);
}
```

- [ ] **Step 6: app.js — replace the socket block**

Replace everything from `async function ensureToken() {` through `function send(obj) { ws && ws.readyState === 1 && ws.send(JSON.stringify(obj)); }` (lines 145–249) with:

```js
// --- active link -------------------------------------------------------------
// The link manager owns sockets and reconnects; these hooks translate the
// ACTIVE link's lifecycle into the chip/gate/escalation UI the single-server
// client already had, so the flag-off experience is unchanged.

function activeServer() { return hub.servers.find((s) => s.id === hub.activeId) || null; }

function connectedLabel() {
  const server = activeServer();
  return hubUIEnabled && server ? (server.name || server.lastOrigin) : "Connected";
}

function handleLinkStateChange(link) {
  refreshHubViews();
  if (link.role !== "active") return;
  switch (link.state) {
    case "online": onActiveOpen(); break;
    case "offline": onActiveClose(); break;
    case "connecting":
      if (!everConnected && !escalated) { setStatus("Connecting…", "connecting"); showConnectingGate(); }
      break;
    case "unauthorized":
      clearEscalation();
      setStatus("Not paired", "bad");
      showPairAgainGate(link);
      break;
    default: break;
  }
}

function onActiveOpen() {
  everConnected = true;
  clearEscalation();
  setStatus(connectedLabel(), "ok");
  hideGate();
  send({ type: "listSessions" });
  if (currentSession) send({ type: "subscribe", sessionId: currentSession });   // re-sync after reconnect
  replayActiveDetailRequest();   // the file/diff request itself doesn't survive a dropped socket
  replayActiveListRequest();     // ...and neither does a listChanges/root listFiles request
  if (createState.open) {
    createState.error = "";
    requestCreateLists();
    reloadNewWorktreeCatalog();
    renderCreateSheet();
  }
}

function onActiveClose() {
  failCreateOnDisconnect();
  if (closeState(everConnected) === "loading") {
    // Initial load still in progress — keep the neutral loading overlay up
    // instead of flashing the alarming "Can't reach Alas" screen. Once we've
    // escalated, leave the alarming gate up rather than flapping back to it.
    if (!escalated) { setStatus("Connecting…", "connecting"); showConnectingGate(); }
  } else {
    // Mid-session drop — keep the transcript visible; only the chip changes.
    setStatus("Reconnecting…", "bad");
  }
  armEscalation();     // no-op if already armed → grace stays a total budget
}

function showPairAgainGate(link) {
  const server = hub.servers.find((s) => s.id === link.id);
  const name = server ? (server.name || server.lastOrigin) : "This Mac";
  showGate("Pair again", `${name} no longer recognizes this device. Copy a fresh pairing link from Alas → Settings → Remote and paste it here.`, false);
}

function showPairGate() {
  clearEscalation();
  showGate("Pair this device", "On your Mac, open Alas → Settings → Remote and scan the QR code shown there.", false);
}

function handleLinkHello(link, hello) {
  const result = RemoteHubRegistry.applyHello(hub, link.id, hello);
  if (!result) return;
  RemoteHubRegistry.save(localStorage, hub);
  if (result.mergedFromId) {
    // The Mac we just reached was already paired under another entry. Keep
    // the older entry (its id is what the UI references), give it the fresh
    // token and origins, and reconnect it.
    links.remove(result.mergedFromId);
    links.update(result.server);
    if (hub.activeId === result.server.id) switchServer(result.server.id);
    return;
  }
  if (link.role === "active") {
    applyHubFlag(result.server.hubEnabled === true);
    if (link.state === "online") setStatus(connectedLabel(), "ok");
  }
  refreshHubViews();
}

// Flag off → single-server client: no idle sockets, no Settings tab, chip as
// before. Task 10 extends this with the Settings tab and chip surfaces.
function applyHubFlag(enabled) {
  hubUIEnabled = enabled;
  if (enabled) links.connectAll(); else links.suspendIdle();
  refreshHubViews();
}

// Re-renders every hub-only surface. Nothing to render until Task 10 adds
// the Settings tab server list and badge.
function refreshHubViews() {}

function send(obj) { links.sendActive(obj); }

// --- pairing & switching -----------------------------------------------------

// `input` is { origins, code } from RemoteHubRegistry.parsePairingLink /
// parseManualPairing. Resolves the registry entry; rejects with the link
// manager's { reason } errors.
async function pairAndAdd(input, options) {
  const result = await links.pair(input.origins, input.code, navigator.userAgent.slice(0, 40));
  const { server, rePaired } = RemoteHubRegistry.upsertPaired(hub, { origins: input.origins, token: result.token, now: Date.now() });
  RemoteHubRegistry.setLastOrigin(hub, server.id, result.origin);
  RemoteHubRegistry.save(localStorage, hub);
  if (rePaired && links.get(server.id)) links.update(server); else links.add(server);
  if ((options && options.activate) || hub.activeId === server.id) switchServer(server.id);
  else if (hubUIEnabled) links.connect(server.id);
  return server;
}

function pairingErrorMessage(err) {
  switch (err && err.reason) {
    case "expired": return "That code expired. Tap New code in Alas and try again.";
    case "origin": return "That Mac doesn't allow this address. Add this hub's address to Allowed origins in its Remote settings.";
    case "net": return "Couldn't reach that Mac at any of its addresses.";
    default: return "Pairing failed.";
  }
}

// Everything in app.js that belongs to ONE server. Runs before the active
// link changes so the unsubscribe goes to the server that owns the session.
function resetServerScopedState() {
  if (currentSession) showSessions();
  hideCreateSheet(true);
  worktreeCreation.disconnect();
  createState = { ...createState, open: false, step: "worktree", worktrees: [], agents: [], selectedWorktreeId: null, selectedAgentId: null, filter: "", busy: false, error: "" };
  listedSessions = new Map(); sessionTitles = new Map(); expandedClosedWorktrees = new Set();
  repoOverrides = new Map();
  dismissedQuestion = null; deferredCreatePrompt = null;
  renderSessions([]);
  showRepos();
}

function switchServer(id) {
  const target = hub.servers.find((s) => s.id === id);
  if (!target) return;
  if (hub.activeId && hub.activeId !== id) resetServerScopedState();
  RemoteHubRegistry.setActive(hub, id);
  RemoteHubRegistry.save(localStorage, hub);
  if (!links.get(id)) links.add(target);
  const link = links.setActive(id);
  applyHubFlag(target.hubEnabled === true);
  everConnected = false;
  if (link.state === "online") { onActiveOpen(); return; }
  clearEscalation();
  setStatus("Connecting…", "connecting");
  showConnectingGate();
  armEscalation();
  if (link.state === "unauthorized") showPairAgainGate(link);
  else links.connect(id);
}
```

- [ ] **Step 7: app.js — boot**

Replace the last four lines (`setStatus("Connecting…", "connecting"); showConnectingGate(); armEscalation(); connect();`) with:

```js
document.addEventListener("visibilitychange", () => links.setVisible(document.visibilityState === "visible"));

function boot() {
  for (const server of hub.servers) links.add(server);
  const fromLink = RemoteHubRegistry.parsePairingLink(location.href);
  if (fromLink) {
    // A freshly-scanned QR always (re)pairs, REPLACING any stored token for
    // that Mac — a phone holding a stale/rejected token recovers by scanning
    // a new code. Strip the code from the URL (history + referrer) first.
    history.replaceState({}, "", "/");
    setStatus("Pairing…", "connecting");
    showConnectingGate();
    pairAndAdd(fromLink, { activate: true }).catch((err) => {
      clearEscalation();
      if (err && err.reason === "net") { showUnreachableGate(); return; }
      showGate("Pairing link expired", pairingErrorMessage(err), false);
    });
    return;
  }
  if (!hub.activeId) { showPairGate(); return; }
  switchServer(hub.activeId);
}
boot();
```

- [ ] **Step 8: Run the asset tests, then exercise the flag-off client**

Run: `-only-testing AlasTests/RemoteWebAssetTests`. Expected: pass.

Manual, with the app built and Remote enabled on this Mac and the hub flag OFF: open the remote page in a desktop browser with the legacy token already stored (or scan a fresh QR). Confirm: the token key migrated (`localStorage["alas.remote.hub"]` exists, `alas.remote.token` gone), the session list loads, opening a session streams, quitting Alas shows "Reconnecting…" then the outage gate, relaunching reconnects, and the Settings tab is still disabled. In DevTools, confirm exactly one WebSocket.

- [ ] **Step 9: Commit**

```bash
git add Alas/Resources/RemoteWeb/app.js Alas/Resources/RemoteWeb/index.html Alas/Resources/RemoteWeb/sw.js AlasTests/Remote/RemoteWebAssetTests.swift
git commit -m "refactor(remote-web): drive the client through the hub registry and link manager"
```

---

### Task 10: Hub UI — Settings tab server list, add sheet, switch, badges, chip

**Files:**
- Modify: `Alas/Resources/RemoteWeb/index.html:28-29, 118-121, 131-134, 233-240`
- Modify: `Alas/Resources/RemoteWeb/app.js` (`applyHubFlag`, `refreshHubViews`, `showPairAgainGate`, `showPairGate`, `showSettings`, new functions, wiring near `$("gate-retry").onclick`)
- Modify: `Alas/Resources/RemoteWeb/style.css` (append), bump `style.css?v=49` in `index.html` and `sw.js`, cache `v68`, `app.js?v=86`
- Test: `AlasTests/Remote/RemoteWebAssetTests.swift`

**Interfaces:**
- Consumes everything Task 9 produces.
- Produces: `renderServerList()`, `renderSettingsBadge()`, `showAddServerSheet(targetId)`, `hideAddServerSheet()`, `submitAddServer()`, `showServerActions(id)`, `hideServerActions()`, `forgetServer(id)`.

- [ ] **Step 1: Write the failing asset tests**

Append inside `RemoteWebAssetTests`:

```swift
    @Test func settingsTabRendersTheHubServerList() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        let css = try asset("style.css")

        #expect(html.contains(#"<div id="hub-section" class="hidden">"#))
        #expect(html.contains(#"id="server-list""#))
        #expect(html.contains(#"id="add-server""#))
        #expect(html.contains(#"id="settings-placeholder""#))
        #expect(html.contains(#"id="tab-settings-badge" class="tab-count hidden""#))
        #expect(html.contains(#"id="add-server-sheet" class="sheet hidden" role="dialog""#))
        #expect(html.contains(#"id="add-server-link""#))
        #expect(html.contains(#"id="add-server-address""#))
        #expect(html.contains(#"id="add-server-code""#))
        #expect(html.contains(#"id="add-server-error" class="sheet-error hidden""#))
        #expect(html.contains(#"id="server-actions-sheet" class="sheet hidden" role="dialog""#))
        #expect(html.contains(#"id="server-repair""#))
        #expect(html.contains(#"id="server-forget""#))
        #expect(html.contains(#"id="gate-pair" class="hidden""#))

        #expect(js.contains("function renderServerList()"))
        #expect(js.contains("function renderSettingsBadge()"))
        #expect(js.contains("function showAddServerSheet(targetId)"))
        #expect(js.contains("async function submitAddServer()"))
        #expect(js.contains("function forgetServer(id)"))
        #expect(js.contains("RemoteHubRegistry.otherAttentionTotal(links.all(), hub.activeId)"))
        #expect(js.contains(#"$("tab-settings").disabled = !enabled;"#))
        #expect(js.contains(#"$("status").onclick = () => { if (hubUIEnabled && !currentSession) showSettings(); };"#))

        #expect(css.contains(".server-row {"))
        #expect(css.contains(".server-row.is-active"))
        #expect(css.contains("#tab-settings-badge"))
        #expect(css.contains(".dot.off"))
        #expect(css.contains(".dot.warn"))
    }

    // Flag off must look exactly like today: the tab stays disabled and no
    // server row is ever rendered.
    @Test func hubSurfacesStayHiddenUntilTheFlagIsOn() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        #expect(html.contains(#"id="tab-settings" class="bt-tab" aria-label="Settings" disabled"#))
        let body = try #require(js.range(of: "function applyHubFlag(enabled) {").map { js[$0.lowerBound...].prefix(600) })
        #expect(body.contains(#"$("hub-section").classList.toggle("hidden", !enabled);"#))
        #expect(body.contains(#"$("settings-placeholder").classList.toggle("hidden", enabled);"#))
        #expect(body.contains("if (enabled) links.connectAll(); else links.suspendIdle();"))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `-only-testing AlasTests/RemoteWebAssetTests`. Expected: the two new tests fail.

- [ ] **Step 3: index.html**

Replace the settings section (lines 118–121):

```html
    <section id="settings" class="view hidden">
      <h1>Settings</h1>
      <div id="hub-section" class="hidden">
        <p class="sheet-label">Servers</p>
        <div id="server-list"></div>
        <button id="add-server" class="option-btn" type="button">Add server…</button>
      </div>
      <p id="settings-placeholder" class="placeholder-card">Settings are coming soon.</p>
    </section>
```

Replace the Settings tab button (lines 131–134):

```html
    <button type="button" id="tab-settings" class="bt-tab" aria-label="Settings" disabled>
      <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="8" cy="8" r="2"/><path d="M8 1.5v2M8 12.5v2M14.5 8h-2M3.5 8h-2M12.6 3.4l-1.4 1.4M4.8 11.2l-1.4 1.4M12.6 12.6l-1.4-1.4M4.8 4.8L3.4 3.4"/></svg>
      <span>Settings</span>
      <span id="tab-settings-badge" class="tab-count hidden"></span>
    </button>
```

Add the two sheets before `<div id="gate" class="hidden">`:

```html
  <div id="add-server-sheet" class="sheet hidden" role="dialog" aria-modal="true" aria-labelledby="add-server-title">
    <div class="sheet-card">
      <p id="add-server-title" class="sheet-title">Add server</p>
      <div id="add-server-error" class="sheet-error hidden" role="alert" aria-live="assertive"></div>
      <label class="sheet-label" for="add-server-link">Pairing link</label>
      <input id="add-server-link" class="sheet-input" type="url" autocomplete="off" autocapitalize="none" spellcheck="false" placeholder="Paste the link from Alas → Settings → Remote" />
      <details id="add-server-manual">
        <summary class="sheet-label">Enter an address and code instead</summary>
        <input id="add-server-address" class="sheet-input" type="text" autocomplete="off" autocapitalize="none" spellcheck="false" placeholder="100.64.1.5:8765" aria-label="Server address" />
        <input id="add-server-code" class="sheet-input" type="text" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="Pairing code" aria-label="Pairing code" />
      </details>
      <button id="add-server-submit" class="btn-submit" type="button">Pair</button>
      <button id="add-server-cancel" class="sheet-close" type="button">Cancel</button>
    </div>
  </div>
  <div id="server-actions-sheet" class="sheet hidden" role="dialog" aria-modal="true" aria-labelledby="server-actions-title">
    <div class="sheet-card">
      <p id="server-actions-title" class="sheet-title">Server</p>
      <button id="server-repair" class="option-btn" type="button">Re-pair…</button>
      <button id="server-forget" class="option-btn is-destructive" type="button">Forget this server</button>
      <button id="server-actions-close" class="sheet-close" type="button">Close</button>
    </div>
  </div>
```

In the gate card, after `<button id="gate-retry" class="hidden">Try again</button>` add:

```html
      <button id="gate-pair" class="hidden">Paste a pairing link</button>
```

Bump `style.css?v=49` (line 14) and `app.js?v=86`; mirror both in `sw.js` and bump the cache to `alas-remote-shell-v68`.

- [ ] **Step 4: app.js — extend the flag, gates, and Settings tab**

Replace `applyHubFlag` and `refreshHubViews` from Task 9 with:

```js
// Flag off → single-server client: no idle sockets, no Settings tab, chip as
// before. Flag on → server list, add sheet, badges, tappable server chip.
function applyHubFlag(enabled) {
  hubUIEnabled = enabled;
  $("tab-settings").disabled = !enabled;
  $("hub-section").classList.toggle("hidden", !enabled);
  $("settings-placeholder").classList.toggle("hidden", enabled);
  $("status").classList.toggle("is-server", enabled);
  if (!enabled && topLevelTab === "settings") showRepos();
  if (enabled) links.connectAll(); else links.suspendIdle();
  refreshHubViews();
}

function refreshHubViews() {
  renderServerList();
  renderSettingsBadge();
}
```

In `showPairAgainGate` and `showPairGate`, add as the last line of each:

```js
  $("gate-pair").classList.remove("hidden");
```

and in `switchServer`, right after `everConnected = false;`:

```js
  $("gate-pair").classList.add("hidden");
```

Change `showSettings` to bail when the flag is off:

```js
function showSettings() {
  if (currentSession || !hubUIEnabled) return;   // tab bar is hidden during session detail; the tab is disabled flag-off
  topLevelTab = "settings";
  $("tab-settings").classList.add("is-active");
  $("tab-repos").classList.remove("is-active");
  $("sessions").classList.add("hidden");
  $("settings").classList.remove("hidden");
  renderServerList();
}
```

Add after `$("fab-new-session").onclick = showCreateSheet;`:

```js
$("status").onclick = () => { if (hubUIEnabled && !currentSession) showSettings(); };

// --- hub settings ------------------------------------------------------------

function serverDotClass(link) {
  if (!link) return "off";
  switch (link.state) {
    case "online": return link.counts.running > 0 ? "run" : "idle";
    case "connecting": return "connecting";
    case "unauthorized": return "warn";
    default: return "off";
  }
}

function serverSubtitle(server, link) {
  const where = (link && link.lastOrigin) || server.lastOrigin || server.origins[0];
  if (!link) return where;
  switch (link.state) {
    case "online": return link.legacy ? `${where} · Older Alas` : where;
    case "connecting": return `${where} · Connecting…`;
    case "unauthorized": return "Pair again";
    case "offline": return `${where} · Offline`;
    default: return where;
  }
}

function renderServerList() {
  if (!hubUIEnabled) return;
  const box = $("server-list");
  box.innerHTML = "";
  for (const server of hub.servers) {
    const link = links.get(server.id);
    const row = el("div", "server-row" + (server.id === hub.activeId ? " is-active" : ""));
    row.setAttribute("role", "button");
    row.tabIndex = 0;
    row.append(el("span", "dot " + serverDotClass(link)));
    const main = el("div", "server-main");
    main.append(el("div", "server-name", server.name || server.lastOrigin));
    main.append(el("div", "server-origin", serverSubtitle(server, link)));
    row.append(main);
    if (link && link.counts.attention > 0) row.append(el("span", "tab-count", String(link.counts.attention)));
    const menu = el("button", "iconbtn server-menu", "⋯");
    menu.type = "button";
    menu.setAttribute("aria-label", `Actions for ${server.name || server.lastOrigin}`);
    menu.onclick = (e) => { e.stopPropagation(); showServerActions(server.id); };
    row.append(menu);
    const activate = () => { if (server.id !== hub.activeId) { switchServer(server.id); showRepos(); } };
    row.onclick = activate;
    row.onkeydown = (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); activate(); } };
    box.append(row);
  }
}

function renderSettingsBadge() {
  const badge = $("tab-settings-badge");
  const total = hubUIEnabled ? RemoteHubRegistry.otherAttentionTotal(links.all(), hub.activeId) : 0;
  badge.textContent = total > 0 ? String(total) : "";
  badge.classList.toggle("hidden", total === 0);
}

let addServerTarget = null;   // client id when re-pairing a specific server, else null
let addServerBusy = false;

function showAddServerSheet(targetId) {
  addServerTarget = targetId || null;
  const target = addServerTarget ? hub.servers.find((s) => s.id === addServerTarget) : null;
  $("add-server-title").textContent = target ? `Re-pair ${target.name || target.lastOrigin}` : "Add server";
  $("add-server-link").value = "";
  $("add-server-address").value = target ? (target.lastOrigin || "") : "";
  $("add-server-code").value = "";
  $("add-server-manual").open = false;
  $("add-server-error").classList.add("hidden");
  $("add-server-submit").disabled = false;
  $("add-server-sheet").classList.remove("hidden");
  $("add-server-link").focus();
}

function hideAddServerSheet() {
  if (addServerBusy) return;
  $("add-server-sheet").classList.add("hidden");
  addServerTarget = null;
}

function showAddServerError(message) {
  const box = $("add-server-error");
  box.textContent = message;
  box.classList.remove("hidden");
}

async function submitAddServer() {
  if (addServerBusy) return;
  let input = RemoteHubRegistry.parsePairingLink($("add-server-link").value);
  if (!input) input = RemoteHubRegistry.parseManualPairing($("add-server-address").value, $("add-server-code").value);
  if (!input) { showAddServerError("That doesn't look like an Alas pairing link."); return; }
  addServerBusy = true;
  $("add-server-submit").disabled = true;
  $("add-server-error").classList.add("hidden");
  const wasEmpty = !hub.activeId;
  try {
    const server = await pairAndAdd(input, { activate: wasEmpty || addServerTarget === hub.activeId });
    addServerBusy = false;
    hideAddServerSheet();
    if (wasEmpty) hideGate();
    if (!wasEmpty && server.id !== hub.activeId) renderServerList();
  } catch (err) {
    addServerBusy = false;
    $("add-server-submit").disabled = false;
    showAddServerError(pairingErrorMessage(err));
  }
}

let serverActionsTarget = null;

function showServerActions(id) {
  const server = hub.servers.find((s) => s.id === id);
  if (!server) return;
  serverActionsTarget = id;
  $("server-actions-title").textContent = server.name || server.lastOrigin;
  $("server-actions-sheet").classList.remove("hidden");
}

function hideServerActions() {
  $("server-actions-sheet").classList.add("hidden");
  serverActionsTarget = null;
}

function forgetServer(id) {
  const wasActive = hub.activeId === id;
  if (wasActive) resetServerScopedState();
  RemoteHubRegistry.forgetServer(hub, id);
  RemoteHubRegistry.save(localStorage, hub);
  links.remove(id);
  if (!wasActive) { refreshHubViews(); return; }
  const online = links.all().filter((l) => l.state === "online").map((l) => l.id);
  const next = RemoteHubRegistry.fallbackActiveId(hub, online);
  if (next) { switchServer(next); return; }
  applyHubFlag(false);
  showPairGate();
}

$("add-server").onclick = () => showAddServerSheet(null);
$("add-server-submit").onclick = submitAddServer;
$("add-server-cancel").onclick = hideAddServerSheet;
$("add-server-sheet").onclick = (e) => { if (e.target.id === "add-server-sheet") hideAddServerSheet(); };
listen("add-server-link", "keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); submitAddServer(); } });
listen("add-server-code", "keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); submitAddServer(); } });
$("server-repair").onclick = () => { const id = serverActionsTarget; hideServerActions(); showAddServerSheet(id); };
$("server-forget").onclick = () => {
  const id = serverActionsTarget;
  const server = hub.servers.find((s) => s.id === id);
  hideServerActions();
  if (server && confirm(`Forget ${server.name || server.lastOrigin}? You will need a new pairing link to add it again.`)) forgetServer(id);
};
$("server-actions-close").onclick = hideServerActions;
$("server-actions-sheet").onclick = (e) => { if (e.target.id === "server-actions-sheet") hideServerActions(); };
$("gate-pair").onclick = () => {
  const active = hub.activeId ? links.get(hub.activeId) : null;
  showAddServerSheet(active && active.state === "unauthorized" ? hub.activeId : null);
};
```

Note `showPairGate()` is reachable flag-off (empty hub), and the add sheet must work there so a first server can be pasted; `showAddServerSheet` therefore does not check `hubUIEnabled`.

- [ ] **Step 5: style.css**

Append:

```css
/* --- hub: server list, add sheet, chip ------------------------------------ */
.server-row { display: flex; align-items: center; gap: 10px; margin: 6px 0; padding: 11px 13px; border-radius: 13px; background: var(--bg-2); box-shadow: inset 0 0 0 0.5px var(--ring); cursor: pointer; }
.server-row.is-active { box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--accent) 42%, transparent); }
.server-row:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.server-main { flex: 1; min-width: 0; }
.server-name { font-size: 15px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.server-origin { color: var(--fg-dim); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.server-menu { flex: 0 0 auto; }
.dot.off { background: oklch(1 0 0 / 0.18); }
.dot.connecting { background: var(--mod); }
.dot.warn { background: var(--del); }
#status.is-server { cursor: pointer; }
.bt-tab { position: relative; }
#tab-settings-badge { position: absolute; top: 5px; left: calc(50% + 6px); color: var(--on-accent); background: var(--del); }
#add-server-manual summary { cursor: pointer; list-style: none; }
#add-server-manual summary::-webkit-details-marker { display: none; }
#add-server-manual[open] summary { margin-bottom: 8px; }
```

- [ ] **Step 6: Run the asset tests and the node suite**

Run: `-only-testing AlasTests/RemoteWebAssetTests` and `bash scripts/tests/remote-web-hub/run.sh`. Expected: pass.

- [ ] **Step 7: Manual pass with two Macs**

With the hub flag ON on Mac A (Settings → Advanced → Experimental → Remote hub) and Remote enabled on both Macs:

1. Open Mac A's remote page on the phone (or a desktop browser). The status chip shows Mac A's name and the Settings tab is enabled with one row.
2. On Mac B, Settings → Remote → Show pairing QR → Copy pairing link. On the phone, Settings → Add server… → paste → Pair. Mac B appears with an online dot.
3. Tap Mac B's row: the Repos tab shows Mac B's sessions and the chip shows Mac B's name. Tap back to Mac A while a session streams on B: no error, A's list loads.
4. Start a session on B that asks a permission; while viewing A the Settings tab badge shows 1 and B's row shows the count.
5. Revoke the phone on Mac B: B's row says "Pair again"; switching to B shows the Pair again gate; "Paste a pairing link" re-pairs it.
6. Forget B; the list shrinks; forgetting the last server shows the pairing gate.
7. Quit Alas on Mac A after the page loaded, reload the page while B is online: within the 5 s grace the hub switches to B.
8. Turn the flag OFF on Mac A: after a reconnect the tab disables and the chip reads "Connected".

- [ ] **Step 8: Commit**

```bash
git add Alas/Resources/RemoteWeb/app.js Alas/Resources/RemoteWeb/index.html Alas/Resources/RemoteWeb/sw.js Alas/Resources/RemoteWeb/style.css AlasTests/Remote/RemoteWebAssetTests.swift
git commit -m "feat(remote-web): add the multi-server hub settings tab behind the experiment flag"
```

---

### Task 11: Focused verification and wrap-up

**Files:**
- Modify: `CHANGELOG.md` (Unreleased section, if the repo keeps one; otherwise skip)

- [ ] **Step 1: Run every affected Swift suite**

```bash
export ALAS_ZMX_OPTIONAL=1 ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_TARGET_ARCH=arm64
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing AlasTests/RemoteConfigTests \
  -only-testing AlasTests/RemoteProtocolTests \
  -only-testing AlasTests/RemoteOriginPolicyTests \
  -only-testing AlasTests/RemoteHTTPResponderTests \
  -only-testing AlasTests/RemotePairingLinkTests \
  -only-testing AlasTests/RemoteServerIntegrationTests \
  -only-testing AlasTests/RemoteAccessPolicyTests \
  -only-testing AlasTests/RemoteNetworkTests \
  -only-testing AlasTests/RemoteAppStateAccessTests \
  -only-testing AlasTests/RemoteWebAssetTests \
  test > /tmp/alas-test.log 2>&1
grep -E "Test run with|TEST (SUCCEEDED|FAILED)|error:" /tmp/alas-test.log | tail -20
```

Expected: `TEST SUCCEEDED` and a `Test run with N tests passed` line with zero failures.

- [ ] **Step 2: Run the node suites**

```bash
for d in scripts/tests/remote-web-*/; do bash "$d/run.sh"; done
```

Expected: every suite prints its "passed" line.

- [ ] **Step 3: Record what ran**

In the PR description, list the suites above and the manual checks from Task 9 Step 8 and Task 10 Step 7 that were performed, and which were not. Do not claim CI is green until its run completes.

- [ ] **Step 4: Commit any changelog entry**

```bash
git add CHANGELOG.md
git commit -m "docs: note the remote hub experiment"
```

---

## Testing notes

- `RemoteServerIntegrationTests` binds real sockets on `127.0.0.1`; the origin tests send raw HTTP over `NWConnection` because `URLSession` does not let a test set `Origin`.
- `-only-testing` filters are case-sensitive suite names; a typo yields "0 tests" and exit 0 under `-quiet`, so the grep above looks for the `Test run with` line.
- The node suites need no dependencies beyond `node` 22.
- `GitServiceStagedTests` has a known flaky type-checker timeout under load; it is not in the focused set above.
