# ACP Terminal Auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class ACP terminal authentication so Claude/Cursor-style ACP auth failures surface as a sign-in banner that launches the provider's advertised login command and retries attach.

**Architecture:** Extend ACP protocol models to advertise/decode auth. Add runtime auth setup state to `ACPSession` and classify auth-required JSON-RPC errors in manager/runner paths. Reuse the existing ACP top banner and AppState terminal-tab launcher for the interactive login command, with an exit callback that reattaches the ACP session.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing, existing Alas ACP JSON-RPC stdio client, existing terminal tab/Ghostty surface.

---

## File Structure

- Modify `Alas/Sources/ACP/Protocol/ACPMessages.swift`: add auth capability and auth method wire models.
- Modify `Alas/Sources/ACP/Protocol/ACPConnection.swift`: return initialize auth methods and add `authenticate(methodId:)`.
- Modify `Alas/Sources/ACP/Protocol/ACPClient.swift`: improve JSON-RPC auth error description if needed.
- Create `Alas/Sources/ACP/Protocol/ACPAuthFailure.swift`: shared auth-error classifier.
- Modify `Alas/Sources/ACP/Session/ACPSession.swift`: add runtime auth state.
- Modify `Alas/Sources/ACP/Session/ACPSessionManager.swift`: store auth methods and convert attach auth failures into setup state.
- Modify `Alas/Sources/ACP/Session/ACPSessionRunner.swift`: convert prompt auth failures into setup state.
- Create `Alas/Sources/ACP/UI/ACPAuthNudgeBanner.swift`: sign-in banner and copy helpers.
- Modify `Alas/Sources/ACP/UI/ACPTabView.swift`: render auth banner and trigger auth terminal launch.
- Modify `Alas/Sources/App/AppState.swift`: add ACP auth terminal launcher and terminal-exit callback hook.
- Add/modify tests under `AlasTests/ACP/Protocol`, `AlasTests/ACP/Session`, `AlasTests/ACP/Adapter`, and `AlasTests/AgentTerminalLaunchTests.swift`.

---

### Task 1: Protocol Auth Models And Initialize Capability

**Files:**
- Modify: `Alas/Sources/ACP/Protocol/ACPMessages.swift`
- Modify: `Alas/Sources/ACP/Protocol/ACPConnection.swift`
- Modify: `Alas/Sources/ACP/Protocol/ACPMockClient.swift` if test helpers need method inspection only
- Test: `AlasTests/ACP/Protocol/ACPInitializeTests.swift`
- Test: `AlasTests/ACP/Protocol/ACPConnectionTests.swift`

- [ ] **Step 1: Write failing protocol tests**

Add tests covering the desired wire shape:

```swift
@Test("initialize request advertises terminal auth capabilities")
func initializeRequestAdvertisesAuth() throws {
    let req = ACPRequest(method: "initialize",
                         params: ACPInitializeParams.defaultClient())
    let data = try JSONEncoder().encode(JSONRPCEnvelope(id: .number(1), method: req.method, params: req.params as? ACPInitializeParams))
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains(#""auth":{"terminal":true}"#))
    #expect(json.contains(#""_meta":{"terminal-auth":true}"#))
}

@Test("decodes terminal auth method metadata")
func decodesTerminalAuthMethod() throws {
    let data = Data("""
    {"protocolVersion":1,"authMethods":[{"id":"claude-ai-login","name":"Claude Subscription","description":"Use Claude subscription","type":"terminal","args":["--cli","auth","login"],"env":{"A":"B"},"_meta":{"terminal-auth":{"command":"/usr/bin/node","args":["/opt/claude-agent-acp","--cli"],"label":"Claude Login"}}}]}
    """.utf8)
    let result = try JSONDecoder().decode(ACPInitializeResult.self, from: data)
    let method = try #require(result.authMethods.first)
    #expect(method.id == "claude-ai-login")
    #expect(method.kind == .terminal)
    #expect(method.args == ["--cli", "auth", "login"])
    #expect(method.env == ["A": "B"])
    #expect(method.terminalAuth?.command == "/usr/bin/node")
    #expect(method.terminalAuth?.args == ["/opt/claude-agent-acp", "--cli"])
    #expect(method.terminalAuth?.label == "Claude Login")
}
```

