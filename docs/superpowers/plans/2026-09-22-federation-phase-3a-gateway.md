# Federation Phase 3a: Gateway Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac with verified, online peers surfaces those peers' sessions to its own remote clients: they appear in its `sessionList` tagged with the owning `serverId`, a client can subscribe to one and drive it, and every message crosses exactly one peer link to the session's home Mac.

**Architecture:** The gateway layer, not the `RemoteSessionsProvider` protocol, is where federation composes. `RemoteSessionsProvider` hands the gateway live `ACPSession` objects and the gateway reads their transcripts directly, but a peer's session is only ever a stream of `RemoteServerMessage`s, so there is no `ACPSession` to hand over. `FederatedSessionsProvider` therefore sits beside the local provider: each `RemoteSessionGateway` asks it first whether a client message names a peer session (`serverId:sessionId`), and if so the message is rewritten to the peer's own id and sent over that peer's `RemotePeerConnection`; replies come back through `RemotePeerManager`, are re-prefixed, and are fanned out to every gateway subscribed to that session. The peer's own `sessionList` is cached per peer, loop-guarded, tagged, and appended to the local list. Nothing outside the provider knows the id scheme.

**Tech Stack:** Swift 5.9, `RemotePeerConnection` (existing `URLSessionWebSocketTask` client), the existing `RemoteClientMessage`/`RemoteServerMessage` JSON wire, Swift Testing.

**Spec:** `docs/plans/2026-09-19-multi-instance-federation-design.md` § "3. Control: gateway aggregation over the existing protocol", § "Protocol handshake", § "Peer identity is proved, not claimed", Rollout step 4. Ticket: mrmans0n/alas#1408. Phases 1 and 2 landed in #1346 and #1395; identity binding in #1406.

## Global Constraints

