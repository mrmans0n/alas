# Federation Phase 2: Bonjour Discovery Implementation Plan

**Goal:** A Mac running Alas with the Remote peers experiment on can advertise itself on the local network and list nearby Alas instances in Settings → Remote → Peers, so pairing with one is "pick it, type the code it shows" instead of copying a link between machines.

**Architecture:** Advertising rides on the existing `NWListener` in `RemoteServer` via `listener.service` (assignable on a running listener, so no restart). Browsing is a new `RemotePeerBrowser` over `NWBrowser` with a small injectable backend. Picking a discovered instance resolves its endpoint to a host:port, reads that Mac's `/remote-info` for its ranked advertised addresses, and feeds them plus a typed code into a new `RemotePeerManager.addPeer(code:origins:)`, which the pasted-link path also delegates to. Everything else in phase 1 (reciprocal pairing, confirmation wait, revocation, link lifecycle) is reused unchanged.

**Tech Stack:** Swift 5.9, SwiftUI (macOS), `Network.framework` (`NWListener.Service`, `NWBrowser`, `NWTXTRecord`, `NWConnection` for resolution), `URLSession` via `boundedFetch`, Swift Testing.

**Spec:** `docs/plans/2026-09-19-multi-instance-federation-design.md` § "1. Discovery", § "Feature flag", § "Security", Rollout step 3. Phase 1 (peer trust) landed in PR #1346.

## Global constraints

- Base branch: `main` after #1346. Branch `nacho/federation`.
- Still behind `AppConfig.Remote.federationEnabled`. Discovery adds `AppConfig.Remote.discoverable` (default `false`), decoded with `(try? c.decode(...)) ?? false` like its siblings. One toggle drives both advertising and browsing.
- Nothing in TXT beyond `id` (serverId, already public via `hello`, `/health`, `/remote-info`), `v` (protocol version), and `model` (hardware model). No paths, ports, tokens, or addresses.
- Discovery grants nothing. Every pairing still goes through `POST /pair` with a live code; the discovered instance only supplies origins.
- The peer-identity gap from the design's Security section is unchanged: a discovered instance's TXT `id` is as unverified as a pasted link's reply. The resolver cross-checks TXT `id` against `/remote-info`'s `serverId` only to catch stale or mismatched records, not as proof.
- Protocol version stays `1`. No wire message changes.
- New source and test files require `xcodegen` and a committed `Alas.xcodeproj`; confirm new suites actually ran (`Test run with N tests in M suites`).
- Tests use `import Testing`. Run only the suites named per task.
- No agent attribution in commits or code.

## File map

Create:

- `Alas/Sources/Remote/Discovery/RemoteBonjourService.swift` — service type, bounded service name, TXT encode/decode.
- `Alas/Sources/Remote/Discovery/RemotePeerBrowser.swift` — `RemoteDiscoveredInstance`, `RemoteServiceBrowsing` backend protocol, `NWBrowser`-backed implementation, the observable browser.
- `Alas/Sources/Remote/Discovery/RemoteDiscoveredInstanceResolver.swift` — endpoint → host:port → `/remote-info` → origins.
- `AlasTests/Remote/RemoteBonjourServiceTests.swift`
- `AlasTests/Remote/RemotePeerBrowserTests.swift`
- `AlasTests/Remote/RemoteDiscoveredInstanceResolverTests.swift`
- `AlasTests/Remote/RemoteDiscoveryIntegrationTests.swift` — real advertise + real browse on this host.

Modify:

- `Alas/Sources/Persistence/AppConfig.swift` — `discoverable`.
- `project.yml` — `NSLocalNetworkUsageDescription`, `NSBonjourServices`.
- `Alas/Sources/Remote/Server/RemoteServer.swift` — `advertise(_:)`, re-applied in `start()`.
- `Alas/Sources/App/AppState.swift` — advertise in `syncRemotePeers()`, `remotePeerBrowser`, resolver wiring.
- `Alas/Sources/Remote/Peer/RemotePeerManager.swift` — `addPeer(code:origins:)`.
- `Alas/Sources/Remote/Settings/RemoteServerPane.swift` — toggle, Nearby list, inline code entry.
- `AlasTests/Remote/RemoteConfigTests.swift`, `AlasTests/Remote/RemotePeerManagerTests.swift`.

## Tasks

### Task 1: `discoverable` flag and plist keys

- [ ] `AppConfig.Remote.discoverable: Bool = false`; init parameter, coding key, tolerant decode.
- [ ] `project.yml` info properties: `NSLocalNetworkUsageDescription` and `NSBonjourServices: [_alas._tcp]`. Run `xcodegen`.
- [ ] `RemoteConfigTests`: default false; decodes from a config without the key.

### Task 2: `RemoteBonjourService`

- [ ] `static let type = "_alas._tcp"`.
- [ ] `struct RemoteBonjourTXT: Equatable { serverId, protocolVersion, model }` with `nwTXTRecord` and `init?(txt: NWTXTRecord)`; missing or empty `id` → nil; non-integer `v` → nil.
- [ ] `static func serviceName(_ displayName: String) -> String`: trimmed, empty → `"Alas"`, truncated to 63 UTF-8 bytes on a scalar boundary.
- [ ] `RemoteBonjourServiceTests`: TXT round trip; rejected TXTs; name bounding on multi-byte input.

### Task 3: `RemoteServer.advertise(_:)`

- [ ] `private var advertisement: NWListener.Service?`; `func advertise(_ service: NWListener.Service?)` stores it and assigns `listener?.service`.
- [ ] `start()` assigns the stored advertisement before `listener.start(queue:)` so a port-fallback restart keeps advertising.
- [ ] `stop()` leaves the stored value alone; it is a setting, not listener state.

### Task 4: `RemotePeerBrowser`

- [ ] `struct RemoteDiscoveredInstance: Identifiable, Equatable { id = serverId, name, protocolVersion, model, endpoint: NWEndpoint }`.
- [ ] `protocol RemoteServiceBrowsing: AnyObject { var onResults: (([RemoteServiceBrowsing.Result]) -> Void)?; func start(); func stop() }` where `Result = (name: String, endpoint: NWEndpoint, txt: NWTXTRecord?)`. `NWServiceBrowser` wraps `NWBrowser(for: .bonjourWithTXTRecord(type:domain: nil), using: .tcp)` and hops results to the main actor.
- [ ] `@MainActor @Observable final class RemotePeerBrowser`: `init(localServerId: @escaping () -> String, backend: ...)`, `private(set) var instances`, `private(set) var isBrowsing`, `start()`, `stop()`. Drops results without a decodable TXT and results whose `serverId` equals the local one. Sorted by name for stable rows.
- [ ] `RemotePeerBrowserTests` with a fake backend: add/update/remove; self filtered; missing `id` dropped; `stop()` clears.

### Task 5: `RemoteDiscoveredInstanceResolver`

- [ ] `enum Failure: Error, Equatable { unreachable, identityMismatch, invalidReply }`.
- [ ] `typealias ResolveEndpoint = (NWEndpoint) async throws -> (host: String, port: UInt16)`; live implementation opens `NWConnection(to:using: .tcp)`, waits for `.ready`, reads `currentPath?.remoteEndpoint`, cancels; 4 s timeout.
- [ ] `func origins(for instance: RemoteDiscoveredInstance) async -> Result<[String], Failure>`: resolved `http://host:port` first, then `/remote-info` `addresses[].url` (decoded from `RemoteDiagnosticsSnapshot`) excluding localhost, deduped, capped at `RemotePairingLink.maxOrigins`. `/remote-info` `serverId` must equal `instance.id` when present, else `.identityMismatch`.
- [ ] `RemoteDiscoveredInstanceResolverTests` with fake resolve + fake fetch: ordering and cap; mismatch; unreachable; HTTP error.

