# Remote Web New Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a paired RemoteWeb client create a new empty ACP session by choosing a worktree and ACP-capable agent, while the Mac app opens the matching ACP tab and the phone lands in the transcript.

**Architecture:** Extend the existing authenticated WebSocket protocol and `RemoteSessionGateway` with worktree/agent metadata and create-session messages. `AppState` remains the production provider for app state changes: it validates visible worktrees and enabled ACP agents, creates the ACP session, activates the native tab, starts attach, and returns a normal remote session summary. RemoteWeb adds a compact `+ New` sheet that asks for metadata over the socket, submits creation, then opens and subscribes to the created session.

**Tech Stack:** Swift 5.9, SwiftUI app state, Swift Testing, local WebSocket protocol, vanilla HTML/CSS/JavaScript RemoteWeb assets.

---

## File Structure

- `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift`
  - Add `RemoteWorktreeOption`, `RemoteAgentOption`, and `RemoteCreateSessionResult`.
- `Alas/Sources/Remote/Protocol/RemoteProtocol.swift`
  - Add client/server message cases and Codable branches.
- `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift`
  - Extend provider API for worktree/agent lists and session creation.
- `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift`
  - Route new messages and send success/failure responses.
- `Alas/Sources/App/AppState.swift`
  - Implement provider methods using existing project, agent, ACP manager, and tab APIs.
- `Alas/Resources/RemoteWeb/index.html`
  - Add `+ New` button and create-session sheet markup.
- `Alas/Resources/RemoteWeb/app.js`
  - Add create-session state, message handlers, sheet rendering, and success flow.
- `Alas/Resources/RemoteWeb/style.css`
  - Add compact header button and sheet/list/search styling.
- `AlasTests/Remote/RemoteProtocolTests.swift`
  - Add protocol round-trip tests.
- `AlasTests/Remote/RemoteSessionGatewayTests.swift`
  - Extend fake provider and gateway behavior tests.
- `AlasTests/Remote/RemoteAppStateAccessTests.swift`
  - Add production AppState creation tests.
- `AlasTests/Remote/RemoteWebAssetTests.swift`
  - Assert bundled web assets include the new controls/message strings.

## Task 1: Protocol Models And Codable Messages

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift`
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift`
- Test: `AlasTests/Remote/RemoteProtocolTests.swift`

- [ ] **Step 1: Add failing protocol tests**

Add tests to `AlasTests/Remote/RemoteProtocolTests.swift`:

```swift
@Test func worktreeOptionRoundTrips() throws {
    let option = RemoteWorktreeOption(
        id: "wt1",
        projectName: "alas",
        worktreeName: "feature-a",
        branch: "nacho/feature-a",
        path: "/tmp/alas-feature-a",
        metricsAvailable: true,
        comparisonRef: "origin/main",
        commitCount: 2,
        changedFileCount: 3,
        addedLines: 10,
        deletedLines: 4,
        conflictCount: 1
    )
    #expect(try roundTrip(option) == option)
}

@Test func agentOptionRoundTrips() throws {
    let option = RemoteAgentOption(id: "claude", name: "Claude", isDefault: true)
    #expect(try roundTrip(option) == option)
}

@Test func clientCreationMessagesRoundTrip() throws {
    #expect(try roundTrip(RemoteClientMessage.listWorktrees) == .listWorktrees)
    #expect(try roundTrip(RemoteClientMessage.listAgents) == .listAgents)
    #expect(
        try roundTrip(RemoteClientMessage.createSession(worktreeId: "wt1", agentId: "claude"))
            == .createSession(worktreeId: "wt1", agentId: "claude")
    )
}

@Test func clientCreationMessagesDecode() throws {
    let worktrees = try JSONDecoder().decode(
        RemoteClientMessage.self,
        from: Data(#"{"type":"listWorktrees"}"#.utf8)
    )
    #expect(worktrees == .listWorktrees)

    let agents = try JSONDecoder().decode(
        RemoteClientMessage.self,
        from: Data(#"{"type":"listAgents"}"#.utf8)
    )
    #expect(agents == .listAgents)

    let create = try JSONDecoder().decode(
        RemoteClientMessage.self,
        from: Data(#"{"type":"createSession","worktreeId":"wt1","agentId":"claude"}"#.utf8)
    )
    #expect(create == .createSession(worktreeId: "wt1", agentId: "claude"))
}

@Test func serverCreationMessagesRoundTrip() throws {
    let worktree = RemoteWorktreeOption(
        id: "wt1",
        projectName: "alas",
        worktreeName: "feature-a",
        branch: "nacho/feature-a",
        path: "/tmp/alas-feature-a",
        metricsAvailable: false,
        comparisonRef: nil,
        commitCount: 0,
        changedFileCount: 0,
        addedLines: 0,
        deletedLines: 0,
        conflictCount: 0
    )
    let agent = RemoteAgentOption(id: "claude", name: "Claude", isDefault: true)
    let session = RemoteSessionSummary(
        id: "s1",
        title: "New session",
        agentId: "claude",
        status: "idle",
        canDrive: true
    )

    #expect(try roundTrip(RemoteServerMessage.worktreeList(worktrees: [worktree])) == .worktreeList(worktrees: [worktree]))
    #expect(try roundTrip(RemoteServerMessage.agentList(agents: [agent])) == .agentList(agents: [agent]))
    #expect(try roundTrip(RemoteServerMessage.sessionCreated(session: session)) == .sessionCreated(session: session))
    #expect(try roundTrip(RemoteServerMessage.createSessionFailed(message: "Could not create session.")) == .createSessionFailed(message: "Could not create session."))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteProtocolTests test
```