- Base branch: `main` after #1406. Work on `nacho/fedi-4`.
- Everything stays behind `AppConfig.Remote.federationEnabled`. With the flag off, `RemotePeerManager.disconnectAll()` has already run, no link is online, so `carriesSessions` is false for every peer and nothing federated is ever emitted.
- **Nothing crosses a peer link unless `RemotePeerManager.carriesSessions(peerId:)` is true** (record pinned to a key and the socket proved it). Grandfathered and unverified records carry nothing, in either direction.
- Protocol version stays `1`. Every wire change is a new optional field: `serverId`/`serverName` on `sessionList` rows, `peers` on `hello`. No existing field changes meaning.
- Session ids are namespaced `"<serverId>:<sessionId>"` only on federated surfaces, only by `FederatedSessionsProvider`. A `serverId` is a UUID string (`AppConfig.Remote.ensureServerId`) and must never contain `:`; the parser splits on the first `:` and only treats the prefix as a peer when it names a peer that currently carries sessions. Any other id is local.
- Loop guard: a peer's row that already carries a `serverId` is dropped, never re-tagged.
- Every session has one home Mac. `canDrive`, writer leases, and permission policy are evaluated there; this Mac forwards and never re-evaluates. A reply the home Mac addresses to this Mac's link (for example `promptRejected`, `queueEditRestored`, `changeList`) is fanned out to every gateway subscribed to that session; a client ignores replies for requests it did not make, so this is accepted for 3a and noted under Follow-on.
- Out of scope: creating sessions on a peer (`createSession`, `createWorktreeSession`, `listWorktrees`, `listProjects`, `listBranches`, `listAgents` stay local), the native sidebar (#1409), the web client (#1410).
- New source and test files require `xcodegen` and a committed `Alas.xcodeproj`. After each task that adds a file, confirm the new suite actually ran (look for its `◇`/`✔` lines; the XCTest bridge's "Executed 0 tests" is a red herring).
- Tests use `import Testing`. Run only the suites named per task:

  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -only-testing AlasTests/<SuiteName> test > /tmp/alas-test.log 2>&1; grep -E "TEST (SUCCEEDED|FAILED)|✘|✔ Suite" /tmp/alas-test.log
  ```

- Keep code, comments, and strings in English. No agent attribution anywhere.

---

## File map

Create:

- `Alas/Sources/Remote/Federation/RemoteFederatedSessionID.swift` — compose and parse `serverId:sessionId`.
- `Alas/Sources/Remote/Federation/RemoteMessageSessionScope.swift` — `sessionId` and `replacingSessionId(_:)` on both wire enums.
- `Alas/Sources/Remote/Federation/FederatedPeerLinks.swift` — the upstream abstraction the provider consumes; `RemotePeerManager` conforms.
- `Alas/Sources/Remote/Federation/FederatedSessionsProvider.swift` — the router, peer list cache, subscription bookkeeping, `FederatedDownstream`.
- `AlasTests/Remote/RemoteFederatedSessionIDTests.swift`
- `AlasTests/Remote/RemoteMessageSessionScopeTests.swift`
- `AlasTests/Remote/FederatedSessionsProviderTests.swift`
- `AlasTests/Remote/RemoteFederationAggregationTests.swift` — two and three real in-process Macs plus a real WebSocket client.

Modify:

- `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift` — `RemoteSessionSummary.serverId`, `.serverName`.
- `Alas/Sources/Remote/Protocol/RemoteProtocol.swift` — `RemoteHelloPeer`, `RemoteServerIdentity.peers`, `hello(peers:)`.
- `Alas/Sources/Remote/Peer/RemotePeerConnection.swift` — the `hello` pattern gains the `peers` slot.
- `Alas/Sources/Remote/Peer/RemotePeerManager.swift` — `FederatedPeerLinks` conformance, `helloPeers`, event emission.
- `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift` — `federation` parameter, routing, merged list, detach on close.
- `Alas/Sources/Remote/Server/RemoteServer.swift` — `federation` property handed to each gateway.
- `Alas/Sources/App/AppState.swift` — `remoteFederation`, wiring, `peers` in `remoteServerIdentity()`.
- `AlasTests/Remote/RemoteProtocolTests.swift`, `RemotePeerManagerTests.swift`, `RemoteSessionGatewayTests.swift`.

---

### Task 1: `serverId` and `serverName` on `RemoteSessionSummary`

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift:94-165`
- Test: `AlasTests/Remote/RemoteProtocolTests.swift`

**Interfaces:**
- Produces: `RemoteSessionSummary.init(..., serverId: String? = nil, serverName: String? = nil)`, `let serverId: String?`, `let serverName: String?`. Absent on the wire when nil, so pre-federation clients and every existing test see identical JSON.

- [ ] **Step 1: Write the failing tests** (append inside `RemoteProtocolTests`)

```swift
    @Test func sessionSummaryOmitsServerFieldsWhenLocal() throws {
        let local = RemoteSessionSummary(id: "s1", title: "T", agentId: "claude", status: "idle", canDrive: true)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as? [String: Any])
        #expect(object["serverId"] == nil)
        #expect(object["serverName"] == nil)
        #expect(try roundTrip(local) == local)
    }

    @Test func sessionSummaryRoundTripsServerFieldsWhenFederated() throws {
        let federated = RemoteSessionSummary(id: "srv-b:s1", title: "T", agentId: "claude", status: "idle",
                                             canDrive: false, serverId: "srv-b", serverName: "Mac B")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(federated)) as? [String: Any])
        #expect(object["serverId"] as? String == "srv-b")
        #expect(object["serverName"] as? String == "Mac B")
        #expect(try roundTrip(federated) == federated)
    }

    @Test func sessionSummaryDecodesWithoutServerFields() throws {
        let legacy = Data(#"{"id":"s1","title":"T","agentId":"claude","status":"idle","canDrive":true}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteSessionSummary.self, from: legacy)
        #expect(decoded.serverId == nil)
        #expect(decoded.serverName == nil)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: the suite command with `RemoteProtocolTests`. Expected: compile error, `extra argument 'serverId' in call`.

- [ ] **Step 3: Implement**

In `RemoteSessionSummary` add two stored properties after `worktree`, two trailing init parameters, two coding keys, and encode/decode lines:

```swift
    let worktree: RemoteWorktreeSummary?
    /// Set only on rows a gateway forwards from a peer: the peer's `serverId`
    /// and display name, so a client can group by Mac. Nil means the row is
    /// local to the Mac that sent it, exactly as before federation.
    let serverId: String?
    let serverName: String?

    init(
        id: String,
        title: String,
        agentId: String,
        status: String,
        canDrive: Bool,
        isActive: Bool = true,
        projectId: String? = nil,
        worktreeId: String? = nil,
        updatedAt: Int64 = 0,
        worktree: RemoteWorktreeSummary? = nil,
        serverId: String? = nil,
        serverName: String? = nil
    ) {
        // existing assignments …
        self.serverId = serverId
        self.serverName = serverName
    }
```

```swift
    private enum CodingKeys: String, CodingKey {
        case id, title, agentId, status, canDrive, isActive, projectId, worktreeId, updatedAt, worktree
        case serverId, serverName
    }
    // init(from:) — add after `worktree:`
            worktree: try c.decodeIfPresent(RemoteWorktreeSummary.self, forKey: .worktree),
            serverId: try c.decodeIfPresent(String.self, forKey: .serverId),
            serverName: try c.decodeIfPresent(String.self, forKey: .serverName)
    // encode(to:) — add at the end
        try c.encodeIfPresent(serverId, forKey: .serverId)
        try c.encodeIfPresent(serverName, forKey: .serverName)
```

- [ ] **Step 4: Run to verify they pass**

Run: `RemoteProtocolTests`. Expected: the three new tests pass and nothing else in the suite changes.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift AlasTests/Remote/RemoteProtocolTests.swift
git commit -m "feat(remote): tag session summaries with an optional owning server"
```

---

### Task 2: `RemoteFederatedSessionID`

**Files:**
- Create: `Alas/Sources/Remote/Federation/RemoteFederatedSessionID.swift`
- Create: `AlasTests/Remote/RemoteFederatedSessionIDTests.swift`

**Interfaces:**
- Produces:
  - `RemoteFederatedSessionID.compose(serverId: String, sessionId: String) -> String`
  - `RemoteFederatedSessionID.parse(_ id: String, peers: Set<String>) -> (serverId: String, sessionId: String)?` — nil unless the prefix before the first `:` is in `peers` and the remainder is non-empty.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import Alas

struct RemoteFederatedSessionIDTests {
    @Test func composeJoinsWithAColon() {
        #expect(RemoteFederatedSessionID.compose(serverId: "srv-b", sessionId: "abc") == "srv-b:abc")
    }

    @Test func parseSplitsOnTheFirstColonOnlyForAKnownPeer() throws {
        let parsed = try #require(RemoteFederatedSessionID.parse("srv-b:abc:def", peers: ["srv-b"]))
        #expect(parsed.serverId == "srv-b")
        #expect(parsed.sessionId == "abc:def")
    }

    @Test func parseTreatsUnknownPrefixesAsLocal() {
        #expect(RemoteFederatedSessionID.parse("srv-c:abc", peers: ["srv-b"]) == nil)
        #expect(RemoteFederatedSessionID.parse("abc", peers: ["srv-b"]) == nil)
        #expect(RemoteFederatedSessionID.parse("srv-b:", peers: ["srv-b"]) == nil)
        #expect(RemoteFederatedSessionID.parse(":abc", peers: [""]) == nil)
    }

    @Test func composeThenParseRoundTrips() throws {
        let id = RemoteFederatedSessionID.compose(serverId: "0B1D", sessionId: "sess")
        let parsed = try #require(RemoteFederatedSessionID.parse(id, peers: ["0B1D"]))
        #expect(parsed.sessionId == "sess")
    }
}
```

- [ ] **Step 2: Run `xcodegen`, then run to verify they fail**

```bash
xcodegen
```

Run: `RemoteFederatedSessionIDTests`. Expected: compile error, `cannot find 'RemoteFederatedSessionID'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The id scheme for sessions a gateway forwards from a peer.
///
/// `"<serverId>:<sessionId>"`. Session ids are only unique per Mac, so a
/// federated surface has to say whose they are. The scheme lives here and in
/// `FederatedSessionsProvider` only: a gateway prefixes on the way out and
/// strips on the way in, and every client treats the whole string as opaque.
///
/// A `serverId` is a UUID string and never contains `:`, which is what makes
/// splitting on the first colon unambiguous. The prefix is treated as a peer
/// only when the caller says that peer exists; anything else is a local id
/// that happens to contain a colon.
enum RemoteFederatedSessionID {
    static func compose(serverId: String, sessionId: String) -> String {
        "\(serverId):\(sessionId)"
    }

    static func parse(_ id: String, peers: Set<String>) -> (serverId: String, sessionId: String)? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let serverId = String(id[..<colon])
        let sessionId = String(id[id.index(after: colon)...])
        guard !serverId.isEmpty, !sessionId.isEmpty, peers.contains(serverId) else { return nil }
        return (serverId, sessionId)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `RemoteFederatedSessionIDTests`. Expected: 4 tests pass, and the log shows the suite ran.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Federation/RemoteFederatedSessionID.swift AlasTests/Remote/RemoteFederatedSessionIDTests.swift Alas.xcodeproj
git commit -m "feat(remote): namespace federated session ids by owning server"
```

---

### Task 3: Session scope on the wire enums

**Files:**
- Create: `Alas/Sources/Remote/Federation/RemoteMessageSessionScope.swift`
- Create: `AlasTests/Remote/RemoteMessageSessionScopeTests.swift`

**Interfaces:**
- Produces:
  - `RemoteClientMessage.sessionId: String?` and `func replacingSessionId(_ new: String) -> RemoteClientMessage`
  - `RemoteServerMessage.sessionId: String?` and `func replacingSessionId(_ new: String) -> RemoteServerMessage`
  - For a case without a session id, `sessionId` is nil and `replacingSessionId` returns `self` unchanged.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Alas

struct RemoteMessageSessionScopeTests {
    @Test func everySessionScopedClientMessageExposesAndRewritesItsId() {
        let scoped: [RemoteClientMessage] = [
            .subscribe(sessionId: "a"), .unsubscribe(sessionId: "a"),
            .permissionDecision(sessionId: "a", requestId: 1, optionId: "o", persistScope: nil),
            .questionAnswer(sessionId: "a", requestId: 1, answers: []),
            .planResponse(sessionId: "a", requestId: .number(1), action: "accept", reason: nil),
            .elicitationResponse(sessionId: "a", requestId: "r", action: "cancel", content: nil),
            .takeOver(sessionId: "a"),
            .sendPrompt(sessionId: "a", text: "hi", attachments: [], intent: "auto"),
            .stop(sessionId: "a"),
            .setModel(sessionId: "a", modelId: "m"), .setMode(sessionId: "a", modeId: "m"),
            .setAutoRun(sessionId: "a", enabled: true), .renameSession(sessionId: "a", title: "t"),
            .fetchOlder(sessionId: "a", beforeIndex: 3, limit: 10),
            .queueForceSend(sessionId: "a", itemId: "i"), .queueRemove(sessionId: "a", itemId: "i"),
            .queueRetry(sessionId: "a", itemId: "i"), .queueEdit(sessionId: "a", itemId: "i"),
            .queueClear(sessionId: "a"),
            .listChanges(sessionId: "a"), .fileDiff(sessionId: "a", path: "p", stage: nil),
            .listFiles(sessionId: "a", path: nil), .readFile(sessionId: "a", path: "p"),
        ]
        for message in scoped {
            #expect(message.sessionId == "a", "\(message)")
            let rewritten = message.replacingSessionId("b")
            #expect(rewritten.sessionId == "b", "\(message)")
            // Only the id moved: rewriting back yields the original.
            #expect(rewritten.replacingSessionId("a") == message, "\(message)")
        }
    }

    @Test func unscopedClientMessagesHaveNoIdAndAreUnchanged() {
        let unscoped: [RemoteClientMessage] = [
            .helloAck(protocolVersion: 1), .listSessions, .listWorktrees, .listAgents, .listProjects,
            .listBranches(projectId: "p"),
            .createWorktreeSession(projectId: "p", base: "main", branch: "b", agentId: "x"),
            .createSession(worktreeId: "w", agentId: "x"),
        ]
        for message in unscoped {
            #expect(message.sessionId == nil, "\(message)")
            #expect(message.replacingSessionId("b") == message, "\(message)")
        }
    }

    @Test func everySessionScopedServerMessageExposesAndRewritesItsId() {
        let cfg = RemoteSessionConfig(sessionId: "a", models: [], modes: [], currentModel: nil,
                                      currentMode: nil, autoRunEnabled: false, acceptsImages: false)
        let scoped: [RemoteServerMessage] = [
            .transcriptSnapshot(sessionId: "a", streamingState: "idle", canDrive: false, messages: [],
                                firstIndex: 0, totalCount: 0, epoch: 0, revision: 0),
            .transcriptDelta(sessionId: "a", streamingState: "idle", canDrive: false, upserts: [], epoch: 0, revision: 1),
            .transcriptPage(sessionId: "a", epoch: 0, firstIndex: 0, messages: []),
            .stopPending(sessionId: "a"),
            .permissionRequest(sessionId: "a", payload: RemotePermissionPayload(
                requestId: 0, toolName: "t", options: [], title: nil, reason: nil, defaultToNo: false, mcpServerName: nil)),
            .permissionResolved(sessionId: "a", requestId: 0),
            .questionRequest(sessionId: "a", payload: RemoteQuestionPayload(requestId: 0, title: nil, questions: [])),
            .questionResolved(sessionId: "a", requestId: 0),
            .planRequest(sessionId: "a", payload: RemotePlanPayload(
                requestId: .number(1), toolCallId: "tc", name: "n", overview: "o", plan: "p", todos: [], isProject: false, phases: [])),
            .planResolved(sessionId: "a", requestId: .number(1)),
            .elicitationRequest(sessionId: "a", payload: RemoteElicitationPayload(
                requestId: "r", title: nil, message: "m", mode: "form", fields: [], elicitationId: nil, url: nil)),
            .elicitationResolved(sessionId: "a", requestId: "r"),
            .sessionClosed(sessionId: "a"), .promptRejected(sessionId: "a"),
            .sessionConfig(cfg), .sessionRenamed(sessionId: "a", title: "t"),
            .queueState(sessionId: "a", items: []), .queueEditRestored(sessionId: "a", itemId: "i", text: "t"),
            .changeList(sessionId: "a", comparisonRef: nil, metricsAvailable: false, files: [], staged: [],
                        unstaged: [], commits: [], truncated: false),
            .changeListFailed(sessionId: "a", reason: .sessionUnknown, message: nil),
            .fileDiffResult(sessionId: "a", path: "p", hunks: [], truncated: false),
            .fileDiffFailed(sessionId: "a", path: "p", reason: .sessionUnknown, message: nil),
            .fileTree(sessionId: "a", path: nil, nodes: [], truncated: false),
            .fileTreeFailed(sessionId: "a", path: nil, reason: .sessionUnknown, message: nil),
            .fileContents(sessionId: "a", path: "p", text: "", truncated: false),
            .fileUnavailable(sessionId: "a", path: "p", reason: .sessionUnknown, byteSize: nil, message: nil),
        ]
        for message in scoped {
            #expect(message.sessionId == "a", "\(message)")
            let rewritten = message.replacingSessionId("b")
            #expect(rewritten.sessionId == "b", "\(message)")
            #expect(rewritten.replacingSessionId("a") == message, "\(message)")
        }
    }

    @Test func unscopedServerMessagesHaveNoIdAndAreUnchanged() {
        let summary = RemoteSessionSummary(id: "a", title: "t", agentId: "x", status: "idle", canDrive: false)
        let unscoped: [RemoteServerMessage] = [
            .hello(protocolVersion: 1, serverId: "s", name: "n", hubEnabled: false),
            .identityProof(challenge: "c", publicKey: "k", signature: "s"),
            .sessionList(sessions: [summary]), .worktreeList(worktrees: []), .agentList(agents: []),
            .projectList(projects: []), .branchList(projectId: "p", branches: [], preferredBase: "main"),
            .branchListFailed(projectId: "p", message: "m"),
            .worktreeSessionCreated(session: summary),
            .worktreeSessionCreationFailed(stage: .worktree, message: "m", worktreeId: nil),
            .sessionCreated(session: summary), .createSessionFailed(message: "m"),
            .error(message: "m"),
        ]
        for message in unscoped {
            #expect(message.sessionId == nil, "\(message)")
            #expect(message.replacingSessionId("b") == message, "\(message)")
        }
    }
}
```

The payload argument lists above match the memberwise inits in `RemoteMessageWireJSON.swift` (`RemotePlanPayload.name/overview/plan/isProject` and `RemoteElicitationPayload.message` are non-optional). The assertions do not depend on payload contents.

- [ ] **Step 2: Run `xcodegen`, then run to verify they fail**

Run: `RemoteMessageSessionScopeTests`. Expected: compile error, `value of type 'RemoteClientMessage' has no member 'sessionId'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Which session a wire message is about, and the same message re-addressed.
///
/// `FederatedSessionsProvider` is the only caller: it strips a peer prefix
/// from a client message before forwarding it to the peer, and adds it back
/// to whatever the peer answers. Both enums keep the session id as a plain
/// associated value, so this is a mechanical map with one case per message.
/// A message with no session id (lists, creation, handshake, errors) reports
/// nil and is returned untouched.
extension RemoteClientMessage {
    var sessionId: String? {
        switch self {
        case .helloAck, .listSessions, .listWorktrees, .listAgents, .listProjects, .listBranches,
             .createWorktreeSession, .createSession:
            return nil
        case .subscribe(let id), .unsubscribe(let id), .takeOver(let id), .stop(let id), .queueClear(let id),
             .listChanges(let id):
            return id
        case .permissionDecision(let id, _, _, _), .questionAnswer(let id, _, _), .planResponse(let id, _, _, _),
             .elicitationResponse(let id, _, _, _), .sendPrompt(let id, _, _, _), .setModel(let id, _),
             .setMode(let id, _), .setAutoRun(let id, _), .renameSession(let id, _), .fetchOlder(let id, _, _),
             .queueForceSend(let id, _), .queueRemove(let id, _), .queueRetry(let id, _), .queueEdit(let id, _),
             .fileDiff(let id, _, _), .listFiles(let id, _), .readFile(let id, _):
            return id
        }
    }

    func replacingSessionId(_ new: String) -> RemoteClientMessage {
        switch self {
        case .helloAck, .listSessions, .listWorktrees, .listAgents, .listProjects, .listBranches,
             .createWorktreeSession, .createSession:
            return self
        case .subscribe: return .subscribe(sessionId: new)
        case .unsubscribe: return .unsubscribe(sessionId: new)
        case .permissionDecision(_, let requestId, let optionId, let persistScope):
            return .permissionDecision(sessionId: new, requestId: requestId, optionId: optionId, persistScope: persistScope)
        case .questionAnswer(_, let requestId, let answers):
            return .questionAnswer(sessionId: new, requestId: requestId, answers: answers)
        case .planResponse(_, let requestId, let action, let reason):
            return .planResponse(sessionId: new, requestId: requestId, action: action, reason: reason)
        case .elicitationResponse(_, let requestId, let action, let content):
            return .elicitationResponse(sessionId: new, requestId: requestId, action: action, content: content)
        case .takeOver: return .takeOver(sessionId: new)
        case .sendPrompt(_, let text, let attachments, let intent):
            return .sendPrompt(sessionId: new, text: text, attachments: attachments, intent: intent)
        case .stop: return .stop(sessionId: new)
        case .setModel(_, let modelId): return .setModel(sessionId: new, modelId: modelId)
        case .setMode(_, let modeId): return .setMode(sessionId: new, modeId: modeId)
        case .setAutoRun(_, let enabled): return .setAutoRun(sessionId: new, enabled: enabled)
        case .renameSession(_, let title): return .renameSession(sessionId: new, title: title)
        case .fetchOlder(_, let beforeIndex, let limit):
            return .fetchOlder(sessionId: new, beforeIndex: beforeIndex, limit: limit)
        case .queueForceSend(_, let itemId): return .queueForceSend(sessionId: new, itemId: itemId)
        case .queueRemove(_, let itemId): return .queueRemove(sessionId: new, itemId: itemId)
        case .queueRetry(_, let itemId): return .queueRetry(sessionId: new, itemId: itemId)
        case .queueEdit(_, let itemId): return .queueEdit(sessionId: new, itemId: itemId)
        case .queueClear: return .queueClear(sessionId: new)
        case .listChanges: return .listChanges(sessionId: new)
        case .fileDiff(_, let path, let stage): return .fileDiff(sessionId: new, path: path, stage: stage)
        case .listFiles(_, let path): return .listFiles(sessionId: new, path: path)
        case .readFile(_, let path): return .readFile(sessionId: new, path: path)
        }
    }
}

extension RemoteServerMessage {
    var sessionId: String? {
        switch self {
        case .hello, .identityProof, .sessionList, .worktreeList, .agentList, .projectList, .branchList,
             .branchListFailed, .worktreeSessionCreated, .worktreeSessionCreationFailed, .sessionCreated,
             .createSessionFailed, .error:
            return nil
        case .transcriptSnapshot(let id, _, _, _, _, _, _, _), .transcriptDelta(let id, _, _, _, _, _),
             .transcriptPage(let id, _, _, _), .stopPending(let id), .permissionRequest(let id, _),
             .permissionResolved(let id, _), .questionRequest(let id, _), .questionResolved(let id, _),
             .planRequest(let id, _), .planResolved(let id, _), .elicitationRequest(let id, _),
             .elicitationResolved(let id, _), .sessionClosed(let id), .promptRejected(let id),
             .sessionRenamed(let id, _), .queueState(let id, _), .queueEditRestored(let id, _, _),
             .changeList(let id, _, _, _, _, _, _, _, _), .changeListFailed(let id, _, _),
             .fileDiffResult(let id, _, _, _, _, _), .fileDiffFailed(let id, _, _, _, _),
             .fileTree(let id, _, _, _), .fileTreeFailed(let id, _, _, _), .fileContents(let id, _, _, _),
             .fileUnavailable(let id, _, _, _, _):
            return id
        case .sessionConfig(let cfg):
            return cfg.sessionId
        }
    }

    func replacingSessionId(_ new: String) -> RemoteServerMessage {
        switch self {
        case .hello, .identityProof, .sessionList, .worktreeList, .agentList, .projectList, .branchList,
             .branchListFailed, .worktreeSessionCreated, .worktreeSessionCreationFailed, .sessionCreated,
             .createSessionFailed, .error:
            return self
        case .transcriptSnapshot(_, let st, let cd, let m, let firstIndex, let totalCount, let epoch, let revision):
            return .transcriptSnapshot(sessionId: new, streamingState: st, canDrive: cd, messages: m,
                                       firstIndex: firstIndex, totalCount: totalCount, epoch: epoch, revision: revision)
        case .transcriptDelta(_, let st, let cd, let u, let epoch, let revision):
            return .transcriptDelta(sessionId: new, streamingState: st, canDrive: cd, upserts: u, epoch: epoch, revision: revision)
        case .transcriptPage(_, let epoch, let firstIndex, let m):
            return .transcriptPage(sessionId: new, epoch: epoch, firstIndex: firstIndex, messages: m)
        case .stopPending: return .stopPending(sessionId: new)
        case .permissionRequest(_, let p): return .permissionRequest(sessionId: new, payload: p)
        case .permissionResolved(_, let r): return .permissionResolved(sessionId: new, requestId: r)
        case .questionRequest(_, let p): return .questionRequest(sessionId: new, payload: p)
        case .questionResolved(_, let r): return .questionResolved(sessionId: new, requestId: r)
        case .planRequest(_, let p): return .planRequest(sessionId: new, payload: p)
        case .planResolved(_, let r): return .planResolved(sessionId: new, requestId: r)
        case .elicitationRequest(_, let p): return .elicitationRequest(sessionId: new, payload: p)
        case .elicitationResolved(_, let r): return .elicitationResolved(sessionId: new, requestId: r)
        case .sessionClosed: return .sessionClosed(sessionId: new)
        case .promptRejected: return .promptRejected(sessionId: new)
        case .sessionConfig(let cfg):
            return .sessionConfig(RemoteSessionConfig(
                sessionId: new, models: cfg.models, modes: cfg.modes, currentModel: cfg.currentModel,
                currentMode: cfg.currentMode, autoRunEnabled: cfg.autoRunEnabled, acceptsImages: cfg.acceptsImages))
        case .sessionRenamed(_, let title): return .sessionRenamed(sessionId: new, title: title)
        case .queueState(_, let items): return .queueState(sessionId: new, items: items)
        case .queueEditRestored(_, let itemId, let text):
            return .queueEditRestored(sessionId: new, itemId: itemId, text: text)
        case .changeList(_, let ref, let available, let files, let staged, let unstaged, let commits, let truncated, let commitsTruncated):
            return .changeList(sessionId: new, comparisonRef: ref, metricsAvailable: available, files: files,
                               staged: staged, unstaged: unstaged, commits: commits, truncated: truncated,
                               commitsTruncated: commitsTruncated)
        case .changeListFailed(_, let reason, let message):
            return .changeListFailed(sessionId: new, reason: reason, message: message)
        case .fileDiffResult(_, let path, let stage, let hunks, let truncated, let metadataNote):
            return .fileDiffResult(sessionId: new, path: path, stage: stage, hunks: hunks, truncated: truncated,
                                   metadataNote: metadataNote)
        case .fileDiffFailed(_, let path, let stage, let reason, let message):
            return .fileDiffFailed(sessionId: new, path: path, stage: stage, reason: reason, message: message)
        case .fileTree(_, let path, let nodes, let truncated):
            return .fileTree(sessionId: new, path: path, nodes: nodes, truncated: truncated)
        case .fileTreeFailed(_, let path, let reason, let message):
            return .fileTreeFailed(sessionId: new, path: path, reason: reason, message: message)
        case .fileContents(_, let path, let text, let truncated):
            return .fileContents(sessionId: new, path: path, text: text, truncated: truncated)
        case .fileUnavailable(_, let path, let reason, let byteSize, let message):
            return .fileUnavailable(sessionId: new, path: path, reason: reason, byteSize: byteSize, message: message)
        }
    }
}
```

Both switches are exhaustive on purpose, with no `default`: adding a wire message later fails to compile here until someone decides whether it is session-scoped.

- [ ] **Step 4: Run to verify they pass**

Run: `RemoteMessageSessionScopeTests`. Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Federation/RemoteMessageSessionScope.swift AlasTests/Remote/RemoteMessageSessionScopeTests.swift Alas.xcodeproj
git commit -m "feat(remote): expose and rewrite the session id on wire messages"
```

---

### Task 4: `FederatedPeerLinks` and the `RemotePeerManager` conformance

**Files:**
- Create: `Alas/Sources/Remote/Federation/FederatedPeerLinks.swift`
- Modify: `Alas/Sources/Remote/Peer/RemotePeerManager.swift` (`handle(_:peerId:)` at 816-859, `forget` at 623, `disconnectAll` at 801, the class doc comment at 3-7)
- Test: `AlasTests/Remote/RemotePeerManagerTests.swift`

**Interfaces:**
- Produces:

```swift
struct FederatedPeerInfo: Equatable, Hashable, Sendable { let serverId: String; let name: String }

enum FederatedPeerLinkEvent {
    /// Something about whether `serverId` carries sessions may have changed.
    case availabilityChanged(serverId: String)
    /// A frame from a peer that currently carries sessions.
    case message(serverId: String, RemoteServerMessage)
}

@MainActor
protocol FederatedPeerLinks: AnyObject {
    var sessionCarryingPeers: [FederatedPeerInfo] { get }
    var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)? { get set }
    /// Dropped silently unless `serverId` names a peer that carries sessions.
    func sendToPeer(_ message: RemoteClientMessage, serverId: String)
}
```

  and `RemotePeerManager: FederatedPeerLinks`. `RemotePeerManagerTests.FakeLink` gains `var sent: [RemoteClientMessage]`.

- [ ] **Step 1: Write the failing tests** (append inside `RemotePeerManagerTests`; first change `FakeLink.send` to `func send(_ message: RemoteClientMessage) { sent.append(message) }` with `var sent: [RemoteClientMessage] = []`)

```swift
    private func verifiedPeer(id: String = "p1", serverId: String = "srv-a") -> RemotePeer {
        RemotePeer(id: id, serverId: serverId, name: "Mac A", origins: ["http://10.0.0.1:8765"], lastOrigin: nil,
                   token: "t", publicKey: "pinned-key", protocolVersion: nil, localDeviceId: nil, addedAt: Date())
    }

    private func unverifiedPeer(id: String = "p2", serverId: String = "srv-old") -> RemotePeer {
        RemotePeer(id: id, serverId: serverId, name: "Old Mac", origins: ["http://10.0.0.2:8765"], lastOrigin: nil,
                   token: "t", publicKey: nil, protocolVersion: nil, localDeviceId: nil, addedAt: Date())
    }

    @Test func sessionCarryingPeersListsOnlyVerifiedOnlineLinks() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), unverifiedPeer(), verifiedPeer(id: "p3", serverId: "srv-c")])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        #expect(manager.sessionCarryingPeers.isEmpty)
        try #require(links.byPeerId["p1"]).emit(.stateChanged(.online))
        try #require(links.byPeerId["p2"]).emit(.stateChanged(.online))   // unverified: never carries
        try #require(links.byPeerId["p3"]).emit(.stateChanged(.offline))
        #expect(manager.sessionCarryingPeers == [FederatedPeerInfo(serverId: "srv-a", name: "Mac A")])
    }

    @Test func peerFramesReachTheFederationEventOnlyOverACarryingLink() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), unverifiedPeer()])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        var events: [FederatedPeerLinkEvent] = []
        manager.onFederationEvent = { events.append($0) }
        manager.connectAll()
        let verified = try #require(links.byPeerId["p1"])
        let unverified = try #require(links.byPeerId["p2"])
        verified.emit(.message(.sessionClosed(sessionId: "x")))         // offline: dropped
        verified.emit(.stateChanged(.online))
        verified.emit(.message(.sessionClosed(sessionId: "x")))         // online + verified: forwarded
        unverified.emit(.stateChanged(.online))
        unverified.emit(.message(.sessionClosed(sessionId: "y")))       // online but unverified: dropped
        let forwarded = events.compactMap { event -> (String, RemoteServerMessage)? in
            if case .message(let serverId, let message) = event { return (serverId, message) }
            return nil
        }
        #expect(forwarded.count == 1)
        #expect(forwarded.first?.0 == "srv-a")
        #expect(forwarded.first?.1 == .sessionClosed(sessionId: "x"))
        let availability = events.compactMap { event -> String? in
            if case .availabilityChanged(let serverId) = event { return serverId }
            return nil
        }
        #expect(availability.contains("srv-a"))
        #expect(availability.contains("srv-old"))
    }

    @Test func sendToPeerOnlyReachesACarryingLink() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), unverifiedPeer()])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        let verified = try #require(links.byPeerId["p1"])
        let unverified = try #require(links.byPeerId["p2"])
        manager.sendToPeer(.listSessions, serverId: "srv-a")            // offline: dropped
        verified.emit(.stateChanged(.online))
        unverified.emit(.stateChanged(.online))
        manager.sendToPeer(.listSessions, serverId: "srv-a")
        manager.sendToPeer(.listSessions, serverId: "srv-old")
        manager.sendToPeer(.listSessions, serverId: "srv-nobody")
        #expect(verified.sent == [.listSessions])
        #expect(unverified.sent.isEmpty)
    }

    @Test func forgetAndDisconnectAllAnnounceAvailabilityChanges() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), verifiedPeer(id: "p3", serverId: "srv-c")])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        try #require(links.byPeerId["p1"]).emit(.stateChanged(.online))
        try #require(links.byPeerId["p3"]).emit(.stateChanged(.online))
        var announced: [String] = []
        manager.onFederationEvent = { if case .availabilityChanged(let id) = $0 { announced.append(id) } }
        manager.forget(peerId: "p1")
        #expect(announced == ["srv-a"])
        #expect(manager.sessionCarryingPeers == [FederatedPeerInfo(serverId: "srv-c", name: "Mac A")])
        manager.disconnectAll()
        #expect(announced.contains("srv-c"))
        #expect(manager.sessionCarryingPeers.isEmpty)
    }
