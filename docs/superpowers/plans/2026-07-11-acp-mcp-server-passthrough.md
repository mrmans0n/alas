# ACP MCP Server Passthrough Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Alas projects configure stdio, HTTP, and legacy SSE MCP servers that are safely resolved, capability-filtered, passed through every ACP session lifecycle request, and reported honestly in project and session UI.

**Architecture:** Persist non-resolved project MCP definitions, then build one pure `MCPAttachmentPlan` after the ACP initialize handshake. Inject a current-project provider into each worktree manager, pass only resolved wire servers to `ACPConnection`, and retain only safe requested/skipped metadata on `ACPSession` for the toolbar.

**Tech Stack:** Swift 5.9, SwiftUI, Observation/Combine, Foundation/CryptoKit, Swift Testing, ACP v1 JSON-RPC, XcodeGen.

---

## File Structure

Create focused files rather than growing `ACPMessages.swift`, `ACPSessionManager.swift`, and `NewProjectDialog.swift` further:

- `Alas/Sources/Persistence/ProjectMCPServer.swift`: persisted server, transport, and key/value models plus structural validation.
- `Alas/Sources/ACP/Protocol/ACPMCPServer.swift`: ACP v1 MCP wire union and initialized transport capabilities.
- `Alas/Sources/ACP/Session/MCPAttachmentPlanner.swift`: interpolation, filtering, safe status, and configuration fingerprinting.
- `Alas/Sources/Dialogs/ProjectMCPServerManager.swift`: project draft list and deletion flow.
- `Alas/Sources/Dialogs/ProjectMCPServerEditor.swift`: adaptive add/edit form.
- `Alas/Sources/Dialogs/ProjectMCPServerEditorPolicy.swift`: pure validation, labels, reference extraction, and safe summaries.
- `Alas/Sources/ACP/UI/ACPMCPStatusControl.swift`: toolbar button and popover.
- `Alas/Sources/ACP/UI/ACPMCPStatusPolicy.swift`: pure visibility/count/staleness projection.
- `scripts/mcp-smoke-server.py`: dependency-free deterministic MCP stdio server for adapter smoke verification.

Modify existing ownership points only where wiring is required:

- `Alas/Sources/Persistence/ProjectConfig.swift`
- `Alas/Sources/App/ProjectsManager.swift`
- `Alas/Sources/App/AppState.swift`
- `Alas/Sources/ACP/Protocol/ACPMessages.swift`
- `Alas/Sources/ACP/Protocol/ACPConnection.swift`
- `Alas/Sources/ACP/Session/ACPSession.swift`
- `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- `Alas/Sources/Dialogs/NewProjectDialog.swift`
- `Alas/Sources/ACP/UI/ACPToolbar.swift`

### Task 1: Persist Project MCP Definitions

**Files:**
- Create: `Alas/Sources/Persistence/ProjectMCPServer.swift`
- Modify: `Alas/Sources/Persistence/ProjectConfig.swift`
- Test: `AlasTests/Persistence/ProjectMCPServerTests.swift`
- Test: `AlasTests/ProjectConfigTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing model and compatibility tests**

Create `ProjectMCPServerTests` covering all transports and semantic validation:

```swift
import Foundation
import Testing
@testable import Alas

@Suite("Project MCP server")
struct ProjectMCPServerTests {
    @Test func roundTripsAllTransports() throws {
        let servers = [
            ProjectMCPServer(id: "stdio", name: "filesystem", transport: .stdio(
                command: "npx", args: ["-y", "server", "${WORKTREE_DIR}"],
                environment: [.init(id: "env", name: "API_TOKEN", value: "${TOKEN}")]
            )),
            ProjectMCPServer(id: "http", name: "linear", transport: .http(
                url: "https://mcp.linear.app/mcp",
                headers: [.init(id: "header", name: "Authorization", value: "Bearer ${LINEAR_TOKEN}")]
            )),
            ProjectMCPServer(id: "sse", name: "legacy", transport: .sse(
                url: "https://example.com/sse", headers: []
            )),
        ]
        let data = try JSONEncoder().encode(servers)
        #expect(try JSONDecoder().decode([ProjectMCPServer].self, from: data) == servers)
    }

    @Test func validationRejectsDuplicateNamesAndInvalidFields() {
        let duplicate = ProjectMCPServer.stdio(name: "filesystem", command: "npx")
        #expect(ProjectMCPValidation.validate([duplicate, duplicate.withFreshId()]) ==
                [.duplicateServerName("filesystem")])
        #expect(ProjectMCPValidation.validate([
            .init(id: "bad", name: "remote", transport: .http(url: "file:///tmp/mcp", headers: []))
        ]).contains(.invalidURL(serverName: "remote")))
    }
}
```