Expected: build fails because `RemoteWorktreeOption`, `RemoteAgentOption`, and the new message cases do not exist.

- [ ] **Step 3: Add wire models**

In `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift`, add after `RemoteWorktreeSummary`:

```swift
struct RemoteWorktreeOption: Codable, Equatable, Sendable {
    let id: String
    let projectName: String
    let worktreeName: String
    let branch: String
    let path: String
    let metricsAvailable: Bool
    let comparisonRef: String?
    let commitCount: Int
    let changedFileCount: Int
    let addedLines: Int
    let deletedLines: Int
    let conflictCount: Int
}

struct RemoteAgentOption: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}

enum RemoteCreateSessionResult: Equatable, Sendable {
    case success(RemoteSessionSummary)
    case failure(String)
}
```

- [ ] **Step 4: Add client message cases**

In `RemoteClientMessage`, add:

```swift
case listWorktrees
case listAgents
case createSession(worktreeId: String, agentId: String)
```

Extend the `CodingKeys` enum with:

```swift
case worktreeId, agentId
```

Extend `init(from:)`:

```swift
case "listWorktrees":
    self = .listWorktrees
case "listAgents":
    self = .listAgents
case "createSession":
    self = .createSession(
        worktreeId: try c.decode(String.self, forKey: .worktreeId),
        agentId: try c.decode(String.self, forKey: .agentId)
    )
```

Extend `encode(to:)`:

```swift
case .listWorktrees:
    try c.encode("listWorktrees", forKey: .type)
case .listAgents:
    try c.encode("listAgents", forKey: .type)
case .createSession(let worktreeId, let agentId):
    try c.encode("createSession", forKey: .type)
    try c.encode(worktreeId, forKey: .worktreeId)
    try c.encode(agentId, forKey: .agentId)
```

- [ ] **Step 5: Add server message cases**

In `RemoteServerMessage`, add:

```swift
case worktreeList(worktrees: [RemoteWorktreeOption])
case agentList(agents: [RemoteAgentOption])
case sessionCreated(session: RemoteSessionSummary)
case createSessionFailed(message: String)
```

Extend server `CodingKeys` with:

```swift
case worktrees, agents, session
```

Extend server `init(from:)`:

```swift
case "worktreeList":
    self = .worktreeList(worktrees: try c.decode([RemoteWorktreeOption].self, forKey: .worktrees))
case "agentList":
    self = .agentList(agents: try c.decode([RemoteAgentOption].self, forKey: .agents))
case "sessionCreated":
    self = .sessionCreated(session: try c.decode(RemoteSessionSummary.self, forKey: .session))
case "createSessionFailed":
    self = .createSessionFailed(message: try c.decode(String.self, forKey: .message))
```

Extend server `encode(to:)`:

```swift
case .worktreeList(let worktrees):
    try c.encode("worktreeList", forKey: .type)
    try c.encode(worktrees, forKey: .worktrees)
case .agentList(let agents):
    try c.encode("agentList", forKey: .type)
    try c.encode(agents, forKey: .agents)
case .sessionCreated(let session):
    try c.encode("sessionCreated", forKey: .type)
    try c.encode(session, forKey: .session)
case .createSessionFailed(let message):
    try c.encode("createSessionFailed", forKey: .type)
    try c.encode(message, forKey: .message)
```