```

- [ ] **Step 2: Run `xcodegen`, then run to verify they fail**

Run: `RemotePeerManagerTests`. Expected: compile errors for `sessionCarryingPeers`, `onFederationEvent`, `sendToPeer`, `FederatedPeerInfo`.

- [ ] **Step 3: Implement the protocol file**

```swift
import Foundation

/// A peer as `FederatedSessionsProvider` sees it: the identity its rows are
/// tagged with and the name a client groups them under.
struct FederatedPeerInfo: Equatable, Hashable, Sendable {
    let serverId: String
    let name: String
}

enum FederatedPeerLinkEvent {
    /// Whether `serverId` carries sessions may have changed: its link went
    /// up or down, its record was forgotten, or every link was torn down.
    /// The consumer re-reads `sessionCarryingPeers` rather than trusting the
    /// event to say which way it went.
    case availabilityChanged(serverId: String)
    /// A frame that arrived over a link that carries sessions. Frames on any
    /// other link are dropped before they get here.
    case message(serverId: String, RemoteServerMessage)
}

/// What `FederatedSessionsProvider` needs from the peer links, kept apart
/// from `RemotePeerManager` so the provider's tests drive it with a fake.
@MainActor
protocol FederatedPeerLinks: AnyObject {
    /// Peers whose records are pinned to a proven key and whose socket is
    /// online right now. Only these may carry session traffic.
    var sessionCarryingPeers: [FederatedPeerInfo] { get }
    var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)? { get set }
    /// Sends over `serverId`'s link. Silently dropped unless that peer
    /// currently carries sessions: the gate is enforced here, on every send,
    /// not only when a route was first chosen.
    func sendToPeer(_ message: RemoteClientMessage, serverId: String)
}
```

- [ ] **Step 4: Implement the manager conformance**

Update the class doc comment (lines 3-7) to:

```swift
/// Owns this Mac's outbound peers: the persisted records, one link each, and
/// both halves of reciprocal pairing. Session traffic over the links is
/// consumed by `FederatedSessionsProvider` through `FederatedPeerLinks`; a
/// frame is only handed over when the link carries sessions.
```

Add after `onRevokeDevice` (line 76):

```swift
    /// `FederatedPeerLinks` sink. Set by `FederatedSessionsProvider`.
    @ObservationIgnored var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)?