Extend `ProjectConfigTests.decodingOlderProjectsFileSuppliesEmptyHiddenPaths` with:

```swift
#expect(file.projects[0].mcpServers.isEmpty)
```

Add a project round-trip assertion with one stdio server.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectMCPServerTests -only-testing:AlasTests/ProjectConfigTests test
```

Expected: compile failure because the project MCP types and `mcpServers` do not exist.

- [ ] **Step 3: Implement the persisted types and validator**

Use this public shape in `ProjectMCPServer.swift`:

```swift
import Foundation

struct MCPKeyValue: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var value: String
}

enum ProjectMCPTransport: Codable, Equatable {
    case stdio(command: String, args: [String], environment: [MCPKeyValue])
    case http(url: String, headers: [MCPKeyValue])
    case sse(url: String, headers: [MCPKeyValue])
}

struct ProjectMCPServer: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var transport: ProjectMCPTransport

    static func stdio(name: String, command: String) -> Self {
        .init(id: UUID().uuidString, name: name,
              transport: .stdio(command: command, args: [], environment: []))
    }

    func withFreshId() -> Self {
        .init(id: UUID().uuidString, name: name, transport: transport)
    }
}

enum ProjectMCPValidationIssue: Equatable {
    case emptyServerName(serverId: String)
    case duplicateServerName(String)
    case emptyCommand(serverName: String)
    case invalidURL(serverName: String)
    case invalidEnvironmentName(serverName: String, name: String)
    case duplicateEnvironmentName(serverName: String, name: String)
    case emptyHeaderName(serverName: String)
    case duplicateHeaderName(serverName: String, name: String)
}
```

Implement `ProjectMCPValidation.validate(_:)` with trimmed, case-sensitive server-name uniqueness; POSIX environment-name validation using `^[A-Za-z_][A-Za-z0-9_]*$`; case-insensitive header-name uniqueness; non-empty stdio command; and HTTP/HTTPS URL validation.

Add `mcpServers` to `ProjectConfig`, its initializer, coding keys, tolerant decoder, and encoder. Missing values decode as `[]`.

- [ ] **Step 4: Regenerate and run focused tests**

Run the Step 2 commands again.

Expected: both suites pass.

- [ ] **Step 5: Commit persistence support**

```bash
rtk git add Alas/Sources/Persistence/ProjectMCPServer.swift Alas/Sources/Persistence/ProjectConfig.swift AlasTests/Persistence/ProjectMCPServerTests.swift AlasTests/ProjectConfigTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(acp): persist project MCP servers"
```

### Task 2: Model ACP v1 MCP Wire Shapes and Capabilities

**Files:**
- Create: `Alas/Sources/ACP/Protocol/ACPMCPServer.swift`
- Modify: `Alas/Sources/ACP/Protocol/ACPMessages.swift`
- Modify: `Alas/Sources/ACP/Protocol/ACPConnection.swift`
- Test: `AlasTests/ACP/Protocol/ACPMCPServerTests.swift`
- Test: `AlasTests/ACP/Protocol/ACPInitializeTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing wire encoding tests**

Test JSON objects, not encoded string ordering:

```swift
@Test func encodesStableV1TransportShapes() throws {
    let servers: [ACPMCPServer] = [
        .stdio(name: "fs", command: "npx", args: [], env: []),
        .http(name: "linear", url: "https://mcp.linear.app/mcp", headers: []),
        .sse(name: "legacy", url: "https://example.com/sse", headers: []),
    ]
    let objects = try servers.map { server -> [String: Any] in
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(server)) as? [String: Any])
    }
    #expect(objects[0]["type"] == nil)
    #expect(objects[0]["args"] as? [String] == [])
    #expect(objects[0]["env"] as? [[String: String]] == [])
    #expect(objects[1]["type"] as? String == "http")
    #expect(objects[1]["headers"] as? [[String: String]] == [])
    #expect(objects[2]["type"] as? String == "sse")
}
```

Add initialize decoding tests for `{ "mcpCapabilities": { "http": true, "sse": false } }` and missing capability defaults.

- [ ] **Step 2: Run focused tests and verify failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPMCPServerTests -only-testing:AlasTests/ACPInitializeTests test
```

Expected: compile failure for missing wire and capability types.

- [ ] **Step 3: Implement the custom wire union**

Create:

```swift
import Foundation

struct ACPMCPKeyValue: Codable, Equatable {
    let name: String
    let value: String
}

enum ACPMCPServer: Codable, Equatable {
    case stdio(name: String, command: String, args: [String], env: [ACPMCPKeyValue])
    case http(name: String, url: String, headers: [ACPMCPKeyValue])
    case sse(name: String, url: String, headers: [ACPMCPKeyValue])
}

struct ACPMCPServerCapabilities: Codable, Equatable {
    let http: Bool
    let sse: Bool

    init(http: Bool = false, sse: Bool = false) {
        self.http = http
        self.sse = sse
    }
}
```

Give `ACPMCPServer` explicit coding keys so stdio omits `type`, while remote variants require it. Decode missing `args`, `env`, or `headers` as empty for tolerance, but always encode those arrays.

Add `mcpCapabilities` to `ACPInitializeResult.ACPAgentCapabilities` with a default `.init()`. Add the same property to `ACPInitializeOutcome` and return it from `ACPConnection.initialize()`.

Replace nested `ACPSessionNewParams.ACPMCPServer` references in all lifecycle params with `[ACPMCPServer]`.

- [ ] **Step 4: Run focused tests**

Run the Step 2 commands again.

Expected: pass.

- [ ] **Step 5: Commit protocol modeling**

```bash
rtk git add Alas/Sources/ACP/Protocol/ACPMCPServer.swift Alas/Sources/ACP/Protocol/ACPMessages.swift Alas/Sources/ACP/Protocol/ACPConnection.swift AlasTests/ACP/Protocol/ACPMCPServerTests.swift AlasTests/ACP/Protocol/ACPInitializeTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(acp): model MCP transport capabilities"
```

### Task 3: Build the Pure Attachment Planner

**Files:**
- Create: `Alas/Sources/ACP/Session/MCPAttachmentPlanner.swift`
- Test: `AlasTests/ACP/Session/MCPAttachmentPlannerTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing planner tests**

Cover stdio baseline, optional capability filtering, built-in precedence, multi-reference expansion, missing variables, semantic invalidity, safe status, and fingerprint stability:

```swift
@Test func plansRequestedAndSkippedServersWithoutLeakingSecrets() throws {
    let input = MCPAttachmentPlannerInput(
        configuredServers: [
            .init(id: "stdio", name: "fs", transport: .stdio(
                command: "npx", args: ["${WORKTREE_DIR}"],
                environment: [.init(id: "token", name: "API_TOKEN", value: "${TOKEN}")]
            )),
            .init(id: "http", name: "linear", transport: .http(
                url: "https://mcp.linear.app/mcp", headers: []
            )),
        ],
        projectDirectory: "/repo",
        worktreeDirectory: "/repo/wt",
        environment: ["TOKEN": "super-secret", "WORKTREE_DIR": "/wrong"],
        capabilities: .init(http: false, sse: false)
    )
    let plan = MCPAttachmentPlanner.plan(input)
    #expect(plan.wireServers.count == 1)
    #expect(plan.statuses == [
        .init(name: "fs", transport: .stdio, disposition: .requested),
        .init(name: "linear", transport: .http, disposition: .skipped(.unsupportedTransport)),
    ])
    #expect(String(describing: plan.statuses).contains("super-secret") == false)
}
```