- [ ] **Step 6: Run protocol tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteProtocolTests test
```

Expected: `RemoteProtocolTests` pass.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift Alas/Sources/Remote/Protocol/RemoteProtocol.swift AlasTests/Remote/RemoteProtocolTests.swift
git commit -m "Add remote session creation protocol"
```

## Task 2: Gateway And Provider Routing

**Files:**
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift`
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift`
- Test: `AlasTests/Remote/RemoteSessionGatewayTests.swift`

- [ ] **Step 1: Add failing gateway tests and fake-provider fields**

Extend `FakeSessionsProvider` in `AlasTests/Remote/RemoteSessionGatewayTests.swift`:

```swift
var worktrees: [RemoteWorktreeOption] = []
var agents: [RemoteAgentOption] = []
var createResults: [String: RemoteCreateSessionResult] = [:]
var remoteWorktreesCallCount = 0
var remoteAgentsCallCount = 0
var createRequests: [(worktreeId: String, agentId: String)] = []
```

Add provider methods to the fake:

```swift
func remoteWorktrees() async -> [RemoteWorktreeOption] {
    remoteWorktreesCallCount += 1
    return worktrees
}

func remoteAgents() -> [RemoteAgentOption] {
    remoteAgentsCallCount += 1
    return agents
}

func createRemoteSession(worktreeId: String, agentId: String) async -> RemoteCreateSessionResult {
    createRequests.append((worktreeId, agentId))
    return createResults["\(worktreeId)|\(agentId)"] ?? .failure("Could not create session.")
}
```

Add tests:

```swift
@Test func listWorktreesEmitsWorktreeList() async {
    let provider = FakeSessionsProvider()
    provider.worktrees = [
        RemoteWorktreeOption(
            id: "wt1",
            projectName: "alas",
            worktreeName: "feature-a",
            branch: "nacho/feature-a",
            path: "/tmp/alas-feature-a",
            metricsAvailable: false,
            comparisonRef: nil,
            commitCount: 0,
            changedFileCount: 0,
            addedLines: 0,
            deletedLines: 0,
            conflictCount: 0
        )
    ]
    var sent: [RemoteServerMessage] = []
    let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

    await gw.handle(.listWorktrees)
    await Task.yield()

    #expect(provider.remoteWorktreesCallCount == 1)
    #expect(sent == [.worktreeList(worktrees: provider.worktrees)])
}

@Test func listAgentsEmitsAgentList() async {
    let provider = FakeSessionsProvider()
    provider.agents = [RemoteAgentOption(id: "claude", name: "Claude", isDefault: true)]
    var sent: [RemoteServerMessage] = []
    let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

    await gw.handle(.listAgents)

    #expect(provider.remoteAgentsCallCount == 1)
    #expect(sent == [.agentList(agents: provider.agents)])
}

@Test func createSessionEmitsCreatedSession() async {
    let provider = FakeSessionsProvider()
    let summary = RemoteSessionSummary(id: "s1", title: "New session", agentId: "claude", status: "idle", canDrive: true)
    provider.createResults["wt1|claude"] = .success(summary)
    var sent: [RemoteServerMessage] = []
    let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

    await gw.handle(.createSession(worktreeId: "wt1", agentId: "claude"))

    #expect(provider.createRequests.count == 1)
    #expect(provider.createRequests.first?.worktreeId == "wt1")
    #expect(provider.createRequests.first?.agentId == "claude")
    #expect(sent == [.sessionCreated(session: summary)])
}

@Test func createSessionEmitsFailure() async {
    let provider = FakeSessionsProvider()
    provider.createResults["missing|claude"] = .failure("Worktree is no longer available.")
    var sent: [RemoteServerMessage] = []
    let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

    await gw.handle(.createSession(worktreeId: "missing", agentId: "claude"))

    #expect(sent == [.createSessionFailed(message: "Worktree is no longer available.")])
}
```

- [ ] **Step 2: Run gateway tests to verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteSessionGatewayTests test
```

Expected: compile fails because `RemoteSessionsProvider` does not define the new methods and gateway does not handle the new messages.

- [ ] **Step 3: Extend provider protocol**

In `RemoteSessionsProvider.swift`, add:

```swift
func remoteWorktrees() async -> [RemoteWorktreeOption]
func remoteAgents() -> [RemoteAgentOption]
func createRemoteSession(worktreeId: String, agentId: String) async -> RemoteCreateSessionResult
```

- [ ] **Step 4: Route gateway messages**

In `RemoteSessionGateway.handle(_:)`, add cases near `listSessions`:

```swift
case .listWorktrees:
    let worktrees = await provider.remoteWorktrees()
    send(.worktreeList(worktrees: worktrees))