```

Replace the `.stateChanged` and `.message` arms in `handle(_:peerId:)`:

```swift
        case .stateChanged(let state):
            states[peerId] = state
            if let peer = peers.first(where: { $0.id == peerId }) {
                onFederationEvent?(.availabilityChanged(serverId: peer.serverId))
            }
```

```swift
        case .message(let message):
            // Nothing may be consumed for a peer whose record is not bound
            // to verified key material: an unverified record is only as
            // strong as the address it was paired over, and session
            // aggregation means transcripts, prompts, diffs and permission
            // decisions. `carriesSessions(peerId:)` is that gate — a
            // verified record's link has already proved possession on this
            // very socket.
            guard carriesSessions(peerId: peerId),
                  let peer = peers.first(where: { $0.id == peerId }) else { return }
            onFederationEvent?(.message(serverId: peer.serverId, message))
```

In `forget(peerId:)`, after `store.save(peers)` at the end:

```swift
        onFederationEvent?(.availabilityChanged(serverId: peer.serverId))
```

In `disconnectAll()`, after `states = [:]`:

```swift
        for peer in peers {
            onFederationEvent?(.availabilityChanged(serverId: peer.serverId))
        }
```

Add the conformance at the end of the file:

```swift
extension RemotePeerManager: FederatedPeerLinks {
    var sessionCarryingPeers: [FederatedPeerInfo] {
        peers.filter { carriesSessions(peerId: $0.id) }
            .map { FederatedPeerInfo(serverId: $0.serverId, name: $0.name) }
    }

    func sendToPeer(_ message: RemoteClientMessage, serverId: String) {
        guard let peer = peers.first(where: { $0.serverId == serverId }),
              carriesSessions(peerId: peer.id) else { return }
        connections[peer.id]?.send(message)
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `RemotePeerManagerTests`. Expected: the 4 new tests pass and the existing suite is unchanged.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Federation/FederatedPeerLinks.swift Alas/Sources/Remote/Peer/RemotePeerManager.swift AlasTests/Remote/RemotePeerManagerTests.swift Alas.xcodeproj
git commit -m "feat(remote): expose session-carrying peer links to federation"
```

---

### Task 5: `FederatedSessionsProvider`

**Files:**
- Create: `Alas/Sources/Remote/Federation/FederatedSessionsProvider.swift`
- Create: `AlasTests/Remote/FederatedSessionsProviderTests.swift`

**Interfaces:**
- Consumes: `FederatedPeerLinks` (Task 4), `RemoteFederatedSessionID` (Task 2), `sessionId`/`replacingSessionId` (Task 3), `RemoteSessionSummary.serverId` (Task 1).
- Produces:

```swift
@MainActor final class FederatedDownstream {
    let id: UUID
    init(send: @escaping @MainActor (RemoteServerMessage) -> Void,
         sessionListChanged: @escaping @MainActor () -> Void)
}

@MainActor final class FederatedSessionsProvider {
    static let listPollInterval: TimeInterval = 15
    static let listRequestThrottle: TimeInterval = 2
    var onPeerAvailabilityChanged: (@MainActor () -> Void)?
    init(links: FederatedPeerLinks)
    func attach(_ downstream: FederatedDownstream)
    func detach(_ downstream: FederatedDownstream)
    var peerSessionSummaries: [RemoteSessionSummary]   // namespaced, tagged, loop-guarded
    /// True when the message was consumed (routed to a peer, or a peer-only
    /// verb). False means "handle locally".
    func route(_ message: RemoteClientMessage, from downstream: FederatedDownstream) -> Bool
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Alas

@MainActor
struct FederatedSessionsProviderTests {
    @MainActor
    final class FakeLinks: FederatedPeerLinks {
        var sessionCarryingPeers: [FederatedPeerInfo] = []
        var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)?
        var sent: [(serverId: String, message: RemoteClientMessage)] = []
        func sendToPeer(_ message: RemoteClientMessage, serverId: String) {
            guard sessionCarryingPeers.contains(where: { $0.serverId == serverId }) else { return }
            sent.append((serverId, message))
        }
        func goOnline(_ serverId: String, name: String) {
            sessionCarryingPeers.append(FederatedPeerInfo(serverId: serverId, name: name))
            onFederationEvent?(.availabilityChanged(serverId: serverId))
        }
        func goOffline(_ serverId: String) {
            sessionCarryingPeers.removeAll { $0.serverId == serverId }
            onFederationEvent?(.availabilityChanged(serverId: serverId))
        }
        func receive(_ message: RemoteServerMessage, from serverId: String) {
            onFederationEvent?(.message(serverId: serverId, message))
        }
        func sent(to serverId: String) -> [RemoteClientMessage] { sent.filter { $0.serverId == serverId }.map(\.message) }
    }

    @MainActor
    final class Client {
        var received: [RemoteServerMessage] = []
        var listRefreshes = 0
        private(set) var downstream: FederatedDownstream!
        init() {
            downstream = FederatedDownstream(
                send: { [weak self] in self?.received.append($0) },
                sessionListChanged: { [weak self] in self?.listRefreshes += 1 })
        }
    }

    private func row(_ id: String, serverId: String? = nil) -> RemoteSessionSummary {
        RemoteSessionSummary(id: id, title: "T \(id)", agentId: "claude", status: "idle", canDrive: false,
                             serverId: serverId, serverName: serverId.map { "Name \($0)" })
    }

    @Test func aPeerComingOnlineIsAskedForItsSessionsAndItsRowsAreTaggedAndNamespaced() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        #expect(links.sent(to: "srv-b") == [.listSessions])
        links.receive(.sessionList(sessions: [row("s1"), row("s2")]), from: "srv-b")
        let rows = provider.peerSessionSummaries
        #expect(rows.map(\.id) == ["srv-b:s1", "srv-b:s2"])
        #expect(rows.allSatisfy { $0.serverId == "srv-b" && $0.serverName == "Mac B" })
        #expect(rows.first?.title == "T s1")
        #expect(client.listRefreshes == 1)
    }

    @Test func rowsAPeerItselfForwardedAreNeverReExported() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [row("s1"), row("srv-c:s9", serverId: "srv-c")]), from: "srv-b")
        #expect(provider.peerSessionSummaries.map(\.id) == ["srv-b:s1"])
    }

    @Test func anUnchangedPeerListDoesNotRefreshDownstreams() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [row("s1")]), from: "srv-b")
        links.receive(.sessionList(sessions: [row("s1")]), from: "srv-b")
        #expect(client.listRefreshes == 1)
    }

    @Test func listSessionsFromAClientIsForwardedToEveryPeerAndStillHandledLocally() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.goOnline("srv-c", name: "Mac C")
        links.sent.removeAll()
        #expect(provider.route(.listSessions, from: client.downstream) == false)
        #expect(links.sent(to: "srv-b") == [.listSessions])
        #expect(links.sent(to: "srv-c") == [.listSessions])
    }

    @Test func subscribeIsForwardedWithTheLocalIdAndRepliesComeBackNamespaced() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        #expect(provider.route(.subscribe(sessionId: "srv-b:s1"), from: client.downstream))
        #expect(links.sent(to: "srv-b").contains(.subscribe(sessionId: "s1")))
        links.receive(.transcriptDelta(sessionId: "s1", streamingState: "idle", canDrive: true, upserts: [], epoch: 0, revision: 1),
                      from: "srv-b")
        #expect(client.received == [
            .transcriptDelta(sessionId: "srv-b:s1", streamingState: "idle", canDrive: true, upserts: [], epoch: 0, revision: 1)
        ])
    }

    @Test func framesForASessionNobodySubscribedToAreDropped() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        links.receive(.worktreeList(worktrees: []), from: "srv-b")
        #expect(client.received.isEmpty)
    }

    @Test func localAndUnknownIdsAreNotRouted() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        #expect(provider.route(.subscribe(sessionId: "s1"), from: client.downstream) == false)
        #expect(provider.route(.subscribe(sessionId: "srv-z:s1"), from: client.downstream) == false)
        #expect(provider.route(.createSession(worktreeId: "w", agentId: "a"), from: client.downstream) == false)
        #expect(links.sent(to: "srv-b") == [.listSessions])
    }

    @Test func driveVerbsAreForwardedVerbatimApartFromTheId() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.sent.removeAll()
        let prompt = RemoteClientMessage.sendPrompt(sessionId: "srv-b:s1", text: "go", attachments: [], intent: "steer")
        #expect(provider.route(prompt, from: client.downstream))
        #expect(provider.route(.stop(sessionId: "srv-b:s1"), from: client.downstream))
        #expect(provider.route(.fetchOlder(sessionId: "srv-b:s1", beforeIndex: 4, limit: 20), from: client.downstream))
        #expect(links.sent(to: "srv-b") == [
            .sendPrompt(sessionId: "s1", text: "go", attachments: [], intent: "steer"),
            .stop(sessionId: "s1"),
            .fetchOlder(sessionId: "s1", beforeIndex: 4, limit: 20),
        ])
    }

    @Test func twoClientsShareOneUpstreamSubscriptionAndBothGetFrames() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let one = Client()
        let two = Client()
        provider.attach(one.downstream)
        provider.attach(two.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.sent.removeAll()
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: one.downstream)
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: two.downstream)
        // Each downstream subscribe re-asks upstream so the newcomer gets a
        // fresh snapshot; the peer answers a re-subscribe with one.
        #expect(links.sent(to: "srv-b") == [.subscribe(sessionId: "s1"), .subscribe(sessionId: "s1")])
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        #expect(one.received == [.stopPending(sessionId: "srv-b:s1")])
        #expect(two.received == [.stopPending(sessionId: "srv-b:s1")])
        // The first to leave does not unsubscribe upstream; the last does.
        _ = provider.route(.unsubscribe(sessionId: "srv-b:s1"), from: one.downstream)
        #expect(!links.sent(to: "srv-b").contains(.unsubscribe(sessionId: "s1")))
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        #expect(one.received.count == 1)
        #expect(two.received.count == 2)
        provider.detach(two.downstream)
        #expect(links.sent(to: "srv-b").contains(.unsubscribe(sessionId: "s1")))
    }

    @Test func aPeerGoingOfflineClosesItsSessionsAndDropsItsRows() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [row("s1")]), from: "srv-b")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: client.downstream)
        let refreshesBefore = client.listRefreshes
        links.goOffline("srv-b")
        #expect(client.received.contains(.sessionClosed(sessionId: "srv-b:s1")))
        #expect(provider.peerSessionSummaries.isEmpty)
        #expect(client.listRefreshes == refreshesBefore + 1)
        // Nothing further is forwarded for a peer that is gone, and its id
        // no longer parses as federated.
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        #expect(!client.received.contains(.stopPending(sessionId: "srv-b:s1")))
        #expect(provider.route(.subscribe(sessionId: "srv-b:s1"), from: client.downstream) == false)
    }

    @Test func sessionClosedFromThePeerForgetsTheSubscription() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: client.downstream)
        links.receive(.sessionClosed(sessionId: "s1"), from: "srv-b")
        #expect(client.received == [.sessionClosed(sessionId: "srv-b:s1")])
        links.sent.removeAll()
        provider.detach(client.downstream)
        #expect(links.sent.isEmpty)   // nothing left to unsubscribe
    }

    @Test func availabilityCallbackFiresOnlyWhenTheSetOfCarryingPeersChanges() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        var fired = 0
        provider.onPeerAvailabilityChanged = { fired += 1 }
        links.goOnline("srv-b", name: "Mac B")
        #expect(fired == 1)
        links.onFederationEvent?(.availabilityChanged(serverId: "srv-b"))   // same set
        #expect(fired == 1)
        links.goOffline("srv-b")
        #expect(fired == 2)
    }
}
```

- [ ] **Step 2: Run `xcodegen`, then run to verify they fail**

Run: `FederatedSessionsProviderTests`. Expected: compile error, `cannot find 'FederatedSessionsProvider'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One gateway's view into federation: where forwarded frames go, and how
/// to tell it the merged session list changed. A gateway creates one in its
/// init, attaches it, and detaches it in `close()`.
@MainActor
final class FederatedDownstream {
    let id = UUID()
    let send: @MainActor (RemoteServerMessage) -> Void
    let sessionListChanged: @MainActor () -> Void