Add an `ACPConnectionTests` assertion that `initialize()` returns both prompt capabilities and auth methods:

```swift
let initialized = try await conn.initialize()
#expect(initialized.promptCapabilities.embeddedContext == true)
#expect(initialized.authMethods.map(\\.id) == ["claude-ai-login"])
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPInitializeTests -only-testing:AlasTests/ACPConnectionTests test
```

Expected: failures because auth capability/model fields and richer initialize return value do not exist yet.

- [ ] **Step 3: Implement protocol models**

In `ACPMessages.swift`, add:

```swift
struct ACPClientCapabilities: Codable, Equatable {
    let fs: ACPFsCapabilities
    let terminal: Bool
    let auth: ACPAuthCapabilities
    let meta: ACPClientCapabilitiesMeta

    init(fs: ACPFsCapabilities, terminal: Bool, auth: ACPAuthCapabilities = .init(terminal: true), meta: ACPClientCapabilitiesMeta = .terminalAuth) {
        self.fs = fs
        self.terminal = terminal
        self.auth = auth
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case fs, terminal, auth
        case meta = "_meta"
    }

    struct ACPFsCapabilities: Codable, Equatable {
        let readTextFile: Bool
        let writeTextFile: Bool
    }
}

struct ACPAuthCapabilities: Codable, Equatable {
    let terminal: Bool
}

struct ACPClientCapabilitiesMeta: Codable, Equatable {
    static let terminalAuth = ACPClientCapabilitiesMeta(terminalAuth: true)
    let terminalAuth: Bool

    enum CodingKeys: String, CodingKey {
        case terminalAuth = "terminal-auth"
    }
}
```

Replace the nested `ACPInitializeResult.ACPAuthMethod` with a richer nested model:

```swift
struct ACPAuthMethod: Codable, Equatable {
    let id: String
    let name: String
    let description: String?
    let kind: Kind
    let args: [String]?
    let env: [String: String]?
    let vars: [ACPAuthEnvVar]?
    let meta: Meta?

    var terminalAuth: TerminalAuthMeta? { meta?.terminalAuth }

    enum Kind: Equatable {
        case agent
        case terminal
        case envVar
        case unknown(String)
    }

    struct Meta: Codable, Equatable {
        let terminalAuth: TerminalAuthMeta?
        enum CodingKeys: String, CodingKey { case terminalAuth = "terminal-auth" }
    }

    struct TerminalAuthMeta: Codable, Equatable {
        let command: String?
        let args: [String]?
        let label: String?
    }

    struct ACPAuthEnvVar: Codable, Equatable {
        let name: String
        let label: String?
        let optional: Bool?
        let secret: Bool?
    }
}
```

Implement custom Codable for `Kind` so missing `type` decodes as `.agent`, `"env_var"` decodes as `.envVar`, and unknown strings round-trip as `.unknown(value)`. Implement custom Codable for `ACPAuthMethod` to map JSON field `type` to `kind` and `_meta` to `meta`.

- [ ] **Step 4: Implement initialize return value**

In `ACPConnection.swift`, add:

```swift
struct ACPInitializeOutcome: Equatable {
    let promptCapabilities: ACPInitializeResult.ACPPromptCapabilities
    let authMethods: [ACPInitializeResult.ACPAuthMethod]
}
```

Change `initialize()` to return `ACPInitializeOutcome`:

```swift
let result = try JSONDecoder().decode(ACPInitializeResult.self, from: resp.body)
return ACPInitializeOutcome(
    promptCapabilities: result.agentCapabilities?.promptCapabilities ?? .init(),
    authMethods: result.authMethods
)
```