case .listAgents:
    send(.agentList(agents: provider.remoteAgents()))
case .createSession(let worktreeId, let agentId):
    let result = await provider.createRemoteSession(worktreeId: worktreeId, agentId: agentId)
    switch result {
    case .success(let summary):
        send(.sessionCreated(session: summary))
        refreshSessionList()
    case .failure(let message):
        send(.createSessionFailed(message: message))
    }
```

- [ ] **Step 5: Run gateway tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteSessionGatewayTests test
```

Expected: `RemoteSessionGatewayTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift AlasTests/Remote/RemoteSessionGatewayTests.swift
git commit -m "Route remote session creation messages"
```

## Task 3: AppState Remote Creation

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/Remote/RemoteAppStateAccessTests.swift`

- [ ] **Step 1: Add failing AppState tests**

Add helper assertions near the existing helpers in `RemoteAppStateAccessTests`:

```swift
private func firstACPTab(in state: AppState, worktreeId: String) -> ACPSessionTabState? {
    state.tabs.tabs(forWorktree: worktreeId).compactMap { tab in
        if case .acpSession(let session) = tab { return session }
        return nil
    }.first
}
```

Add tests:

```swift
@Test func remoteWorktreesIncludeVisibleProjectWorktrees() async throws {
    let state = makeRemoteRenameState()
    let worktreeId = try #require(state.selectedWorktreeId)

    let worktrees = await state.remoteWorktrees()

    #expect(worktrees.contains { $0.id == worktreeId })
    #expect(worktrees.first { $0.id == worktreeId }?.projectName == "test")
}

@Test func remoteAgentsIncludeEnabledACPCapableAgentsOnly() throws {
    let state = makeRemoteRenameState()
    let agent = AgentDefinition(
        id: "test-agent",
        displayName: "Test Agent",
        binary: "test-agent",
        binaryOverride: nil,
        promptModeArgs: [],
        bypassPermissionsFlag: nil,
        extraTerminalArgs: nil,
        isBuiltin: false,
        isEnabled: true,
        builtinLogoAssetName: nil
    )
    state.agentRegistry = AgentRegistry(builtinState: [:], customs: [agent], installedIds: ["test-agent"])

    let agents = state.remoteAgents()

    #expect(agents == [RemoteAgentOption(id: "test-agent", name: "Test Agent", isDefault: true)])
}

@Test func createRemoteSessionSelectsWorktreeAppendsTabAndReturnsSummary() async throws {
    var cleanupWorktreeId: String?
    defer {
        if let cleanupWorktreeId {
            cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
        }
    }

    let state = makeRemoteRenameState()
    let worktreeId = try #require(state.selectedWorktreeId)
    cleanupWorktreeId = worktreeId
    let result = await state.createRemoteSession(worktreeId: worktreeId, agentId: "test-agent")

    guard case .success(let summary) = result else {
        Issue.record("expected success, got \(result)")
        return
    }
    #expect(summary.agentId == "test-agent")
    #expect(summary.title == "New session")
    #expect(summary.worktree?.worktreeName != nil)
    #expect(state.selectedWorktreeId == worktreeId)
    let tab = try #require(firstACPTab(in: state, worktreeId: worktreeId))
    #expect(tab.sessionId == summary.id)
    #expect(state.tabs.activeTabId(forWorktree: worktreeId) == tab.id)
    let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
    #expect(manager.liveSession(for: summary.id) != nil)
}

@Test func createRemoteSessionRejectsMissingWorktree() async throws {
    let state = makeRemoteRenameState()

    let result = await state.createRemoteSession(worktreeId: "missing", agentId: "test-agent")

    #expect(result == .failure("Worktree is no longer available."))
}

@Test func createRemoteSessionRejectsMissingAgent() async throws {
    let state = makeRemoteRenameState()
    let worktreeId = try #require(state.selectedWorktreeId)

    let result = await state.createRemoteSession(worktreeId: worktreeId, agentId: "missing")

    #expect(result == .failure("Agent is no longer available."))
}
```

- [ ] **Step 2: Run AppState tests to verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteAppStateAccessTests test
```

Expected: compile fails because `AppState` does not yet implement provider methods.