Add a test proving two definitions with different editing IDs have the same fingerprint and changing a referenced value changes it.

- [ ] **Step 2: Run tests and verify failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/MCPAttachmentPlannerTests test
```

Expected: compile failure for missing planner types.

- [ ] **Step 3: Implement planner inputs, status, and interpolation**

Use these consistent types:

```swift
import CryptoKit
import Foundation

enum MCPTransportKind: String, Codable, Equatable { case stdio, http, sse }

enum MCPAttachmentSkipReason: Equatable {
    case unsupportedTransport
    case missingVariable(String)
    case invalidConfiguration(String)
}

enum MCPAttachmentDisposition: Equatable {
    case requested
    case skipped(MCPAttachmentSkipReason)
}

struct MCPAttachmentServerStatus: Equatable, Identifiable {
    var id: String { "\(transport.rawValue):\(name)" }
    let name: String
    let transport: MCPTransportKind
    let disposition: MCPAttachmentDisposition
}

struct MCPAttachmentPlan: Equatable {
    let wireServers: [ACPMCPServer]
    let statuses: [MCPAttachmentServerStatus]
    let configurationFingerprint: String
}
```

Implement `${NAME}` substitution with `NSRegularExpression`, resolving reserved `PROJECT_DIR` and `WORKTREE_DIR` before the supplied environment. Return the first missing variable name and skip the whole server. Never include resolved values in errors or status.

Fingerprint a normalized Codable representation that excludes all editing IDs, using `JSONEncoder.outputFormatting = [.sortedKeys]` and SHA-256 hex.
Expose `MCPAttachmentPlanner.configurationFingerprint(for:)` so the toolbar can
compare current saved definitions without resolving environment values.

- [ ] **Step 4: Run focused tests**

Run the Step 2 commands again.

Expected: pass.

- [ ] **Step 5: Commit planner**

```bash
rtk git add Alas/Sources/ACP/Session/MCPAttachmentPlanner.swift AlasTests/ACP/Session/MCPAttachmentPlannerTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(acp): plan MCP server attachments"
```

### Task 4: Pass MCP Servers Through ACPConnection

**Files:**
- Modify: `Alas/Sources/ACP/Protocol/ACPConnection.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- Test: `AlasTests/ACP/Protocol/ACPConnectionTests.swift`

- [ ] **Step 1: Update connection tests to require passthrough**

For each lifecycle method, pass a non-empty array and assert typed params contain it:

```swift
let servers: [ACPMCPServer] = [.stdio(name: "fs", command: "npx", args: [], env: [])]
let result = try await conn.loadSession(cwd: "/tmp/wt", sessionId: "remote-old", mcpServers: servers)
let params = try #require(mock.sent.last?.params as? ACPSessionLoadParams)
#expect(params.mcpServers == servers)
```

Add equivalent assertions for new, resume, and fork.