Keep the initialize request's `clientCapabilities` creation using `.init(fs:..., terminal: true)` so the new default auth capability is encoded automatically.

- [ ] **Step 5: Update direct callers and tests**

Update `ACPSessionManager.attach` to use:

```swift
let initialized = try await connection.initialize()
session.promptCapabilities = initialized.promptCapabilities
session.authMethods = initialized.authMethods
```

Update existing tests that treated `initialize()` as returning prompt capabilities.

- [ ] **Step 6: Run protocol tests and commit**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPInitializeTests -only-testing:AlasTests/ACPConnectionTests test
```

Expected: PASS.

Commit:

```bash
rtk proxy git add Alas/Sources/ACP/Protocol/ACPMessages.swift Alas/Sources/ACP/Protocol/ACPConnection.swift Alas/Sources/ACP/Session/ACPSessionManager.swift AlasTests/ACP/Protocol/ACPInitializeTests.swift AlasTests/ACP/Protocol/ACPConnectionTests.swift
rtk proxy git commit -m "feat(acp): negotiate auth methods"
```

---

### Task 2: Runtime Auth State And Error Classification

**Files:**
- Create: `Alas/Sources/ACP/Protocol/ACPAuthFailure.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionRunner.swift`
- Test: `AlasTests/ACP/Protocol/ACPAuthFailureTests.swift`
- Test: `AlasTests/ACP/Session/ACPSessionManagerAttachRestoreTests.swift`
- Test: `AlasTests/ACP/Session/ACPSessionRunnerQueueTests.swift` or a focused runner test file

- [ ] **Step 1: Write failing classifier tests**

Create tests:

```swift
@Suite("ACPAuthFailure")
struct ACPAuthFailureTests {
    @Test("classifies JSON-RPC authentication failures")
    func classifiesAuthenticationMessages() {
        let error = ACPClientError.jsonrpc(.init(code: -32603, message: "Internal error: Failed to authenticate. API Error: 401 Invalid authentication credentials", data: nil))
        #expect(ACPAuthFailure.message(from: error) == "Failed to authenticate. API Error: 401 Invalid authentication credentials")
    }

    @Test("does not classify unrelated failures")
    func ignoresUnrelatedErrors() {
        let error = ACPClientError.jsonrpc(.init(code: -32603, message: "Internal error: file not found", data: nil))
        #expect(ACPAuthFailure.message(from: error) == nil)
    }
}
```

- [ ] **Step 2: Write failing manager auth-state test**

In `ACPSessionManagerAttachRestoreTests.swift`, add a test where initialize returns a terminal auth method and `session/new` throws the 401 error. Assert:

```swift
if case .needsAuth(let methods, let reason) = session.setupState {
    #expect(methods.map(\\.id) == ["claude-ai-login"])
    #expect(reason?.contains("401") == true)
} else {
    Issue.record("Expected needsAuth")
}
#expect(session.agentState == .failed(reasonText))
```

Use the existing `manager(store:client:)`, `scriptInitialize`, and `scriptSessionResult` helpers where possible; add a helper for auth methods if useful.

- [ ] **Step 3: Write failing prompt auth-state test**

Add a runner/manager test where the session is ready, `session.authMethods` has a terminal method, and `connection.prompt` throws the same auth error. Assert:

```swift
if case .needsAuth(let methods, let reason) = session.setupState {
    #expect(methods.first?.id == "claude-ai-login")
    #expect(reason?.contains("401") == true)
} else {
    Issue.record("Expected needsAuth after prompt auth failure")
}
#expect(session.lastError?.contains("prompt failed") == true)
```

- [ ] **Step 4: Run tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPAuthFailureTests -only-testing:AlasTests/ACPSessionManagerAttachRestoreTests test
```

Expected: failures because the classifier and setup state do not exist.

- [ ] **Step 5: Implement classifier**

Create `ACPAuthFailure.swift`:

```swift
import Foundation

enum ACPAuthFailure {
    static func message(from error: Error) -> String? {
        let message: String
        if let clientError = error as? ACPClientError,
           case .jsonrpc(let rpc) = clientError {
            message = rpc.message
        } else if let rpc = error as? JSONRPCError {
            message = rpc.message
        } else {
            message = error.localizedDescription
        }
        let lower = message.lowercased()
        guard lower.contains("auth_required")
            || lower.contains("auth required")
            || lower.contains("failed to authenticate")
            || lower.contains("invalid authentication credentials")
            || lower.contains("unauthorized")
            || lower.contains("401")
        else { return nil }
        return cleaned(message)
    }

    private static func cleaned(_ message: String) -> String {
        let prefix = "Internal error: "
        if message.hasPrefix(prefix) {
            return String(message.dropFirst(prefix.count))
        }
        return message
    }
}
```

- [ ] **Step 6: Implement session auth state**

In `ACPSession.swift`, add:

```swift
@Published var authMethods: [ACPInitializeResult.ACPAuthMethod] = []
```

Extend `SetupState`:

```swift
case needsAuth(methods: [ACPInitializeResult.ACPAuthMethod], reason: String?)
```

- [ ] **Step 7: Implement manager classification**

In `ACPSessionManager.attach`, after initialize:

```swift
let initialized = try await connection.initialize()
session.promptCapabilities = initialized.promptCapabilities
session.authMethods = initialized.authMethods
```

In the outer `catch`, before setting generic failure:

```swift
if let authReason = ACPAuthFailure.message(from: error) {
    session.setupState = .needsAuth(methods: session.authMethods, reason: authReason)
    let full = tail.isEmpty ? authReason : authReason + "\nstderr: " + tail
    session.lastError = full
    session.agentState = .failed(full)
    startedRunner?.stop()
    await connection.shutdown()
    return
}
```

In the `session/load` catch, if `ACPAuthFailure.message(from: error) != nil`, rethrow instead of falling back to `session/new`.

- [ ] **Step 8: Implement runner prompt classification**

In `ACPSessionRunner.sendNow` catch path, when `!wasCancelled` and `ACPAuthFailure.message(from: error)` returns a reason:

```swift
self.session.setupState = .needsAuth(methods: self.session.authMethods, reason: authReason)
self.session.agentState = .failed(authReason)
```

Then preserve existing queue/direct prompt error behavior so queued prompts still show retry and direct prompts still set `lastError`.

- [ ] **Step 9: Run focused tests and commit**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPAuthFailureTests -only-testing:AlasTests/ACPSessionManagerAttachRestoreTests test
```

Expected: PASS.

Commit:

```bash
rtk proxy git add Alas/Sources/ACP/Protocol/ACPAuthFailure.swift Alas/Sources/ACP/Session/ACPSession.swift Alas/Sources/ACP/Session/ACPSessionManager.swift Alas/Sources/ACP/Session/ACPSessionRunner.swift AlasTests/ACP/Protocol/ACPAuthFailureTests.swift AlasTests/ACP/Session/ACPSessionManagerAttachRestoreTests.swift AlasTests/ACP/Session/ACPSessionRunnerQueueTests.swift
rtk proxy git commit -m "feat(acp): surface auth-required state"
```

---

### Task 3: Auth Banner And Terminal Login Launch

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPAuthNudgeBanner.swift`
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/ACP/Adapter/ACPAuthNudgeBannerTests.swift`
- Test: `AlasTests/AgentTerminalLaunchTests.swift`

- [ ] **Step 1: Write failing banner copy tests**

Create `ACPAuthNudgeBannerTests.swift`:

```swift
@Suite("ACPAuthNudgeBanner")
struct ACPAuthNudgeBannerTests {
    @Test("prefers terminal-auth metadata label")
    func labelUsesTerminalMetadata() {
        let method = ACPInitializeResult.ACPAuthMethod.terminalForTesting(
            id: "claude-ai-login",
            name: "Claude Subscription",
            label: "Claude Login"
        )
        #expect(ACPAuthNudgeBannerCopy.buttonTitle(method: method) == "Claude Login")
    }