    init(send: @escaping @MainActor (RemoteServerMessage) -> Void,
         sessionListChanged: @escaping @MainActor () -> Void) {
        self.send = send
        self.sessionListChanged = sessionListChanged
    }
}

/// Composes this Mac's peers' sessions into what its own remote clients see.
///
/// Sits beside `RemoteSessionsProvider`, not in front of it: the local
/// provider hands gateways live `ACPSession`s, while a peer's session only
/// ever exists here as wire frames. Each `RemoteSessionGateway` asks
/// `route(_:from:)` first; a message naming a peer session is rewritten to
/// the peer's own id and sent over that peer's link, and everything the peer
/// answers for a subscribed session comes back re-prefixed to every gateway
/// subscribed to it. The peer's own `sessionList` is cached per peer, tagged
/// with its `serverId` and name, and appended to the local list by the
/// gateway.
///
/// The id scheme (`RemoteFederatedSessionID`) never leaves this type. A
/// prefix is only honoured while that peer carries sessions, so an id for a
/// peer that is offline, unverified or forgotten falls through to local
/// handling — where the gateway reports it as closed or refuses the prompt,
/// which is the right answer for a session this Mac cannot reach.
///
/// Every session has one home Mac: writer leases, `canDrive` and permission
/// policy are evaluated there, and this Mac forwards without re-evaluating.
/// This Mac holds one device credential per peer, so its clients share that
/// one lease on the peer; the design accepts that a gateway is a trusted
/// controller.
@MainActor
final class FederatedSessionsProvider {
    /// How often a peer is re-asked for its list while anyone is attached.
    /// Matches the web client's own idle poll, so a peer's status changes
    /// reach a phone about as fast as its own Mac's do.
    static let listPollInterval: TimeInterval = 15
    /// Several phones polling at once must not turn into a burst upstream.
    static let listRequestThrottle: TimeInterval = 2

    /// Fired when the set of session-carrying peers changes, so the server
    /// can push a fresh `hello` (its `peers` list) to connected clients.
    var onPeerAvailabilityChanged: (@MainActor () -> Void)?

    private let links: FederatedPeerLinks
    private var downstreams: [UUID: FederatedDownstream] = [:]
    /// Peers that carry sessions right now, by `serverId`.
    private var activePeers: [String: FederatedPeerInfo] = [:]
    /// Each active peer's last list, already loop-guarded, tagged and namespaced.
    private var peerRows: [String: [RemoteSessionSummary]] = [:]
    /// Namespaced session id → downstreams that asked for it.
    private var subscribers: [String: Set<UUID>] = [:]
    private var pollTimer: Task<Void, Never>?
    private var lastListRequestAt: Date?
    private let now: () -> Date

    init(links: FederatedPeerLinks, now: @escaping () -> Date = { Date() }) {
        self.links = links
        self.now = now
        links.onFederationEvent = { [weak self] event in self?.handle(event) }
        reconcilePeers()
    }

    // MARK: - Downstreams

    func attach(_ downstream: FederatedDownstream) {
        downstreams[downstream.id] = downstream
        syncPollTimer()
    }

    func detach(_ downstream: FederatedDownstream) {
        downstreams[downstream.id] = nil
        for (namespaced, ids) in subscribers where ids.contains(downstream.id) {
            removeSubscriber(downstream.id, from: namespaced)
        }
        syncPollTimer()
    }

    /// Peer rows for the merged `sessionList`, grouped by peer name.
    var peerSessionSummaries: [RemoteSessionSummary] {
        activePeers.values
            .sorted { ($0.name, $0.serverId) < ($1.name, $1.serverId) }
            .flatMap { peerRows[$0.serverId] ?? [] }
    }

    /// Routes a client message. Returns true when it was consumed here.
    func route(_ message: RemoteClientMessage, from downstream: FederatedDownstream) -> Bool {
        if case .listSessions = message {
            // The gateway still answers from the local list plus the cache;
            // this only refreshes the cache for next time.
            requestPeerSessionLists()
            return false
        }
        guard let namespaced = message.sessionId,
              let target = RemoteFederatedSessionID.parse(namespaced, peers: Set(activePeers.keys)) else {
            return false
        }
        switch message {
        case .subscribe:
            subscribers[namespaced, default: []].insert(downstream.id)
            // Re-asked on every downstream subscribe, even when the session
            // is already subscribed upstream: the peer answers a repeated
            // subscribe with a fresh snapshot, which is exactly what the
            // newcomer needs, and the others apply a snapshot harmlessly.
            links.sendToPeer(.subscribe(sessionId: target.sessionId), serverId: target.serverId)
        case .unsubscribe:
            removeSubscriber(downstream.id, from: namespaced)
        default:
            links.sendToPeer(message.replacingSessionId(target.sessionId), serverId: target.serverId)
        }
        return true
    }

    // MARK: - Upstream

    private func handle(_ event: FederatedPeerLinkEvent) {
        switch event {
        case .availabilityChanged:
            reconcilePeers()
        case .message(let serverId, let message):
            guard let peer = activePeers[serverId] else { return }
            switch message {
            case .sessionList(let rows):
                // Loop guard: a row the peer itself forwarded from one of
                // ITS peers already carries a serverId. Only the peer's own
                // rows are re-exported, so A↔B↔C cannot echo sessions
                // around the ring or duplicate them.
                let tagged = rows.filter { $0.serverId == nil }.map { $0.namespaced(under: peer) }
                guard peerRows[serverId] != tagged else { return }
                peerRows[serverId] = tagged
                notifySessionListChanged()
            case .sessionClosed(let sessionId):
                let namespaced = RemoteFederatedSessionID.compose(serverId: serverId, sessionId: sessionId)
                fanOut(.sessionClosed(sessionId: namespaced), to: namespaced)
                subscribers[namespaced] = nil
            default:
                guard let sessionId = message.sessionId else { return }
                let namespaced = RemoteFederatedSessionID.compose(serverId: serverId, sessionId: sessionId)
                fanOut(message.replacingSessionId(namespaced), to: namespaced)
            }
        }
    }

    private func reconcilePeers() {
        let current = Dictionary(links.sessionCarryingPeers.map { ($0.serverId, $0) }, uniquingKeysWith: { $1 })
        let previous = activePeers
        activePeers = current
        var listChanged = false
        for serverId in previous.keys where current[serverId] == nil {
            // Everything this peer was carrying is unreachable now. Its
            // rows leave the list, and every client watching one of its
            // sessions is told it closed — the same thing the peer's own
            // gateway says when a session goes away.
            if peerRows.removeValue(forKey: serverId) != nil { listChanged = true }
            let prefix = RemoteFederatedSessionID.compose(serverId: serverId, sessionId: "")
            for namespaced in subscribers.keys where namespaced.hasPrefix(prefix) {
                fanOut(.sessionClosed(sessionId: namespaced), to: namespaced)
                subscribers[namespaced] = nil
            }
        }
        for serverId in current.keys where previous[serverId] == nil {
            links.sendToPeer(.listSessions, serverId: serverId)
        }
        // A rename reaches here as a changed `name` on the same id.
        for (serverId, peer) in current where previous[serverId] != nil && previous[serverId] != peer {
            if let rows = peerRows[serverId] {
                peerRows[serverId] = rows.map { $0.retagged(under: peer) }
                listChanged = true
            }
        }
        if listChanged { notifySessionListChanged() }
        if Set(previous.keys) != Set(current.keys) { onPeerAvailabilityChanged?() }
        syncPollTimer()
    }

    private func requestPeerSessionLists() {
        let at = now()
        if let last = lastListRequestAt, at.timeIntervalSince(last) < Self.listRequestThrottle { return }
        lastListRequestAt = at
        for serverId in activePeers.keys {
            links.sendToPeer(.listSessions, serverId: serverId)
        }
    }

    /// Runs only while there is someone to tell and someone to ask.
    private func syncPollTimer() {
        let shouldRun = !downstreams.isEmpty && !activePeers.isEmpty
        if shouldRun, pollTimer == nil {
            pollTimer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(Self.listPollInterval * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.requestPeerSessionLists()
                }
            }
        } else if !shouldRun {
            pollTimer?.cancel()
            pollTimer = nil
        }
    }

    // MARK: - Fan-out

    private func fanOut(_ message: RemoteServerMessage, to namespaced: String) {
        for id in subscribers[namespaced] ?? [] {
            downstreams[id]?.send(message)
        }
    }

    private func removeSubscriber(_ id: UUID, from namespaced: String) {
        guard var ids = subscribers[namespaced], ids.remove(id) != nil else { return }
        if ids.isEmpty {
            subscribers[namespaced] = nil
            if let target = RemoteFederatedSessionID.parse(namespaced, peers: Set(activePeers.keys)) {
                links.sendToPeer(.unsubscribe(sessionId: target.sessionId), serverId: target.serverId)
            }
        } else {
            subscribers[namespaced] = ids
        }
    }

    private func notifySessionListChanged() {
        for downstream in downstreams.values { downstream.sessionListChanged() }
    }
}