- [ ] **Step 2: Run and verify compile failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPConnectionTests test
```

Expected: method signatures do not accept `mcpServers`.

- [ ] **Step 3: Change all four method signatures**

Use required parameters, not default empty arrays, so future call sites cannot accidentally omit the plan:

```swift
func newSession(cwd: String, mcpServers: [ACPMCPServer]) async throws -> ACPSessionNewResult
func loadSession(cwd: String, sessionId: String, mcpServers: [ACPMCPServer]) async throws -> ACPSessionNewResult
func resumeSession(cwd: String, sessionId: String, mcpServers: [ACPMCPServer]) async throws -> ACPSessionNewResult
func forkSession(cwd: String, sessionId: String, mcpServers: [ACPMCPServer]) async throws -> ACPSessionNewResult
```

Construct each params value with the supplied array.

Update the existing manager call sites to pass `[]` in this task. This is an
explicit, short-lived compilation bridge; Task 5 replaces every one of those
arrays with the single planned server list. `forkSession` has no production
caller today, so its required argument and connection test are the complete
current integration surface rather than a reason to invent a fork workflow.

- [ ] **Step 4: Run focused tests**

Expected: `ACPConnectionTests` pass and the app target compiles with the
explicit empty manager call sites.

- [ ] **Step 5: Commit connection passthrough**

```bash
rtk git add Alas/Sources/ACP/Protocol/ACPConnection.swift Alas/Sources/ACP/Session/ACPSessionManager.swift AlasTests/ACP/Protocol/ACPConnectionTests.swift
rtk git commit -m "feat(acp): pass MCP servers through lifecycle RPCs"
```

### Task 5: Integrate Planning Into Session Attachment

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `AlasTests/ACP/Session/ACPSessionManagerAttachRestoreTests.swift`

- [ ] **Step 1: Write failing attach-flow tests**

Extend the test helper to accept a provider:

```swift
private func manager(
    store: ACPSessionStore,
    client: ACPMockClient,
    context: @escaping () -> MCPProjectContext? = { nil }
) -> ACPSessionManager {
    ACPSessionManager(
        worktreeId: "wt", worktreePath: "/tmp/wt", store: store,
        mcpProjectContextProvider: context,
        setupEvaluator: { _ in .ready },
        connectionFactory: { _ in ACPConnection(client: client) }
    )
}
```

Add tests proving:

- initialize capabilities filter the plan before `session/new`
- `session/load`, `session/resume`, and load-to-new recovery receive the same plan
- invoking the provider again on a second attach reads changed configuration
- the safe summary is present on `ACPSession` and contains no resolved values

- [ ] **Step 2: Run focused tests and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionManagerAttachRestoreTests test
```

Expected: compile failure for the provider and session summary.

- [ ] **Step 3: Add current-project injection and runtime summary**

Define:

```swift
struct MCPProjectContext: Equatable {
    let projectPath: String
    let servers: [ProjectMCPServer]
}

struct MCPAttachmentSummary: Equatable {
    let statuses: [MCPAttachmentServerStatus]
    let configurationFingerprint: String
}
```

Add `@Published var mcpAttachmentSummary: MCPAttachmentSummary?` to `ACPSession`. Add an `mcpProjectContextProvider` closure to `ACPSessionManager.init`, defaulting to `{ nil }` for existing tests.

Immediately after `initialize`, call the provider and planner with:

```swift
let projectContext = mcpProjectContextProvider()
let mcpPlan = MCPAttachmentPlanner.plan(.init(
    configuredServers: projectContext?.servers ?? [],
    projectDirectory: projectContext?.projectPath ?? worktreePath,
    worktreeDirectory: worktreePath,
    environment: ACPProcessEnvironment.sanitizedForACP(extra: spec.extraEnv),
    capabilities: initialized.mcpCapabilities
))
session.mcpAttachmentSummary = .init(
    statuses: mcpPlan.statuses,
    configurationFingerprint: mcpPlan.configurationFingerprint
)
```

Pass `mcpPlan.wireServers` to every lifecycle call, including existing recovery-to-new branches. Never recompute the plan during one attach attempt.

In `AppState.acpManager(for:)`, inject a closure that uses `worktree.projectId` to find the current project and returns its path and current servers.

- [ ] **Step 4: Run focused manager and connection tests**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPConnectionTests -only-testing:AlasTests/ACPSessionManagerAttachRestoreTests test
```

Expected: pass.

- [ ] **Step 5: Commit lifecycle integration**

```bash
rtk git add Alas/Sources/ACP/Protocol/ACPConnection.swift Alas/Sources/ACP/Session/ACPSession.swift Alas/Sources/ACP/Session/ACPSessionManager.swift Alas/Sources/App/AppState.swift AlasTests/ACP/Protocol/ACPConnectionTests.swift AlasTests/ACP/Session/ACPSessionManagerAttachRestoreTests.swift
rtk git commit -m "feat(acp): attach project MCP servers"
```

### Task 6: Preserve MCP Definitions Through Project Draft Updates

**Files:**
- Modify: `Alas/Sources/App/ProjectsManager.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Dialogs/NewProjectDialog.swift`
- Create: `Alas/Sources/Dialogs/ProjectMCPServerEditorPolicy.swift`
- Test: `AlasTests/ProjectConfigTests.swift`
- Test: `AlasTests/ProjectMCPServerEditorPolicyTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing project-update and editor-policy tests**