    @Test("unsupported env auth copy is explicit")
    func unsupportedEnvAuthCopy() {
        #expect(ACPAuthNudgeBannerCopy.unsupportedMessage(agentDisplayName: "Cursor").contains("environment credentials"))
    }
}
```

If a `terminalForTesting` helper is not desired in production, construct the auth method directly with its memberwise initializer.

- [ ] **Step 2: Write failing AppState terminal launch test**

In `AgentTerminalLaunchTests.swift`, add a test that injects `terminalSessionOpener`, calls the new `openACPAuthTerminalTab`, and asserts the startup script includes the quoted command and env assignment:

```swift
var capturedSuffix: String?
let state = AppState(... terminalSessionOpener: { _, _, _, _, _, startupScriptSuffix in
    capturedSuffix = startupScriptSuffix
    return .init(id: "auth-session", foregroundPid: { nil })
})
_ = try state.openACPAuthTerminalTab(
    for: worktree,
    command: .init(command: "/usr/bin/node", args: ["/opt/claude-agent-acp", "--cli"], env: ["A": "B"])
) {}
#expect(capturedSuffix?.contains("A=B") == true)
#expect(capturedSuffix?.contains("/usr/bin/node /opt/claude-agent-acp --cli") == true)
```

- [ ] **Step 3: Run tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPAuthNudgeBannerTests -only-testing:AlasTests/AgentTerminalLaunchTests test
```

Expected: failures because banner and launch API do not exist.

- [ ] **Step 4: Implement auth command resolution**

In `ACPAuthNudgeBanner.swift`, add a small value type:

```swift
struct ACPAuthTerminalCommand: Equatable {
    let command: String
    let args: [String]
    let env: [String: String]

    static func resolve(method: ACPInitializeResult.ACPAuthMethod, fallbackCommand: String) -> ACPAuthTerminalCommand? {
        guard method.kind == .terminal else { return nil }
        if let command = method.terminalAuth?.command, !command.isEmpty {
            return .init(command: command, args: method.terminalAuth?.args ?? method.args ?? [], env: method.env ?? [:])
        }
        let args = method.args ?? []
        guard !args.isEmpty else { return nil }
        return .init(command: fallbackCommand, args: args, env: method.env ?? [:])
    }
}
```

Add `ACPAuthNudgeBannerCopy` with:

```swift
static func message(agentDisplayName: String, reason: String?) -> String
static func unsupportedMessage(agentDisplayName: String) -> String
static func buttonTitle(method: ACPInitializeResult.ACPAuthMethod) -> String
```

- [ ] **Step 5: Implement SwiftUI banner**

Create `ACPAuthNudgeBanner` matching the existing setup banner style. Inputs:

```swift
let agentDisplayName: String
let methods: [ACPInitializeResult.ACPAuthMethod]
let reason: String?
let onSignIn: (ACPInitializeResult.ACPAuthMethod) -> Void
let onReconnect: () -> Void
```

Behavior:

- If a terminal method exists, show `Sign In`/advertised label button.
- If no terminal method exists, show unsupported copy and a `Reconnect` button.
- Use the same quiet pane-level banner styling as `ACPSetupNudgeBanner`.

- [ ] **Step 6: Implement AppState auth terminal launcher**

In `AppState.swift`, add:

```swift
@ObservationIgnored
private var acpAuthTerminalExitHandlers: [String: () -> Void] = [:]
```

Add:

```swift
@discardableResult
func openACPAuthTerminalTab(
    for worktree: Worktree,
    command: ACPAuthTerminalCommand,
    onExit: @escaping () -> Void
) throws -> Tab {
    let suffix = Self.shellCommand(command.command, args: command.args, env: command.env)
    let tab = try openTerminalTab(for: worktree, startupScriptSuffix: suffix)
    if case .terminal(let terminal) = tab {
        acpAuthTerminalExitHandlers[terminal.sessionId] = onExit
    }
    return tab
}
```