### Task 6: `RemotePeerManager.addPeer(code:origins:)`

- [ ] Extract the body of `addPeer(link:)` after parsing into `addPeer(code:origins:)`; `addPeer(link:)` parses then delegates. Empty `origins` or empty `code` → `.invalidLink`.
- [ ] `RemotePeerManagerTests`: one test that `addPeer(code:origins:)` with empty origins returns `.invalidLink` and mints no code; existing link tests cover the rest.

### Task 7: AppState wiring

- [ ] `syncRemotePeers()`: after the link branch, `remoteServer?.advertise(shouldAdvertise ? service : nil)` where `shouldAdvertise = enabled && federationEnabled && discoverable`. Service built from `RemoteBonjourService.serviceName(remoteDisplayName)` and TXT from `config.remote.serverId`, `RemoteProtocolVersion.current`, `RemoteNetwork.hardwareModel()`.
- [ ] `private(set) lazy var remotePeerBrowser` with `localServerId: { config.remote.serverId }`.
- [ ] `func syncRemoteDiscovery()` called by the pane's toggle: saves nothing itself; calls `syncRemotePeers()` and stops the browser when discovery turns off.
- [ ] Display-name changes already trigger `saveConfig` in the pane; call `syncRemotePeers()` there too so the advertised name follows.

### Task 8: Settings UI

- [ ] Remote access group, only when `federationEnabled`: "Discoverable on this network" toggle bound to `config.remote.discoverable`; on change save + `syncRemoteDiscovery()`.
- [ ] Peers group: a "Nearby" row set from `state.remotePeerBrowser.instances`, between persisted peers and the manual link row. Row: name (+ model as desc); trailing "Paired" text when `state.remotePeers.peers` has that `serverId`, else "Pair" which selects the row and reveals an inline `AlasField` for the code plus "Pair" submit. Submit: resolver → `addPeer(code:origins:)`; errors reuse the existing `AddError` mapping plus two resolver strings.
- [ ] Browser lifecycle: `.task(id: discoverable)` on the Peers group starts the browser when `discoverable` is on and stops it on disappear or toggle off.
- [ ] Empty states: discoverable off → "Turn on Discoverable on this network to see nearby Macs."; on and none found → "No nearby Macs yet."

### Task 9: Loopback integration test

- [ ] `RemoteDiscoveryIntegrationTests`: start a real `RemoteServer` on port 0, `advertise` with a unique random name and a known serverId; a real `NWServiceBrowser`-backed `RemotePeerBrowser` (local id different) sees an instance with that serverId within 10 s; `RemoteDiscoveredInstanceResolver.live` resolves it to a host:port whose port equals `server.port`. Stop both.
- [ ] If the runner's mDNS is unavailable the test must fail loudly, not pass vacuously; gate on environment only if CI proves flaky.

### Task 10: Verification

- [ ] Suites: `RemoteConfigTests`, `RemoteBonjourServiceTests`, `RemotePeerBrowserTests`, `RemoteDiscoveredInstanceResolverTests`, `RemotePeerManagerTests`, `RemoteServerIntegrationTests`, `RemoteDiscoveryIntegrationTests`.
- [ ] `xcodebuild … -quiet build`.
- [ ] Manual, one Mac: toggle on, `dns-sd -B _alas._tcp` lists this Mac with `id=` in TXT (`dns-sd -L`); toggle off, it disappears without any remote client disconnecting.

## Follow-on

- **Phase 3 prerequisite: peer identity binding.** Bind each peer record to a key the peer proves possession of at pairing and on every `hello`. Required before `FederatedSessionsProvider` (design § "Known gap").
- **Phase 3: `FederatedSessionsProvider`** and **Phase 4: web client grouping**, as listed in the phase-1 plan.