private extension RemoteSessionSummary {
    /// The same row under the peer's namespace, tagged with its owner.
    func namespaced(under peer: FederatedPeerInfo) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: RemoteFederatedSessionID.compose(serverId: peer.serverId, sessionId: id),
            title: title, agentId: agentId, status: status, canDrive: canDrive, isActive: isActive,
            projectId: projectId, worktreeId: worktreeId, updatedAt: updatedAt, worktree: worktree,
            serverId: peer.serverId, serverName: peer.name)
    }

    /// An already-namespaced row with a refreshed owner name.
    func retagged(under peer: FederatedPeerInfo) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: id, title: title, agentId: agentId, status: status, canDrive: canDrive, isActive: isActive,
            projectId: projectId, worktreeId: worktreeId, updatedAt: updatedAt, worktree: worktree,
            serverId: peer.serverId, serverName: peer.name)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `FederatedSessionsProviderTests`. Expected: 12 tests pass. If `twoClientsShareOneUpstreamSubscriptionAndBothGetFrames` fails on the `.sent` ordering, check that `FakeLinks.sent.removeAll()` ran after `goOnline` (which sends `.listSessions`).

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Federation/FederatedSessionsProvider.swift AlasTests/Remote/FederatedSessionsProviderTests.swift Alas.xcodeproj
git commit -m "feat(remote): add FederatedSessionsProvider routing peer sessions through the gateway"
```

---

### Task 6: Gateway integration

**Files:**
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift` (init at 47-50, `handle` at 52, `refreshSessionList` at 357-367, `close` at 467-492)
- Test: `AlasTests/Remote/RemoteSessionGatewayTests.swift`

**Interfaces:**
- Consumes: `FederatedSessionsProvider`, `FederatedDownstream` (Task 5).
- Produces: `RemoteSessionGateway.init(provider: RemoteSessionsProvider, federation: FederatedSessionsProvider? = nil, send: @escaping (RemoteServerMessage) -> Void)`. Existing two-argument call sites keep compiling.

- [ ] **Step 1: Write the failing tests** (append inside `RemoteSessionGatewayTests`; reuse `FederatedSessionsProviderTests.FakeLinks`)

```swift
    @Test func sessionListMergesLocalAndPeerRows() async {
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "local", title: "L", agentId: "claude", status: "idle", canDrive: true)]
        let links = FederatedSessionsProviderTests.FakeLinks()
        let federation = FederatedSessionsProvider(links: links)
        var out: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider, federation: federation) { out.append($0) }
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [
            RemoteSessionSummary(id: "s1", title: "B1", agentId: "claude", status: "idle", canDrive: false)
        ]), from: "srv-b")
        // The cache update itself asks the gateway to refresh; the explicit
        // request supersedes that refresh (same generation counter) and its
        // list is what lands. Same single yield as `listSessionsEmitsSummaries`.
        await gateway.handle(.listSessions)
        await Task.yield()
        guard case .sessionList(let rows) = out.last else {
            Issue.record("expected sessionList, got \(String(describing: out.last))")
            return
        }
        #expect(rows.map(\.id) == ["local", "srv-b:s1"])
        #expect(rows.last?.serverId == "srv-b")
        #expect(links.sent(to: "srv-b").filter { $0 == .listSessions }.count >= 1)
        gateway.close()
    }

    @Test func aPeerSessionSubscribeIsRoutedAwayFromTheLocalProvider() async {
        let provider = FakeSessionsProvider()
        let links = FederatedSessionsProviderTests.FakeLinks()
        let federation = FederatedSessionsProvider(links: links)
        var out: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider, federation: federation) { out.append($0) }
        links.goOnline("srv-b", name: "Mac B")
        await gateway.handle(.subscribe(sessionId: "srv-b:s1"))
        // Not handled locally: no sessionClosed for an unknown local session.
        #expect(!out.contains(.sessionClosed(sessionId: "srv-b:s1")))
        #expect(links.sent(to: "srv-b").contains(.subscribe(sessionId: "s1")))
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        #expect(out.contains(.stopPending(sessionId: "srv-b:s1")))
        // A local id still goes to the local provider.
        await gateway.handle(.subscribe(sessionId: "nope"))
        #expect(out.contains(.sessionClosed(sessionId: "nope")))
        gateway.close()
    }

    @Test func closingTheGatewayUnsubscribesUpstream() async {
        let provider = FakeSessionsProvider()
        let links = FederatedSessionsProviderTests.FakeLinks()
        let federation = FederatedSessionsProvider(links: links)
        let gateway = RemoteSessionGateway(provider: provider, federation: federation) { _ in }
        links.goOnline("srv-b", name: "Mac B")
        await gateway.handle(.subscribe(sessionId: "srv-b:s1"))
        gateway.close()
        #expect(links.sent(to: "srv-b").contains(.unsubscribe(sessionId: "s1")))
    }

    @Test func aGatewayWithoutFederationTreatsPrefixedIdsAsLocal() async {
        let provider = FakeSessionsProvider()
        var out: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { out.append($0) }
        await gateway.handle(.subscribe(sessionId: "srv-b:s1"))
        #expect(out == [.sessionClosed(sessionId: "srv-b:s1")])
    }
```

`FakeLinks` and its `goOnline`/`receive`/`sent(to:)` helpers must be reachable from this file: they are nested in `FederatedSessionsProviderTests` at internal access, in the same test target, so `FederatedSessionsProviderTests.FakeLinks()` works.

- [ ] **Step 2: Run to verify they fail**

Run: `RemoteSessionGatewayTests`. Expected: compile error, `extra argument 'federation' in call`.

- [ ] **Step 3: Implement**

Add stored properties and the new init. `downstream` is a `var` because its
`sessionListChanged` closure captures `self`, which is only available once
every stored property is set:

```swift
    private let provider: RemoteSessionsProvider
    private let federation: FederatedSessionsProvider?
    /// This gateway's registration with `federation`; nil without one.
    private var downstream: FederatedDownstream?
    private let send: (RemoteServerMessage) -> Void
    // … existing properties …

    init(provider: RemoteSessionsProvider, federation: FederatedSessionsProvider? = nil,
         send: @escaping (RemoteServerMessage) -> Void) {
        self.provider = provider
        self.federation = federation
        self.send = send
        guard let federation else { return }
        // A peer's cached list moving refreshes this client even if it has
        // never asked for the list, which matches what `renameSession`
        // already does locally.
        let downstream = FederatedDownstream(
            send: send,
            sessionListChanged: { [weak self] in self?.refreshSessionList() })
        self.downstream = downstream
        federation.attach(downstream)
    }
```

At the top of `handle(_:)`:

```swift
    func handle(_ message: RemoteClientMessage) async {
        if let federation, let downstream, federation.route(message, from: downstream) { return }
        switch message {
```

In `refreshSessionList()`:

```swift
            let summaries = await provider.sessionSummaries() + (federation?.peerSessionSummaries ?? [])
```

At the start of `close()`:

```swift
    func close() {
        if let federation, let downstream { federation.detach(downstream) }
        self.downstream = nil
```

- [ ] **Step 4: Run to verify they pass**

Run: `RemoteSessionGatewayTests`. Expected: the 4 new tests pass; every pre-existing test still passes (they construct the gateway without `federation`).

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift AlasTests/Remote/RemoteSessionGatewayTests.swift
git commit -m "feat(remote): route peer sessions through the gateway"
```

---

### Task 7: Server and app wiring

**Files:**
- Modify: `Alas/Sources/Remote/Server/RemoteServer.swift` (properties near 25-37, `accept` at 215-297)
- Modify: `Alas/Sources/App/AppState.swift` (lazy properties near 499-530, `syncRemoteServer` at 659-737)
- Test: `AlasTests/Remote/RemoteServerIntegrationTests.swift`

**Interfaces:**
- Produces: `RemoteServer.federation: FederatedSessionsProvider?` (settable, main actor; read once per accepted connection), `AppState.remoteFederation: FederatedSessionsProvider` (lazy).

- [ ] **Step 1: Write the failing test** (append inside `RemoteServerIntegrationTests`)

```swift
    @Test func aConnectionOpenedAfterFederationIsSetSeesPeerRows() async throws {
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "local", title: "L", agentId: "claude", status: "idle", canDrive: true)]
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing, provider: provider)
        defer { server.stop() }
        let links = FederatedSessionsProviderTests.FakeLinks()
        let federation = FederatedSessionsProvider(links: links)
        server.federation = federation
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [
            RemoteSessionSummary(id: "s1", title: "B1", agentId: "claude", status: "idle", canDrive: false)
        ]), from: "srv-b")

        let code = pairing.beginPairing()
        var pairReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        pairReq.httpMethod = "POST"
        pairReq.httpBody = Data(#"{"code":"\#(code)","deviceName":"test"}"#.utf8)
        let (pairData, _) = try await URLSession.shared.data(for: pairReq)
        struct PairResp: Decodable { let token: String }
        let token = try JSONDecoder().decode(PairResp.self, from: pairData).token
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!, protocols: [token])
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.listSessions)))
        _ = try await receiveServerMessage(task)   // hello
        var list: [RemoteSessionSummary]?
        for _ in 0..<5 where list == nil {
            if case .sessionList(let rows) = try await receiveServerMessage(task) { list = rows }
        }
        #expect(list?.map(\.id) == ["local", "srv-b:s1"])
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `RemoteServerIntegrationTests`. Expected: compile error, `value of type 'RemoteServer' has no member 'federation'`.

- [ ] **Step 3: Implement the server change**

Add after `signer` (line 37):

```swift
    /// Peer-session routing handed to every gateway this server creates.
    /// Nil means clients see local sessions only. Read once per accepted
    /// connection, so setting it affects sockets opened from then on; the
    /// app sets it before `start()`.
    var federation: FederatedSessionsProvider?
```

In `accept(_:)`, next to `let provider = self.provider`:

```swift
        let provider = self.provider   // captured strongly; the server owns it for its lifetime
        let federation = self.federation
```

and:

```swift
            makeGateway: { send in
                RemoteSessionGateway(provider: provider, federation: federation, send: send)
            },
```

- [ ] **Step 4: Implement the app wiring**

In `AppState`, after `remotePeerBrowser` (line 530):

```swift
    /// Peer-session routing for this Mac's own remote clients. Lazy like
    /// `remotePeers`, which it forces: only built once a server exists.
    @ObservationIgnored
    private(set) lazy var remoteFederation: FederatedSessionsProvider = {
        let federation = FederatedSessionsProvider(links: remotePeers)
        // Connected clients learn about a peer coming or going through a
        // refreshed `hello` (its `peers` list, Task 8).
        federation.onPeerAvailabilityChanged = { [weak self] in
            self?.remoteServer?.broadcastHello()
        }
        return federation
    }()
```

In `syncRemoteServer()`, after `server.onPeerPaired = …` and before `do {`:

```swift
            // Always set, flag or no flag: with federation off no link is
            // online, so `sessionCarryingPeers` is empty and the provider
            // routes nothing. Gating here instead would need a server
            // restart on every toggle.
            server.federation = remoteFederation
```

- [ ] **Step 5: Run to verify it passes, then build**

Run: `RemoteServerIntegrationTests`. Expected: the new test passes.

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build > /tmp/alas-build.log 2>&1; grep -E "BUILD (SUCCEEDED|FAILED)|error:" /tmp/alas-build.log
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Server/RemoteServer.swift Alas/Sources/App/AppState.swift AlasTests/Remote/RemoteServerIntegrationTests.swift
git commit -m "feat(remote): wire FederatedSessionsProvider into the server and app"
```

---

### Task 8: `peers` on `hello`

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift` (`RemoteServerIdentity` at 11-23, `hello` case at 399, coding keys at 460-470, decode at 475-481, encode at 663-669, `hello(_:)` factory at 857-864)
- Modify: `Alas/Sources/Remote/Peer/RemotePeerConnection.swift:214`
- Modify: `Alas/Sources/Remote/Peer/RemotePeerManager.swift` (add `helloPeers`)
- Modify: `Alas/Sources/App/AppState.swift` (`remoteServerIdentity()` at 608-615)
- Test: `AlasTests/Remote/RemoteProtocolTests.swift`, `AlasTests/Remote/RemotePeerManagerTests.swift`