- [ ] **Step 3: Add helper mappers in AppState remote extension**

Inside the `extension AppState: RemoteSessionsProvider` block, add:

```swift
private func remoteWorktreeOption(project: ProjectConfig, worktree: Worktree) async -> RemoteWorktreeOption {
    let summary = await remoteWorktreeSummary(project: project, worktree: worktree)
    return RemoteWorktreeOption(
        id: worktree.id,
        projectName: summary.projectName,
        worktreeName: summary.worktreeName,
        branch: summary.branch,
        path: summary.path,
        metricsAvailable: summary.metricsAvailable,
        comparisonRef: summary.comparisonRef,
        commitCount: summary.commitCount,
        changedFileCount: summary.changedFileCount,
        addedLines: summary.addedLines,
        deletedLines: summary.deletedLines,
        conflictCount: summary.conflictCount
    )
}

private func remoteSessionSummary(
    session: ACPSession,
    manager: ACPSessionManager,
    worktreeSummary: RemoteWorktreeSummary?
) -> RemoteSessionSummary {
    let state = manager.runners[session.id]?.session.transcript.streamingState
    return RemoteSessionSummary(
        id: session.id,
        title: session.title,
        agentId: session.agentId,
        status: state.map(RemoteSessionGateway.stateString) ?? RemoteSessionGateway.stateString(session.transcript.streamingState),
        canDrive: manager.isWriter(for: session.id),
        worktree: worktreeSummary
    )
}
```

- [ ] **Step 4: Implement worktree and agent lists**

Inside the same extension, add:

```swift
func remoteWorktrees() async -> [RemoteWorktreeOption] {
    var out: [RemoteWorktreeOption] = []
    for project in projects {
        for worktree in projectsManager.visibleWorktrees(projectId: project.id) {
            switch projectsManager.operationState(for: worktree.id) {
            case .deleting, .deleteFailed, .createFailed:
                continue
            case .creating, nil:
                out.append(await remoteWorktreeOption(project: project, worktree: worktree))
            }
        }
    }
    return out
}

func remoteAgents() -> [RemoteAgentOption] {
    let acpIds = Set(ACPLaunchCatalog.specs.map(\.agentID))
    let enabled = agentRegistry.enabled().filter { acpIds.contains($0.id) }
    return enabled.enumerated().map { index, agent in
        RemoteAgentOption(
            id: agent.id,
            name: agent.displayName,
            isDefault: index == 0
        )
    }
}
```

- [ ] **Step 5: Implement remote creation**

Inside the same extension, add:

```swift
func createRemoteSession(worktreeId: String, agentId: String) async -> RemoteCreateSessionResult {
    guard let resolved = projectAndWorktree(withWorktreeId: worktreeId),
          projectsManager.visibleWorktrees(projectId: resolved.project.id).contains(where: { $0.id == worktreeId })
    else {
        return .failure("Worktree is no longer available.")
    }
    switch projectsManager.operationState(for: worktreeId) {
    case .creating, .deleting, .createFailed:
        return .failure("Worktree is no longer available.")
    case nil, .deleteFailed:
        break
    }

    let acpIds = Set(ACPLaunchCatalog.specs.map(\.agentID))
    guard let agent = agentRegistry.enabled().first(where: { $0.id == agentId }),
          acpIds.contains(agent.id)
    else {
        return .failure("Agent is no longer available.")
    }

    guard let manager = acpManager(for: resolved.worktree) else {
        return .failure("Could not create session.")
    }

    let session = manager.createSession(agentId: agent.id, autoRunDefault: config.harness.acpAutoRunByDefault)
    selectedWorktreeId = resolved.worktree.id
    let state = ACPSessionTabState(sessionId: session.id, title: session.title)
    _ = tabs.append(acpSession: state, to: resolved.worktree.id)

    Task { @MainActor [weak manager] in
        await manager?.attach(to: session.id, freshlyCreated: true)
    }

    let worktreeSummary = await remoteWorktreeSummary(project: resolved.project, worktree: resolved.worktree)
    return .success(remoteSessionSummary(session: session, manager: manager, worktreeSummary: worktreeSummary))
}
```

- [ ] **Step 6: Refactor `sessionSummaries()` to reuse summary helper**

Replace the current manual `RemoteSessionSummary(...)` construction in `sessionSummaries()` with:

```swift
if let session = mgr.liveSession(for: row.id) {
    out.append(remoteSessionSummary(session: session, manager: mgr, worktreeSummary: worktreeSummary))
} else {
    out.append(RemoteSessionSummary(
        id: row.id,
        title: row.title,
        agentId: row.agentId,
        status: "idle",
        canDrive: mgr.isWriter(for: row.id),
        worktree: worktreeSummary
    ))
}
```

- [ ] **Step 7: Run AppState remote tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteAppStateAccessTests test
```

Expected: `RemoteAppStateAccessTests` pass. These tests assert creation, selection, tab state, and returned summaries; they do not assert final runner readiness because the test agent may not launch a real adapter.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/App/AppState.swift AlasTests/Remote/RemoteAppStateAccessTests.swift
git commit -m "Create ACP sessions from remote web requests"
```

## Task 4: RemoteWeb Create Session UI

**Files:**
- Modify: `Alas/Resources/RemoteWeb/index.html`
- Modify: `Alas/Resources/RemoteWeb/app.js`
- Modify: `Alas/Resources/RemoteWeb/style.css`
- Test: `AlasTests/Remote/RemoteWebAssetTests.swift`

- [ ] **Step 1: Add failing asset tests**

In `RemoteWebAssetTests.swift`, add:

```swift
@Test func remoteWebIncludesNewSessionControls() throws {
    let html = try remoteWebAsset("index.html")
    #expect(html.contains(#"id="new-session""#))
    #expect(html.contains(#"id="new-session-sheet""#))
    #expect(html.contains(#"id="worktree-search""#))
}

@Test func remoteWebIncludesNewSessionMessageTypes() throws {
    let js = try remoteWebAsset("app.js")
    #expect(js.contains(#"type: "listWorktrees""#))
    #expect(js.contains(#"type: "listAgents""#))
    #expect(js.contains(#"type: "createSession""#))
    #expect(js.contains(#"case "worktreeList""#))
    #expect(js.contains(#"case "agentList""#))
    #expect(js.contains(#"case "sessionCreated""#))
    #expect(js.contains(#"case "createSessionFailed""#))
}
```

Use the existing `asset(_:)` helper in `RemoteWebAssetTests.swift`; do not add a `Bundle.module` helper.

- [ ] **Step 2: Run asset tests to verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWebAssetTests test
```

Expected: tests fail because the controls and message strings are absent.

- [ ] **Step 3: Add HTML controls**

In `index.html`, add a `+ New` button in the header before the status chip:

```html
<button id="new-session" aria-label="New session">+ New</button>
```

Add a sheet before the existing `rename-sheet`:

```html
<div id="new-session-sheet" class="sheet hidden" role="dialog" aria-modal="true" aria-labelledby="new-session-title">
  <div class="sheet-card create-sheet">
    <p id="new-session-title" class="sheet-title">New session</p>
    <div id="create-error" class="sheet-error hidden"></div>
    <div id="worktree-step">
      <input id="worktree-search" class="sheet-input" type="search" autocomplete="off" placeholder="Search worktrees" aria-label="Search worktrees" />
      <div id="worktree-list" class="create-list"></div>
    </div>
    <div id="agent-step" class="hidden">
      <div id="agent-list" class="create-list"></div>
    </div>
    <div class="create-actions">
      <button id="create-back" class="sheet-close hidden">Back</button>
      <button id="create-next" class="btn-submit" disabled>Next</button>
      <button id="create-cancel" class="sheet-close">Cancel</button>
    </div>
  </div>
</div>
```

Increment the `app.js` cache-busting query version in `index.html`.

- [ ] **Step 4: Add JS state and message handlers**

Near other globals in `app.js`, add:

```javascript
let createState = {
  open: false,
  step: "worktree",
  worktrees: [],
  agents: [],
  selectedWorktreeId: null,
  selectedAgentId: null,
  filter: "",
  busy: false,
  error: ""
};
```

In `handle(msg)`, add:

```javascript
case "worktreeList":
  createState.worktrees = msg.worktrees || [];
  renderCreateSheet();
  break;
case "agentList":
  createState.agents = msg.agents || [];
  if (!createState.selectedAgentId) {
    const preferred = createState.agents.find(a => a.isDefault) || createState.agents[0];
    createState.selectedAgentId = preferred ? preferred.id : null;
  }
  renderCreateSheet();
  break;
case "sessionCreated":
  applyCreatedSession(msg.session);
  break;
case "createSessionFailed":
  createState.busy = false;
  createState.error = msg.message || "Could not create session.";
  renderCreateSheet();
  break;