Add `shellCommand(command:args:env:)` using the existing `shellQuote` helper:

```swift
let envPrefix = env.sorted(by: { $0.key < $1.key }).map { "\\($0.key)=\\(shellQuote($0.value))" }
return (envPrefix + [shellQuote(command)] + args.map(shellQuote)).joined(separator: " ")
```

In the existing `terminal.onSessionProcessExited` handler, after close-pane handling:

```swift
if let handler = self?.acpAuthTerminalExitHandlers.removeValue(forKey: leafId) {
    handler()
}
```

- [ ] **Step 7: Wire banner into ACPTabView**

In `adapterBanner()`, handle `.needsAuth` before adapter install/update decisions:

```swift
if case .needsAuth(let methods, let reason) = session.setupState {
    ACPAuthNudgeBanner(
        agentDisplayName: state.agent(id: session.agentId)?.displayName ?? session.agentId,
        methods: methods,
        reason: reason,
        onSignIn: { method in launchAuth(method) },
        onReconnect: { Task { await reattach() } }
    )
    return
}
```

Add `launchAuth(_:)`:

```swift
private func launchAuth(_ method: ACPInitializeResult.ACPAuthMethod) {
    guard let spec = ACPLaunchCatalog.spec(for: session.agentId),
          let command = ACPAuthTerminalCommand.resolve(method: method, fallbackCommand: spec.command)
    else { return }
    do {
        _ = try state.openACPAuthTerminalTab(for: worktree, command: command) {
            Task { @MainActor in await reattach() }
        }
    } catch {
        session.lastError = "Failed to launch auth terminal: \\(error.localizedDescription)"
    }
}
```

Update `isConnecting` to return false for `.needsAuth`.

- [ ] **Step 8: Run focused tests and commit**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPAuthNudgeBannerTests -only-testing:AlasTests/AgentTerminalLaunchTests test
```

Expected: PASS.

Commit:

```bash
rtk proxy git add Alas/Sources/ACP/UI/ACPAuthNudgeBanner.swift Alas/Sources/ACP/UI/ACPTabView.swift Alas/Sources/App/AppState.swift AlasTests/ACP/Adapter/ACPAuthNudgeBannerTests.swift AlasTests/AgentTerminalLaunchTests.swift
rtk proxy git commit -m "feat(acp): launch terminal auth from pane"
```

---

### Task 4: Project Regeneration And End-to-End Verification

**Files:**
- Modify: `Alas.xcodeproj/project.pbxproj` if `xcodegen` updates it for new files.
- Review all files touched by prior tasks.

- [ ] **Step 1: Regenerate project**

Run:

```bash
rtk xcodegen
```

Expected: exits 0. New Swift files appear in the generated Xcode project if required.

- [ ] **Step 2: Run ACP-focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPInitializeTests -only-testing:AlasTests/ACPConnectionTests -only-testing:AlasTests/ACPAuthFailureTests -only-testing:AlasTests/ACPSessionManagerAttachRestoreTests -only-testing:AlasTests/ACPAuthNudgeBannerTests -only-testing:AlasTests/AgentTerminalLaunchTests test
```

Expected: PASS.

- [ ] **Step 3: Run required build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: PASS.

- [ ] **Step 4: Run required full tests if feasible**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: PASS. If the suite times out or fails on known unrelated host-specific tests, capture exact failing test names and run the ACP-focused subset plus the quiet build before reporting.

- [ ] **Step 5: Manual adapter handshake sanity check**

Run:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true,"auth":{"terminal":true},"_meta":{"terminal-auth":true}}}}' | rtk claude-agent-acp
```

Expected: response includes terminal `authMethods` when auth methods are available, matching the protocol test fixture shape.

- [ ] **Step 6: Commit verification/project regeneration**

If `xcodegen` changed the project file, commit it:

```bash
rtk proxy git add Alas.xcodeproj/project.pbxproj
rtk proxy git commit -m "chore: regenerate project"
```

If no project file changed, do not create an empty commit.