**Interfaces:**
- Produces:

```swift
struct RemoteHelloPeer: Codable, Equatable, Sendable { let serverId: String; let name: String; let state: String }
// state ∈ "online" | "unverified" | "connecting" | "offline" | "unauthorized" | "incompatible" | "identityMismatch" | "identityUnproven" | "idle"
RemoteServerIdentity.init(serverId:name:hubEnabled:federationEnabled: = false, peers: [RemoteHelloPeer] = [])
RemoteServerMessage.hello(protocolVersion:serverId:name:hubEnabled:federationEnabled: = false, peers: [RemoteHelloPeer] = [])
RemotePeerManager.helloPeers: [RemoteHelloPeer]
```

  `peers` is omitted from the JSON when empty and decodes as `[]` when absent, so every existing `hello` expectation and pre-federation client is unaffected.

- [ ] **Step 1: Write the failing tests**

In `RemoteProtocolTests`:

```swift
    @Test func helloCarriesPeersOnlyWhenThereAreAny() throws {
        let none = RemoteServerMessage.hello(RemoteServerIdentity(serverId: "s", name: "n", hubEnabled: false, federationEnabled: true))
        let noneObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(none)) as? [String: Any])
        #expect(noneObject["peers"] == nil)

        let peers = [RemoteHelloPeer(serverId: "srv-b", name: "Mac B", state: "online"),
                     RemoteHelloPeer(serverId: "srv-c", name: "Mac C", state: "offline")]
        let some = RemoteServerMessage.hello(RemoteServerIdentity(serverId: "s", name: "n", hubEnabled: false,
                                                                  federationEnabled: true, peers: peers))
        #expect(try roundTrip(some) == some)
        let someObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(some)) as? [String: Any])
        let encodedPeers = try #require(someObject["peers"] as? [[String: Any]])
        #expect(encodedPeers.map { $0["serverId"] as? String } == ["srv-b", "srv-c"])
        #expect(encodedPeers.map { $0["state"] as? String } == ["online", "offline"])

        let legacy = Data(#"{"type":"hello","protocolVersion":1,"serverId":"s","name":"n"}"#.utf8)
        #expect(try JSONDecoder().decode(RemoteServerMessage.self, from: legacy)
                == .hello(protocolVersion: 1, serverId: "s", name: "n", hubEnabled: false))
    }
```

In `RemotePeerManagerTests`:

```swift
    @Test func helloPeersReportEveryRecordWithItsLinkState() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), unverifiedPeer(), verifiedPeer(id: "p3", serverId: "srv-c")])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        try #require(links.byPeerId["p1"]).emit(.stateChanged(.online))
        try #require(links.byPeerId["p2"]).emit(.stateChanged(.online))
        try #require(links.byPeerId["p3"]).emit(.stateChanged(.identityUnproven))
        #expect(manager.helloPeers == [
            RemoteHelloPeer(serverId: "srv-a", name: "Mac A", state: "online"),
            RemoteHelloPeer(serverId: "srv-old", name: "Old Mac", state: "unverified"),
            RemoteHelloPeer(serverId: "srv-c", name: "Mac A", state: "identityUnproven"),
        ])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `RemoteProtocolTests` and `RemotePeerManagerTests`. Expected: compile errors for `RemoteHelloPeer`, `peers:`, `helloPeers`.

- [ ] **Step 3: Implement the protocol change**

```swift
/// One of the sending Mac's peers, as reported in `hello` so a client can
/// render the gateway's peer list without a separate request. `state` is
/// `"online"` only when that peer's sessions are actually reachable through
/// this Mac; `"unverified"` marks a record that connects but is not pinned
/// to a proven key, and the rest mirror `RemotePeerConnection.State`.
struct RemoteHelloPeer: Codable, Equatable, Sendable {
    let serverId: String
    let name: String
    let state: String
}

struct RemoteServerIdentity: Equatable, Sendable {
    let serverId: String
    let name: String
    let hubEnabled: Bool
    let federationEnabled: Bool
    let peers: [RemoteHelloPeer]

    init(serverId: String, name: String, hubEnabled: Bool, federationEnabled: Bool = false,
         peers: [RemoteHelloPeer] = []) {
        self.serverId = serverId
        self.name = name
        self.hubEnabled = hubEnabled
        self.federationEnabled = federationEnabled
        self.peers = peers
    }
}
```

The `hello` case:

```swift
    case hello(protocolVersion: Int, serverId: String, name: String, hubEnabled: Bool,
               federationEnabled: Bool = false, peers: [RemoteHelloPeer] = [])
```

Coding key `peers` added to the `protocolVersion, serverId, …` line. Decode:

```swift
                federationEnabled: try c.decodeIfPresent(Bool.self, forKey: .federationEnabled) ?? false,
                peers: try c.decodeIfPresent([RemoteHelloPeer].self, forKey: .peers) ?? [])
```

Encode:

```swift
        case .hello(let protocolVersion, let serverId, let name, let hubEnabled, let federationEnabled, let peers):
            // … existing five encodes …
            if !peers.isEmpty { try c.encode(peers, forKey: .peers) }
```

Factory:

```swift
            federationEnabled: identity.federationEnabled,
            peers: identity.peers)