```

- [ ] **Step 5: Add JS create-sheet functions**

Add functions before the event binding section:

```javascript
function showCreateSheet() {
  createState = {
    open: true,
    step: "worktree",
    worktrees: [],
    agents: [],
    selectedWorktreeId: null,
    selectedAgentId: null,
    filter: "",
    busy: false,
    error: ""
  };
  $("new-session-sheet").classList.remove("hidden");
  send({ type: "listWorktrees" });
  send({ type: "listAgents" });
  renderCreateSheet();
  setTimeout(() => $("worktree-search") && $("worktree-search").focus(), 0);
}

function hideCreateSheet() {
  createState.open = false;
  $("new-session-sheet").classList.add("hidden");
}

function visibleCreateWorktrees() {
  const q = createState.filter.trim().toLowerCase();
  if (!q) return createState.worktrees;
  return createState.worktrees.filter(w => {
    return [w.projectName, w.worktreeName, w.branch, w.path]
      .filter(Boolean)
      .some(value => value.toLowerCase().includes(q));
  });
}

function renderCreateSheet() {
  if (!createState.open) return;
  $("create-error").textContent = createState.error;
  $("create-error").classList.toggle("hidden", !createState.error);
  $("worktree-step").classList.toggle("hidden", createState.step !== "worktree");
  $("agent-step").classList.toggle("hidden", createState.step !== "agent");
  $("create-back").classList.toggle("hidden", createState.step === "worktree");
  $("create-next").textContent = createState.step === "worktree" ? "Next" : (createState.busy ? "Creating..." : "Create");
  $("create-next").disabled = createState.busy
    || (createState.step === "worktree" && !createState.selectedWorktreeId)
    || (createState.step === "agent" && !createState.selectedAgentId);
  renderCreateWorktrees();
  renderCreateAgents();
}

function renderCreateWorktrees() {
  const list = $("worktree-list");
  if (!list) return;
  list.innerHTML = "";
  const rows = visibleCreateWorktrees();
  if (!rows.length) {
    list.append(el("div", "create-empty", createState.worktrees.length ? "No matching worktrees" : "No worktrees available"));
    return;
  }
  rows.forEach(w => {
    const row = el("button", "create-row");
    row.type = "button";
    row.classList.toggle("is-selected", w.id === createState.selectedWorktreeId);
    row.onclick = () => {
      createState.selectedWorktreeId = w.id;
      createState.error = "";
      renderCreateSheet();
    };
    const title = el("div", "create-row-title", `${w.projectName} / ${w.worktreeName}`);
    const detail = el("div", "create-row-detail", w.branch || w.path || "");
    const meta = el("div", "create-row-meta", createWorktreeMeta(w));
    row.append(title, detail, meta);
    list.append(row);
  });
}

function createWorktreeMeta(w) {
  if (!w.metricsAvailable) return "changes unavailable";
  const parts = [];
  if (w.commitCount > 0) parts.push(plural(w.commitCount, "commit"));
  if (w.conflictCount > 0) parts.push(plural(w.conflictCount, "conflict"));
  if (w.changedFileCount > 0) parts.push(plural(w.changedFileCount, "file"));
  if (w.addedLines > 0 || w.deletedLines > 0) parts.push(`+${w.addedLines} -${w.deletedLines}`);
  return parts.length ? parts.join(" · ") : "clean";
}

function renderCreateAgents() {
  const list = $("agent-list");
  if (!list) return;
  list.innerHTML = "";
  if (!createState.agents.length) {
    list.append(el("div", "create-empty", "No ACP agents available"));
    return;
  }
  createState.agents.forEach(a => {
    const row = el("button", "create-row");
    row.type = "button";
    row.classList.toggle("is-selected", a.id === createState.selectedAgentId);
    row.onclick = () => {
      createState.selectedAgentId = a.id;
      createState.error = "";
      renderCreateSheet();
    };
    row.append(
      el("div", "create-row-title", a.name),
      el("div", "create-row-detail", a.isDefault ? "Default" : a.id)
    );
    list.append(row);
  });
}

function advanceCreateSheet() {
  if (createState.busy) return;
  createState.error = "";
  if (createState.step === "worktree") {
    createState.step = "agent";
    renderCreateSheet();
    return;
  }
  if (!createState.selectedWorktreeId || !createState.selectedAgentId) return;
  createState.busy = true;
  renderCreateSheet();
  send({ type: "createSession", worktreeId: createState.selectedWorktreeId, agentId: createState.selectedAgentId });
}