Add a `ProjectsManager` update test proving MCP values survive the update and a pure editor policy test:

```swift
@Test @MainActor func projectUpdatePersistsMCPDraft() {
    let server = ProjectMCPServer.stdio(name: "fs", command: "npx")
    let project = ProjectConfig(
        id: "project", name: "alas", path: "/tmp/alas",
        color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0)
    )
    let manager = ProjectsManager(persistedProjects: [project])
    manager.updateProject(id: "project", update: .init(
        name: "renamed", icon: .default(color: "#5fb7c4"),
        startupScripts: .defaults, mcpServers: [server]
    ))
    #expect(manager.projects[0].mcpServers == [server])
}

@Test @MainActor func unrelatedProjectUpdatePreservesExistingMCPServers() {
    let server = ProjectMCPServer.stdio(name: "fs", command: "npx")
    var project = ProjectConfig(
        id: "project", name: "alas", path: "/tmp/alas",
        color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0)
    )
    project.mcpServers = [server]
    let manager = ProjectsManager(persistedProjects: [project])
    manager.updateProject(id: "project", update: .init(
        name: "renamed", icon: .default(color: "#5fb7c4")
    ))
    #expect(manager.projects[0].mcpServers == [server])
}

@Test func editorBlocksStructuralErrorsButAllowsMissingReferences() {
    #expect(ProjectMCPServerEditorPolicy.canSave(
        server: .stdio(name: "fs", command: "npx"), siblingServers: []
    ))
    #expect(ProjectMCPServerEditorPolicy.environmentReferences(in: "Bearer ${TOKEN}") == ["TOKEN"])
}
```

- [ ] **Step 2: Run focused tests and verify failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectConfigTests -only-testing:AlasTests/ProjectMCPServerEditorPolicyTests test
```

Expected: compile failure for `ProjectUpdate.mcpServers` and editor policy.

- [ ] **Step 3: Wire MCP values through the existing project update path**

Add `mcpServers: [ProjectMCPServer]? = nil` to `ProjectUpdate`. In
`ProjectsManager.updateProject`, assign it only when the optional contains a
value. This patch semantics preserves MCP configuration at unrelated
`ProjectUpdate` call sites. Add a required `[ProjectMCPServer]` parameter to the
Edit Project `AppState.updateProject` overload and pass it from
`ProjectDialog.confirm`.

Add `@State private var mcpServers: [ProjectMCPServer] = []` to `ProjectDialog`; populate it from edit mode; leave it empty in add mode. Keep the manager entry point edit-only, matching startup scripts.

Implement `ProjectMCPServerEditorPolicy` as a pure wrapper over `ProjectMCPValidation` plus `${NAME}` reference extraction. Missing runtime variables produce advisory warnings and do not make `canSave` false.

- [ ] **Step 4: Run focused tests**

Expected: pass.

- [ ] **Step 5: Commit project draft plumbing**

```bash
rtk git add Alas/Sources/App/ProjectsManager.swift Alas/Sources/App/AppState.swift Alas/Sources/Dialogs/NewProjectDialog.swift Alas/Sources/Dialogs/ProjectMCPServerEditorPolicy.swift AlasTests/ProjectConfigTests.swift AlasTests/ProjectMCPServerEditorPolicyTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(projects): preserve MCP configuration drafts"
```

### Task 7: Build the MCP Server Manager and Adaptive Editor

**Files:**
- Create: `Alas/Sources/Dialogs/ProjectMCPServerManager.swift`
- Create: `Alas/Sources/Dialogs/ProjectMCPServerEditor.swift`
- Modify: `Alas/Sources/Dialogs/NewProjectDialog.swift`
- Test: `AlasTests/ProjectMCPServerEditorPolicyTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Extend policy tests for display and validation states**

Cover trimmed unique names, invalid command/URL, duplicate environment/header keys, safe summaries that omit args/query/userinfo/fragment, and the label `Legacy SSE`.