```

`RemotePeerConnection.swift:214` becomes:

```swift
            guard case .hello(let version, let serverId, let name, _, let federationEnabled, _) = first else {
```

- [ ] **Step 4: Implement `helloPeers` and the app identity**

In `RemotePeerManager`, inside the `FederatedPeerLinks` extension from Task 4 (or a new extension):

```swift
    /// What `hello` says about this Mac's peers. Every record is listed, in
    /// store order, so a client can show a peer that exists but is not
    /// reachable; only `"online"` means its sessions come through here.
    var helloPeers: [RemoteHelloPeer] {
        peers.map { peer in
            RemoteHelloPeer(serverId: peer.serverId, name: peer.name, state: helloState(for: peer))
        }
    }

    private func helloState(for peer: RemotePeer) -> String {
        switch states[peer.id] ?? .idle {
        case .online: return peer.isVerified ? "online" : "unverified"
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .offline: return "offline"
        case .unauthorized: return "unauthorized"
        case .incompatible: return "incompatible"
        case .identityMismatch: return "identityMismatch"
        case .identityUnproven: return "identityUnproven"
        }
    }
```

A `private` member cannot live in an extension in a different file from the type unless declared there; put both in the same extension at the bottom of `RemotePeerManager.swift`.

In `AppState.remoteServerIdentity()`:

```swift
    func remoteServerIdentity() -> RemoteServerIdentity {
        RemoteServerIdentity(
            serverId: config.remote.serverId,
            name: remoteDisplayName,
            hubEnabled: config.remote.hubEnabled,
            federationEnabled: config.remote.federationEnabled,
            // Only reach for the lazy manager when a server is up and the
            // flag is on, for the same reason `syncRemotePeers` does.
            peers: config.remote.federationEnabled && remoteServer != nil ? remotePeers.helloPeers : []
        )
    }
```

Note `remoteServerIdentity()` is called from the server's `identity` closure on every socket and every `broadcastHello()`, and `remoteServer` is non-nil by then, so the guard only matters for the Settings pane calling it with the server down.

- [ ] **Step 5: Run to verify they pass**

Run: `RemoteProtocolTests`, `RemotePeerManagerTests`, `RemotePeerConnectionTests`, `RemoteServerIntegrationTests`. Expected: all pass. The existing `hello` equality expectations compile unchanged because `peers` defaults to `[]`.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Protocol/RemoteProtocol.swift Alas/Sources/Remote/Peer/RemotePeerConnection.swift Alas/Sources/Remote/Peer/RemotePeerManager.swift Alas/Sources/App/AppState.swift AlasTests/Remote/RemoteProtocolTests.swift AlasTests/Remote/RemotePeerManagerTests.swift
git commit -m "feat(remote): report peers in hello"
```

---

### Task 9: End-to-end aggregation over real Macs

**Files:**
- Create: `AlasTests/Remote/RemoteFederationAggregationTests.swift`

**Interfaces:**
- Consumes: everything above; the `Mac` harness pattern from `RemoteFederationIdentityTests` (copy it, do not share: that file's `Mac` is `private`), `FakeSessionsProvider`, `ACPSessionManager` as built in `RemoteServerIntegrationTests.makeManager()`.

Each `Mac` here differs from the identity harness in two ways: its `FakeSessionsProvider` is kept so a test can plant sessions on it, and after `peers` exists in `start()` it builds `FederatedSessionsProvider(links: peers)` and sets `server.federation`.

- [ ] **Step 1: Write the harness and the tests**

```swift
import Testing
import Foundation
@testable import Alas

/// Gateway aggregation over real loopback servers: a phone paired with A sees
/// and drives B's sessions through A, and nothing echoes around a chain.
@MainActor
struct RemoteFederationAggregationTests {
    private enum TimeoutError: Error { case timedOut }

    @MainActor
    private final class Mac {
        let serverId: String
        let name: String
        let signer: RemoteIdentityKeyProvider
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let peerStore = InMemoryPeerStore()
        let provider = FakeSessionsProvider()
        let server: RemoteServer
        private(set) var peers: RemotePeerManager!
        private(set) var federation: FederatedSessionsProvider!
        private(set) var port: UInt16 = 0
        var origin: String { "http://127.0.0.1:\(port)" }

        init(serverId: String, name: String, key: RemoteIdentityKeyProvider? = nil) {
            self.serverId = serverId
            self.name = name
            self.signer = key ?? RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
            let signer = self.signer
            self.server = RemoteServer(
                pairing: pairing,
                assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
                provider: provider,
                identity: { RemoteServerIdentity(serverId: serverId, name: name, hubEnabled: false, federationEnabled: true) },
                signer: signer)
        }

        func start() async throws {
            try server.start(port: 0)
            for _ in 0..<100 where server.port == nil { try await Task.sleep(nanoseconds: 20_000_000) }
            port = try #require(server.port)
            let serverId = self.serverId, name = self.name, signer = self.signer
            let originBox = { [weak self] in self?.origin ?? "" }
            peers = RemotePeerManager(
                store: peerStore, pairing: pairing, pairer: .live, reciprocalConfirmationTimeout: 15,
                localIdentity: {
                    RemotePeerManager.LocalIdentity(serverId: serverId, name: name, origins: [originBox()],
                                                    publicKey: signer.publicKey)
                })
            peers.onRevokeDevice = { [weak self] deviceId in self?.server.disconnectDevice(deviceId) }
            server.onPeerPaired = { [weak self] request in
                guard let self else { return }
                self.peers.notePeerPairingArrived(serverId: request.peerServerId, localDeviceId: request.localDeviceId)
                Task { @MainActor in await self.peers.handleInboundPeer(request) }
            }
            federation = FederatedSessionsProvider(links: peers)
            server.federation = federation
            peers.connectAll()
        }

        func stop() {
            peers?.disconnectAll()
            server.stop()
        }

        /// Plants a live session on this Mac and returns its id.
        func plantSession(text: String, manager: ACPSessionManager) -> String {
            let session = manager.createSession(agentId: "claude")
            session.transcript.messages = [.agent(id: UUID(), StreamingText(text))]
            provider.sessions[session.id] = session
            provider.writers.insert(session.id)
            provider.summaries.append(RemoteSessionSummary(id: session.id, title: "On \(name)", agentId: "claude",
                                                           status: "idle", canDrive: true))
            return session.id
        }
    }

    /// A paired browser client of `mac`: redeems a code over HTTP, opens the
    /// socket, and swallows the leading `hello`.
    @MainActor
    private final class Phone {
        let task: URLSessionWebSocketTask
        init(of mac: Mac) async throws {
            let code = mac.pairing.beginPairing()
            var request = URLRequest(url: URL(string: mac.origin + "/pair")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"code":"\#(code)","deviceName":"phone"}"#.utf8)
            let (data, _) = try await URLSession.shared.data(for: request)
            struct PairResp: Decodable { let token: String }
            let token = try JSONDecoder().decode(PairResp.self, from: data).token
            task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(mac.port)/ws")!, protocols: [token])
            task.resume()
            _ = try await receive()
        }
        func send(_ message: RemoteClientMessage) async throws {
            try await task.send(.data(JSONEncoder().encode(message)))
        }
        func receive() async throws -> RemoteServerMessage {
            let raw = try await task.receive()
            let payload: Data
            switch raw {
            case .data(let d): payload = d
            case .string(let s): payload = Data(s.utf8)
            @unknown default: throw TimeoutError.timedOut
            }
            return try JSONDecoder().decode(RemoteServerMessage.self, from: payload)
        }
        /// Reads frames until `matches` returns a value, or `limit` frames pass.
        func receive<T>(limit: Int = 20, _ matches: (RemoteServerMessage) -> T?) async throws -> T {
            for _ in 0..<limit {
                if let value = matches(try await receive()) { return value }
            }
            throw TimeoutError.timedOut
        }
        func close() { task.cancel(with: .goingAway, reason: nil) }
    }

    private func makeManager() throws -> ACPSessionManager {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-fed-\(UUID()).sqlite")
        return ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: try ACPSessionStore(path: url.path))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw TimeoutError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// `a` pairs with `b`; returns once both links carry sessions.
    private func pair(_ a: Mac, _ b: Mac) async throws {
        let code = b.pairing.beginPairing()
        let error = await a.peers.addPeer(code: code, origins: [b.origin])
        #expect(error == nil, "expected a clean pairing, got \(String(describing: error))")
        try await waitUntil { a.peers.sessionCarryingPeers.contains { $0.serverId == b.serverId }
                              && b.peers.sessionCarryingPeers.contains { $0.serverId == a.serverId } }
    }

    @Test func aPhoneOnASeesAndStreamsBsSessionThroughA() async throws {
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let b = Mac(serverId: "srv-b", name: "Mac B")
        try await a.start()
        try await b.start()
        defer { a.stop()
        b.stop() }
        let manager = try makeManager()
        let bSession = b.plantSession(text: "hello-from-b", manager: manager)
        try await pair(a, b)
        try await waitUntil { a.federation.peerSessionSummaries.contains { $0.id == "srv-b:\(bSession)" } }

        let phone = try await Phone(of: a)
        defer { phone.close() }
        try await phone.send(.listSessions)
        let rows = try await phone.receive { if case .sessionList(let rows) = $0 { return rows } else { return nil } }
        let row = try #require(rows.first { $0.id == "srv-b:\(bSession)" })
        #expect(row.serverId == "srv-b")
        #expect(row.serverName == "Mac B")
        #expect(row.title == "On Mac B")

        try await phone.send(.subscribe(sessionId: "srv-b:\(bSession)"))
        let snapshot = try await phone.receive { message -> [RemoteWireMessage]? in
            if case .transcriptSnapshot("srv-b:\(bSession)", _, _, let messages, _, _, _, _) = message { return messages }
            return nil
        }
        #expect(snapshot.contains { $0.text == "hello-from-b" })
    }

    @Test func driveVerbsLandOnTheHomeMacAndRefusalsComeBack() async throws {
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let b = Mac(serverId: "srv-b", name: "Mac B")
        try await a.start()
        try await b.start()
        defer { a.stop()
        b.stop() }
        let manager = try makeManager()
        let bSession = b.plantSession(text: "x", manager: manager)
        try await pair(a, b)
        let phone = try await Phone(of: a)
        defer { phone.close() }
        try await phone.send(.subscribe(sessionId: "srv-b:\(bSession)"))
        _ = try await phone.receive { if case .transcriptSnapshot = $0 { return true } else { return nil } }

        try await phone.send(.sendPrompt(sessionId: "srv-b:\(bSession)", text: "do it", attachments: [], intent: "auto"))
        try await waitUntil { b.provider.prompts.contains { $0.id == bSession && $0.text == "do it" } }
        #expect(a.provider.prompts.isEmpty)

        try await phone.send(.renameSession(sessionId: "srv-b:\(bSession)", title: "Renamed"))
        try await waitUntil { b.provider.renamed.contains { $0.id == bSession && $0.title == "Renamed" } }
        let renamed = try await phone.receive { message -> String? in
            if case .sessionRenamed("srv-b:\(bSession)", let title) = message { return title }
            return nil
        }
        #expect(renamed == "Renamed")

        // B decides who may drive. Take the lease away and the forwarded
        // prompt is refused by B, and the refusal reaches the phone.
        b.provider.writers.remove(bSession)
        try await phone.send(.sendPrompt(sessionId: "srv-b:\(bSession)", text: "again", attachments: [], intent: "auto"))
        let rejected = try await phone.receive { message -> Bool? in
            if case .promptRejected("srv-b:\(bSession)") = message { return true }
            return nil
        }
        #expect(rejected)
        #expect(!b.provider.prompts.contains { $0.text == "again" })
    }

    @Test func aChainDoesNotEchoSessionsPastOneHop() async throws {
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let b = Mac(serverId: "srv-b", name: "Mac B")
        let c = Mac(serverId: "srv-c", name: "Mac C")
        try await a.start()
        try await b.start()
        try await c.start()
        defer { a.stop()
        b.stop()
        c.stop() }
        let manager = try makeManager()
        let aSession = a.plantSession(text: "a", manager: manager)
        let cSession = c.plantSession(text: "c", manager: manager)
        try await pair(a, b)
        try await pair(b, c)
        // B sees both neighbours.
        try await waitUntil { b.federation.peerSessionSummaries.map(\.id).sorted()
                              == ["srv-a:\(aSession)", "srv-c:\(cSession)"].sorted() }
        // Give B's list (which now carries C's row) time to reach A, then
        // check A never adopted it, and that A's own row did not come back
        // to A through B.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(a.federation.peerSessionSummaries.isEmpty)
        #expect(!c.federation.peerSessionSummaries.contains { $0.id.hasPrefix("srv-b:srv-a:") })
        #expect(c.federation.peerSessionSummaries.isEmpty)
    }

    @Test func aPeerGoingAwayClosesItsSessionsForThePhone() async throws {
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let b = Mac(serverId: "srv-b", name: "Mac B")
        try await a.start()
        try await b.start()
        defer { a.stop() }
        let manager = try makeManager()
        let bSession = b.plantSession(text: "x", manager: manager)
        try await pair(a, b)
        let phone = try await Phone(of: a)
        defer { phone.close() }
        try await phone.send(.subscribe(sessionId: "srv-b:\(bSession)"))
        _ = try await phone.receive { if case .transcriptSnapshot = $0 { return true } else { return nil } }

        b.stop()
        let closed = try await phone.receive(limit: 40) { message -> Bool? in
            if case .sessionClosed("srv-b:\(bSession)") = message { return true }
            return nil
        }
        #expect(closed)
        try await waitUntil { a.federation.peerSessionSummaries.isEmpty }
        try await phone.send(.listSessions)
        let rows = try await phone.receive { if case .sessionList(let rows) = $0 { return rows } else { return nil } }
        #expect(!rows.contains { $0.serverId == "srv-b" })
    }

    @Test func anUnverifiedPeerNeverCarriesSessions() async throws {
        // A Mac with no identity key pairs but is never pinned; its record
        // on A stays unverified, so A must not surface its sessions even
        // though the link itself is online.
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let keyless = Mac(serverId: "srv-k", name: "Keyless",
                          key: RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore(writable: false)))
        try await a.start()
        try await keyless.start()
        defer { a.stop()
        keyless.stop() }
        let manager = try makeManager()
        _ = keyless.plantSession(text: "secret", manager: manager)
        let code = keyless.pairing.beginPairing()
        _ = await a.peers.addPeer(code: code, origins: [keyless.origin])
        try await waitUntil { a.peers.states.values.contains(.online) }
        let record = try #require(a.peers.peers.first { $0.serverId == "srv-k" })
        #expect(!record.isVerified)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(a.peers.sessionCarryingPeers.isEmpty)
        #expect(a.federation.peerSessionSummaries.isEmpty)
    }
}
```

If `RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore(writable: false))` does not yield an empty `publicKey`, look at `RemoteFederationIdentityTests.pairingWithAMacThatOffersNoKeyLeavesAnUnverifiedRecord` and copy exactly how that test builds its keyless Mac.

- [ ] **Step 2: Run `xcodegen`, then run**

Run: `RemoteFederationAggregationTests`. Expected: 5 tests pass, each in well under 20 s. If the suite is flaky on `receive(limit:)`, raise the limit rather than adding sleeps: the phone can legitimately receive several list refreshes and queue/config frames before the one it wants.

- [ ] **Step 3: Commit**

```bash
git add AlasTests/Remote/RemoteFederationAggregationTests.swift Alas.xcodeproj
git commit -m "test(remote): cover gateway aggregation over real peer links"
```

---

### Task 10: Verification and hand-off

- [ ] **Step 1: Run every suite this plan touched**

`RemoteProtocolTests`, `RemoteFederatedSessionIDTests`, `RemoteMessageSessionScopeTests`, `RemotePeerManagerTests`, `FederatedSessionsProviderTests`, `RemoteSessionGatewayTests`, `RemotePeerConnectionTests`, `RemoteServerIntegrationTests`, `RemoteFederationIdentityTests`, `RemoteFederationAggregationTests`. Each can go in one `xcodebuild` call with repeated `-only-testing` flags. Confirm every new suite appears in the log with its own `✔ Suite` line.

- [ ] **Step 2: Build the app**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build > /tmp/alas-build.log 2>&1; grep -E "BUILD (SUCCEEDED|FAILED)|error:" /tmp/alas-build.log
```

- [ ] **Step 3: Manual check on two Macs (or two builds on one Mac with different config dirs)**

1. Federation on both, paired and verified (Settings → Remote → Peers shows the peer without "unverified").
2. Open the web client against Mac A. Its session list contains Mac B's sessions; the JSON in DevTools shows `serverId`/`serverName` on those rows and ids of the form `<uuid>:<id>`.
3. Open one of B's sessions from A's client. The transcript streams; sending a prompt runs on B; B's native window shows the prompt.
4. Quit Alas on B. A's client gets `sessionClosed` for that session and the next list omits B's rows. Relaunch B; within about 15 s the rows are back.
5. Toggle federation off on A. Rows disappear; toggle on; rows return.

- [ ] **Step 4: Open the PR against `main`**

Title: `feat(remote): Mac-to-Mac federation, phase 3a (gateway aggregation)`. Body: what a client of a gateway now sees, the three invariants (verified-only, one home Mac, loop guard), the known fan-out limitation, and `Closes #1408`. Then shepherd it with `/lassie`.

## Follow-on

- **Request-scoped replies fan out.** A peer's reply to one gateway's request (`promptRejected`, `queueEditRestored`, file results) reaches every gateway subscribed to that session. Fixing it needs a request-to-downstream correlation the wire does not carry today; revisit if it shows up in practice.
- **Shared lease per gateway.** All of a gateway's clients drive a peer session under one device credential on the peer, so `canDrive` is per gateway, not per phone. Documented in the design; a per-phone lease would need the phone's identity to travel with the forwarded verb.
- **Phase 3b (#1409):** the native sidebar consumes `remoteFederation.peerSessionSummaries` and the forwarded frames; needs a native subscriber that is not a `RemoteSessionGateway`.
- **Phase 4 (#1410):** web client grouping by `serverId`/`serverName` and badge counts from the gateway's pushed list; `hello.peers` is already there for it.