function backCreateSheet() {
  if (createState.busy) return;
  createState.step = "worktree";
  createState.error = "";
  renderCreateSheet();
}

function applyCreatedSession(session) {
  if (!session || !session.id) return;
  hideCreateSheet();
  sessionTitles.set(session.id, session.title || "New session");
  openSession(session.id);
  send({ type: "listSessions" });
}
```

- [ ] **Step 6: Add JS event bindings**

Near existing event bindings, add:

```javascript
$("new-session").onclick = showCreateSheet;
$("create-cancel").onclick = hideCreateSheet;
$("create-next").onclick = advanceCreateSheet;
$("create-back").onclick = backCreateSheet;
$("new-session-sheet").onclick = (e) => { if (e.target.id === "new-session-sheet" && !createState.busy) hideCreateSheet(); };
listen("worktree-search", "input", (e) => {
  createState.filter = e.target.value || "";
  renderCreateSheet();
});
```

- [ ] **Step 7: Add CSS**

In `style.css`, add header and sheet styles:

```css
#new-session {
  margin-left: auto;
  padding: 6px 10px;
  border: 0.5px solid color-mix(in oklab, var(--accent) 50%, transparent);
  border-radius: 999px;
  background: color-mix(in oklab, var(--accent) 15%, transparent);
  color: var(--fg);
  font-size: 13px;
  font-weight: 650;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  white-space: nowrap;
}
#new-session + #status.chip { margin-left: 0; }
.create-sheet { max-height: 82vh; display: flex; flex-direction: column; gap: 10px; }
.create-list { min-height: 0; max-height: 50vh; overflow-y: auto; display: flex; flex-direction: column; gap: 8px; }
.create-row {
  width: 100%;
  padding: 12px 13px;
  border: 1px solid var(--bg-4);
  border-radius: 10px;
  background: var(--bg-1);
  color: var(--fg);
  text-align: left;
  cursor: pointer;
}
.create-row.is-selected {
  border-color: var(--accent);
  background: color-mix(in oklab, var(--accent) 18%, transparent);
}
.create-row-title { font-size: 15px; font-weight: 650; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.create-row-detail { margin-top: 4px; color: var(--fg-muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.create-row-meta { margin-top: 7px; color: var(--fg-dim); font-size: 11px; }
.create-empty { padding: 18px 8px; color: var(--fg-dim); text-align: center; font-size: 14px; }
.sheet-error { padding: 10px 12px; border-radius: 10px; background: color-mix(in oklab, var(--del) 16%, transparent); color: var(--fg); font-size: 13px; }
.create-actions { display: grid; grid-template-columns: 1fr; gap: 0; }
```

- [ ] **Step 8: Run asset tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWebAssetTests test
```

Expected: `RemoteWebAssetTests` pass.

- [ ] **Step 9: Commit**

```bash
git add Alas/Resources/RemoteWeb/index.html Alas/Resources/RemoteWeb/app.js Alas/Resources/RemoteWeb/style.css AlasTests/Remote/RemoteWebAssetTests.swift
git commit -m "Add remote web new session UI"
```

## Task 5: Integration Verification And Polish

**Files:**
- Modify only if verification exposes defects in files changed by Tasks 1-4.

- [ ] **Step 1: Run focused remote test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteProtocolTests -only-testing:AlasTests/RemoteSessionGatewayTests -only-testing:AlasTests/RemoteAppStateAccessTests -only-testing:AlasTests/RemoteWebAssetTests test
```

Expected: all listed test suites pass.

- [ ] **Step 2: Run project generation**

Run:

```bash
xcodegen
```

Expected: exits 0. Since `project.yml` is not part of this feature, review any `Alas.xcodeproj/project.pbxproj` diff after generation and keep only changes required for test/file membership.

- [ ] **Step 3: Run full build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build exits 0.

- [ ] **Step 4: Run full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: tests exit 0.

- [ ] **Step 5: Inspect final diff**

Run:

```bash
git diff --stat HEAD~4..HEAD
git status --short
```

Expected: protocol, gateway, AppState, RemoteWeb assets, and tests changed. No `.superpowers/` scratch files are staged.

- [ ] **Step 6: Commit verification fixes**

Run:

```bash
git diff --quiet
```

Expected: exits 0 when no verification fixes changed files. When it exits non-zero, inspect the diff and commit the verification fixes:

```bash
git add Alas/Sources Alas/Resources/RemoteWeb AlasTests Alas.xcodeproj
git commit -m "Stabilize remote web session creation"
```