```swift
@Test func remoteSummaryStripsCredentialsAndQuery() {
    let server = ProjectMCPServer(
        id: "remote", name: "linear",
        transport: .http(url: "https://user:secret@example.com/mcp?token=secret#fragment", headers: [])
    )
    #expect(ProjectMCPServerEditorPolicy.safeSummary(server) == "https://example.com/mcp")
}
```

- [ ] **Step 2: Run tests and verify failure**

Run the Task 6 focused test command.

Expected: failure for missing summary and label behavior.

- [ ] **Step 3: Implement manager list UI**

`ProjectMCPServerManager` takes `@Binding var servers`, snapshots the binding on appear for its own Cancel behavior, and provides:

- name, transport label, and safe summary per row
- `Add` command
- overflow menu with `Edit` and `Delete`
- delete confirmation
- `Done` that keeps the edited binding
- `Cancel` that restores the snapshot

Use individual list rows, not nested cards. Use `Icon`/SF Symbols and existing `AlasButton` controls.

- [ ] **Step 4: Implement the adaptive editor**

`ProjectMCPServerEditor` owns a draft server and uses `Seg` with `stdio`, `HTTP`, and `Legacy SSE`. Render:

- ordered argument rows with add/remove controls
- ordered environment or header rows with add/remove controls
- inline structural error text
- missing-reference advisory text
- SSE deprecation text
- disabled confirm button until `ProjectMCPServerEditorPolicy.canSave` is true

Switching transport preserves the name but initializes transport-specific fields to empty values. Saving normalizes trimmed server/key names while preserving values verbatim.

- [ ] **Step 5: Add the Edit Project entry point**

In the `Integrations` section, show `No servers configured` or `N configured for ACP sessions`, plus `Manage...`. Present the manager as a sheet bound to the parent `mcpServers` draft.

- [ ] **Step 6: Regenerate, run policy tests, and build**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectMCPServerEditorPolicyTests test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: tests and build pass.

- [ ] **Step 7: Commit project MCP UI**

```bash
rtk git add Alas/Sources/Dialogs/ProjectMCPServerManager.swift Alas/Sources/Dialogs/ProjectMCPServerEditor.swift Alas/Sources/Dialogs/NewProjectDialog.swift AlasTests/ProjectMCPServerEditorPolicyTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(projects): manage MCP servers"
```

### Task 8: Add Honest ACP Toolbar Status

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPMCPStatusPolicy.swift`
- Create: `Alas/Sources/ACP/UI/ACPMCPStatusControl.swift`
- Modify: `Alas/Sources/ACP/UI/ACPToolbar.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/ACP/UI/ACPMCPStatusPolicyTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing status policy tests**

```swift
@Suite("ACP MCP status policy")
struct ACPMCPStatusPolicyTests {
    @Test func projectsVisibilityCountsWarningsAndStaleness() {
        #expect(ACPMCPStatusPolicy.presentation(summary: nil, currentFingerprint: nil) == nil)
        let summary = MCPAttachmentSummary(statuses: [
            .init(name: "fs", transport: .stdio, disposition: .requested),
            .init(name: "legacy", transport: .sse, disposition: .skipped(.unsupportedTransport)),
        ], configurationFingerprint: "old")
        let state = ACPMCPStatusPolicy.presentation(summary: summary, currentFingerprint: "new")
        #expect(state?.requestedCount == 1)
        #expect(state?.hasWarning == true)
        #expect(state?.isStale == true)
    }
}
```

Also test all-skipped visibility, requested-only no-warning state, and safe reason strings.

- [ ] **Step 2: Run and verify failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPMCPStatusPolicyTests test
```

Expected: compile failure for policy types.

- [ ] **Step 3: Implement pure presentation policy**

Return `nil` only when there are no requested or skipped statuses. Project requested count, warning presence, staleness, transport labels, and safe skip descriptions. Use exactly:

- `Requested for this session`
- `Skipped: agent does not support HTTP`
- `Skipped: agent does not support SSE`
- `Skipped: missing environment variable NAME`
- `Skipped: invalid configuration — REASON`

- [ ] **Step 4: Implement toolbar control and popover**

Create a compact button matching existing toolbar chrome. Label it `MCP N`; add a warning badge only when skipped entries exist. The popover lists name, transport, and safe status. When stale, show:

`Project MCP configuration changed. New settings apply when this session reconnects.`

Do not render commands, arguments, URLs, headers, environment values, or resolved data.

Add `AppState.mcpProjectContext(for:)` as an internal read-only helper and compute the current fingerprint with the planner's fingerprint helper. Insert `ACPMCPStatusControl` after `ACPRecoveryPill` in `ACPToolbar`.

- [ ] **Step 5: Regenerate, test, and build**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPMCPStatusPolicyTests test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: pass.

- [ ] **Step 6: Commit toolbar status**

```bash
rtk git add Alas/Sources/ACP/UI/ACPMCPStatusPolicy.swift Alas/Sources/ACP/UI/ACPMCPStatusControl.swift Alas/Sources/ACP/UI/ACPToolbar.swift Alas/Sources/App/AppState.swift AlasTests/ACP/UI/ACPMCPStatusPolicyTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(acp): show MCP attachment status"
```

### Task 9: Adapter Smoke Fixture and Final Verification

**Files:**
- Create: `scripts/mcp-smoke-server.py`
- Test: focused suites from Tasks 1-8

- [ ] **Step 1: Add a dependency-free MCP stdio fixture**

Implement a newline-delimited JSON-RPC loop that handles:

- `initialize`: echo the requested protocol version and advertise tools
- `notifications/initialized`: no response
- `tools/list`: expose `alas_echo` with one required string argument, `text`
- `tools/call`: return `alas-mcp-smoke:<text>`
- unknown requests: return JSON-RPC `-32601`

The script must write protocol responses only to stdout and diagnostics only to stderr. Mark it executable.

- [ ] **Step 2: Exercise the fixture directly**

Run:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' | scripts/mcp-smoke-server.py
```

Expected: one JSON-RPC response whose `serverInfo.name` is `alas-mcp-smoke`.

- [ ] **Step 3: Run focused regression suites**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectMCPServerTests -only-testing:AlasTests/ProjectConfigTests -only-testing:AlasTests/ACPMCPServerTests -only-testing:AlasTests/ACPInitializeTests -only-testing:AlasTests/MCPAttachmentPlannerTests -only-testing:AlasTests/ACPConnectionTests -only-testing:AlasTests/ACPSessionManagerAttachRestoreTests -only-testing:AlasTests/ProjectMCPServerEditorPolicyTests -only-testing:AlasTests/ACPMCPStatusPolicyTests test
```

Expected: pass.

- [ ] **Step 4: Perform real adapter smoke checks**

In Edit Project, add:

- name: `alas-smoke`
- transport: `stdio`
- command: the absolute path to `scripts/mcp-smoke-server.py`
- environment: `ALAS_MCP_SMOKE_TOKEN=${ALAS_MCP_SMOKE_TOKEN}`

Launch Alas with `ALAS_MCP_SMOKE_TOKEN=present`. For both `claude-agent-acp` and `codex-acp`:

1. Create a fresh ACP session.
2. Confirm the toolbar says `MCP 1` without a warning.
3. Ask the agent to call `alas_echo` with `hello`.
4. Confirm the result contains `alas-mcp-smoke:hello`.
5. Reconnect the session and repeat the tool call.

Then remove `ALAS_MCP_SMOKE_TOKEN`, reconnect, and confirm the session starts while the toolbar reports the server skipped for the missing variable.

- [ ] **Step 5: Run required project verification**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: build and full test suite pass.

- [ ] **Step 6: Inspect the final diff and commit verification fixture**

```bash
rtk git diff --check
rtk git status --short
rtk git add scripts/mcp-smoke-server.py Alas.xcodeproj/project.pbxproj
rtk git commit -m "test(acp): add MCP adapter smoke fixture"
```

Expected: only intended implementation, tests, generated project changes, and the smoke fixture remain; the worktree is clean after the commit.
