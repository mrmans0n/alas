# Remote Web Worktree Creation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a paired Alas Remote browser create a worktree from configured repository defaults and immediately open an ACP session in it.

**Architecture:** Extend the typed WebSocket protocol with repository, branch, and combined-creation messages. Keep Git, path, startup-script, and agent policy in `AppState`; keep `RemoteSessionGateway` as the asynchronous coordinator; isolate the browser wizard's pure transitions in a testable JavaScript module used by `app.js`.

**Tech Stack:** Swift 5.9, Swift Testing, SwiftUI-hosted static HTML/CSS/JavaScript, Node.js `assert`, Git worktrees over local or SSH-aware existing services.

**Design spec:** `docs/plans/2026-09-05-remote-web-worktree-creation-design.md`

---

## File map

- `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift`: wire DTOs and provider result enums for repositories, branches, and combined creation.
- `Alas/Sources/Remote/Protocol/RemoteProtocol.swift`: client/server WebSocket cases and Codable dispatch.
- `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift`: app capabilities exposed to a connection gateway.
- `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift`: generation-guarded list requests and combined-creation response mapping.
- `Alas/Sources/App/AppState.swift`: authoritative repository lookup, branch validation, destination rendering, worktree creation, and session creation.
- `Alas/Resources/RemoteWeb/worktree-creation.js`: pure creation-wizard state transitions.
- `Alas/Resources/RemoteWeb/app.js`: DOM rendering, WebSocket requests, reconnect recovery, and success/failure handling.
- `Alas/Resources/RemoteWeb/index.html`: new-worktree form controls and script loading.
- `Alas/Resources/RemoteWeb/style.css`: compact responsive form styles.
- `Alas/Resources/RemoteWeb/sw.js`: cache names and new asset revision.
- `AlasTests/Remote/RemoteProtocolTests.swift`: wire round-trip coverage.
- `AlasTests/Remote/RemoteAppStateAccessTests.swift`: app policy and orchestration coverage.
- `AlasTests/Remote/RemoteSessionGatewayTests.swift`: gateway routing, generation, and partial-success coverage.
- `AlasTests/Remote/RemoteWebAssetTests.swift`: static asset wiring and cache-version assertions.
- `AlasTests/SSH/SSHIntegrationTests.swift`: opt-in localhost SSH coverage for branch discovery and creation.
- `scripts/tests/remote-web-worktree-creation/run.sh`: focused JavaScript test runner.
- `scripts/tests/remote-web-worktree-creation/test-worktree-creation.js`: wizard transition tests.

### Task 1: Add the remote worktree-creation wire contract

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift`
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift`
- Modify: `AlasTests/Remote/RemoteProtocolTests.swift`

- [ ] **Step 1: Write failing protocol round-trip tests**

Add focused tests for all new cases. Assert exact JSON keys, not only enum equality:

```swift
@Test func worktreeCreationMessagesRoundTrip() throws {
    let listBranches = RemoteClientMessage.listBranches(projectId: "project-1")
    #expect(try roundTrip(listBranches) == listBranches)

    let create = RemoteClientMessage.createWorktreeSession(
        projectId: "project-1",
        base: "origin/main",
        branch: "feature/remote-create",
        agentId: "codex"
    )
    #expect(try roundTrip(create) == create)
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(create)) as? [String: Any]
    )
    #expect(object["type"] as? String == "createWorktreeSession")
    #expect(object["projectId"] as? String == "project-1")

    let projects = [RemoteProjectOption(id: "project-1", name: "alas")]
    let projectList = RemoteServerMessage.projectList(projects: projects)
    #expect(try roundTrip(projectList) == projectList)
    let branchList = RemoteServerMessage.branchList(
        projectId: "project-1", branches: ["main"], preferredBase: "main"
    )
    #expect(try roundTrip(branchList) == branchList)
    let branchFailure = RemoteServerMessage.branchListFailed(
        projectId: "project-1", message: "Could not load branches."
    )
    #expect(try roundTrip(branchFailure) == branchFailure)
    let createFailure = RemoteServerMessage.worktreeSessionCreationFailed(
        stage: .session,
        message: "Worktree created, but the session could not be created.",
        worktreeId: "/tmp/alas-feature"
    )
    #expect(try roundTrip(createFailure) == createFailure)
}
```

Also assert decoding fails when `projectId`, `base`, `branch`, `agentId`, or `stage` is missing or invalid.

- [ ] **Step 2: Run the protocol tests and confirm the new cases fail to compile**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteProtocolTests
```

Expected: FAIL because the new protocol cases and DTOs do not exist.

- [ ] **Step 3: Add the wire DTOs and result vocabulary**

In `RemoteMessageWireJSON.swift`, add:

```swift
struct RemoteProjectOption: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

enum RemoteWorktreeSessionCreationStage: String, Codable, Equatable, Sendable {
    case worktree
    case session
}

enum RemoteBranchListResult: Equatable, Sendable {
    case success(branches: [String], preferredBase: String)
    case failure(String)
}

enum RemoteCreateWorktreeSessionResult: Equatable, Sendable {
    case success(RemoteSessionSummary)
    case failure(
        stage: RemoteWorktreeSessionCreationStage,
        message: String,
        worktreeId: String?
    )
}
```

Add client cases `listProjects`, `listBranches(projectId:)`, and `createWorktreeSession(projectId:base:branch:agentId:)`. Add server cases `projectList`, `branchList`, `branchListFailed`, `worktreeSessionCreated`, and `worktreeSessionCreationFailed`. Extend coding keys and both Codable switches with the exact lower-camel-case wire names from the spec. Do not classify these as control messages or drive-ordering messages.

- [ ] **Step 4: Run the protocol tests**

Run the command from Step 2.

Expected: PASS with all `RemoteProtocolTests` passing.

- [ ] **Step 5: Commit the protocol contract**

```bash
git add Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift Alas/Sources/Remote/Protocol/RemoteProtocol.swift AlasTests/Remote/RemoteProtocolTests.swift
git commit -m "feat(remote): add worktree creation protocol"
```

### Task 2: Expose remote repository and branch catalogs

**Files:**
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `AlasTests/Remote/RemoteAppStateAccessTests.swift`
- Modify: `AlasTests/Remote/RemoteSessionGatewayTests.swift`
- Modify: `AlasTests/SSH/SSHIntegrationTests.swift`

- [ ] **Step 1: Add failing `AppState` catalog tests**

Cover stable project IDs/names, missing projects, branch ordering, preferred-base reuse, local repositories, and SSH-aware dispatch through the existing `Process.git`/`RemoteHostRegistry` path. The core expectations are:

```swift
let projects = await state.remoteProjects()
#expect(projects == [RemoteProjectOption(id: project.id, name: project.name)])

let result = await state.remoteBranches(projectId: project.id)
guard case .success(let branches, let preferredBase) = result else {
    Issue.record("expected branch list success")
    return
}
#expect(branches.contains("main"))
#expect(preferredBase == "main")

#expect(await state.remoteBranches(projectId: "missing") == .failure("Repository is no longer available."))
```

Use a temporary Git repository for the local success case. Add an opt-in test to `SSHIntegrationTests` that creates a temporary repository, registers its path with host `localhost`, builds an `AppState` containing that remote project, and calls `remoteBranches`. The suite already requires `ALAS_SSH_INTEGRATION=1` and key-authenticated localhost SSH. Always unregister the path and remove temporary repositories in `defer`. Combined SSH creation belongs to Task 3, after that API exists.

- [ ] **Step 2: Run the `AppState` remote-access tests and verify failure**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteAppStateAccessTests
```

Expected: FAIL because `remoteProjects()` and `remoteBranches(projectId:)` are missing.

- [ ] **Step 3: Extend the provider and its test fake**

Add these requirements to `RemoteSessionsProvider`:

```swift
func remoteProjects() async -> [RemoteProjectOption]
func remoteBranches(projectId: String) async -> RemoteBranchListResult
```

Add storage, call counters, optional continuations, and implementations to `FakeSessionsProvider` in `RemoteSessionGatewayTests.swift`. This keeps the test target compiling before gateway routing is added.

- [ ] **Step 4: Implement the `AppState` catalog methods**

Place them beside `remoteWorktrees()`:

```swift
func remoteProjects() async -> [RemoteProjectOption] {
    projects.map { RemoteProjectOption(id: $0.id, name: $0.name) }
}

func remoteBranches(projectId: String) async -> RemoteBranchListResult {
    guard let project = projects.first(where: { $0.id == projectId }) else {
        return .failure("Repository is no longer available.")
    }
    do {
        let branches = try await GitService().branches(at: URL(fileURLWithPath: project.path))
        return .success(
            branches: branches,
            preferredBase: NewWorktreeDialog.preferredBaseBranch(
                availableBranches: branches,
                configuredDefault: config.worktrees.baseBranch
            )
        )
    } catch {
        Self.logger.error("Remote branch loading failed: \(String(describing: error), privacy: .public)")
        return .failure("Could not load branches.")
    }
}
```

Do not duplicate SSH handling. `Process.git` already resolves `RemoteHostRegistry` for the project path. Never put raw Git or SSH stderr in `RemoteBranchListResult`; it may contain host paths or credentials.

- [ ] **Step 5: Run the focused tests**

Run the command from Step 2.

Expected: PASS for local, missing-project, and preferred-base coverage.

When key-authenticated localhost SSH is available, also run:

```bash
ALAS_SSH_INTEGRATION=1 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/SSHIntegrationTests
```

Expected: PASS, including remote branch discovery. If localhost SSH is unavailable, record that the opt-in suite was not run; the default full suite keeps it disabled.

- [ ] **Step 6: Commit the catalogs**

```bash
git add Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift Alas/Sources/App/AppState.swift AlasTests/Remote/RemoteAppStateAccessTests.swift AlasTests/Remote/RemoteSessionGatewayTests.swift AlasTests/SSH/SSHIntegrationTests.swift
git commit -m "feat(remote): expose repository branch catalogs"
```

### Task 3: Implement authoritative combined creation in `AppState`

**Files:**
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `AlasTests/Remote/RemoteAppStateAccessTests.swift`
- Modify: `AlasTests/Remote/RemoteSessionGatewayTests.swift`
- Modify: `AlasTests/SSH/SSHIntegrationTests.swift`

- [ ] **Step 1: Add failing creation-policy tests**

Add tests that call `createRemoteWorktreeSession(projectId:base:branch:agentId:)` and cover:

- missing project;
- disabled, missing, or non-ACP agent before Git work starts;
- invalid branch name;
- base absent from a freshly loaded branch list;
- destination already present;
- destination already present on an SSH host;
- successful real worktree creation and ACP tab/session activation;
- configured path rendering and startup enabled;
- mapping `.failure(.session, ..., worktreeId: newWorktree.id)` without deleting the created worktree.

Use temporary repositories and the existing `remoteSessionAttachScheduler` to avoid launching a real ACP process. Test the partial-success mapping through a small internal result-mapping helper fed a failed `RemoteCreateSessionResult`; gateway-level behavior will also be covered in Task 4.

Extend `SSHIntegrationTests` with an opt-in combined-creation test. Register the temporary repository for `localhost`, configure the path template to another temporary directory, install an enabled ACP agent plus `remoteSessionAttachScheduler`, then assert that the remote worktree exists and the returned summary points at it. This test is disabled unless `ALAS_SSH_INTEGRATION=1` is set.

Example success assertion:

```swift
let result = await state.createRemoteWorktreeSession(
    projectId: project.id,
    base: "main",
    branch: "feature/from-phone",
    agentId: "claude"
)

guard case .success(let summary) = result else {
    Issue.record("expected combined creation success")
    return
}
#expect(summary.worktree?.branch == "feature/from-phone")
let path = try #require(summary.worktree?.path)
#expect(state.selectedWorktreeId == Worktree.makeId(path: URL(fileURLWithPath: path)))
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteAppStateAccessTests
```

Expected: FAIL because the combined provider method is missing.

- [ ] **Step 3: Add the provider requirement and fake implementation**

```swift
func createRemoteWorktreeSession(
    projectId: String,
    base: String,
    branch: String,
    agentId: String
) async -> RemoteCreateWorktreeSessionResult
```

Extend `FakeSessionsProvider` with keyed results and captured requests so Task 4 can test gateway routing.

- [ ] **Step 4: Implement validation and creation in `AppState`**

Add the method beside `createRemoteSession`. Its order is important:

1. Resolve the project and validate the ACP-capable agent using the same catalog as `createRemoteSession`.
2. Validate `branch` through `GitNameValidator`.
3. Call `GitService().branches` again and require `base` to occur in the returned list.
4. Render the destination with `config.worktrees.pathTemplate`, `rootPath`, project name, and branch, then normalize it with `preparedCreateWorktreeDestination` so `~` resolves to the SSH user's home for remote projects.
5. Reject an existing destination before calling `createWorktreeAndWait`. Use `FileManager.fileExists` locally and `RemoteExec.run(..., command: "test -e <shell-quoted-path>")` for an SSH project. Treat a remote existence-check transport failure as a fixed browser-safe worktree error instead of assuming the path is free.
6. Call `createWorktreeAndWait(..., runStartup: true, ggWorktreeMode: .inherit)`.
7. On worktree success, call `createRemoteSession(worktreeId:agentId:)` and map its result without deleting the worktree.

Keep the local/SSH existence behavior in one helper:

```swift
private func remoteCreationDestinationExists(
    project: ProjectConfig,
    destination: URL
) async throws -> Bool {
    guard let host = project.host ?? RemoteHostRegistry.shared.host(forPath: project.path) else {
        return FileManager.default.fileExists(atPath: destination.path)
    }
    let command = "test -e \(Self.shellQuote(destination.path))"
    let result = try await RemoteExec.run(host: host, cwd: nil, command: command)
    switch result.exitCode {
    case 0: return true
    case 1: return false
    default: throw RemoteWorktreeDestinationCheckError()
    }
}

private struct RemoteWorktreeDestinationCheckError: LocalizedError {
    var errorDescription: String? { "Could not check the worktree destination." }
}
```

Test that shell metacharacters and spaces in the destination stay inside the quoted `test -e` argument. The opt-in localhost SSH test covers both an absent and an existing remote destination.

Use a pure internal mapper for the non-transactional final step:

```swift
nonisolated static func remoteWorktreeSessionResult(
    worktree: Worktree,
    sessionResult: RemoteCreateSessionResult
) -> RemoteCreateWorktreeSessionResult {
    switch sessionResult {
    case .success(let summary):
        return .success(summary)
    case .failure(let message):
        return .failure(
            stage: .session,
            message: "Worktree created, but the session could not be created: \(message)",
            worktreeId: worktree.id
        )
    }
}
```

Return `.worktree` failures for every pre-session validation or worktree failure. Keep detailed command output in existing logs and return localized user-facing messages. For an existing destination, return `A worktree already exists at this path.` For an unexpected `createWorktreeAndWait` failure, log `WorktreeCreationFailure.message` and return the fixed text `Could not create worktree.`; do not put the underlying Git message on the wire.
If the fresh branch lookup itself fails, log the underlying error and return the same fixed `Could not load branches.` text used by `remoteBranches`; do not return raw Git or SSH stderr.

- [ ] **Step 5: Run the focused tests**

Run the command from Step 2.

Expected: PASS, including the real Git worktree and partial-success mapper cases.

When key-authenticated localhost SSH is available, also run:

```bash
ALAS_SSH_INTEGRATION=1 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/SSHIntegrationTests
```

Expected: PASS, including remote branch discovery and combined worktree-session creation. If localhost SSH is unavailable, record that the opt-in suite was not run; the default full suite keeps it disabled.

- [ ] **Step 6: Commit app-side creation**

```bash
git add Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift Alas/Sources/App/AppState.swift AlasTests/Remote/RemoteAppStateAccessTests.swift AlasTests/Remote/RemoteSessionGatewayTests.swift AlasTests/SSH/SSHIntegrationTests.swift
git commit -m "feat(remote): create worktree sessions"
```

### Task 4: Route catalogs and combined creation through the gateway

**Files:**
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift`
- Modify: `AlasTests/Remote/RemoteSessionGatewayTests.swift`

- [ ] **Step 1: Add failing gateway tests**

Cover:

- `listProjects` emits `projectList`;
- `listBranches` emits `branchList` or `branchListFailed` with the requested project ID;
- a second project/branch list request suppresses a paused older response;
- combined creation forwards every field exactly once;
- success emits `worktreeSessionCreated`, then refreshes session and worktree lists;
- worktree failure emits the stage and no worktree ID;
- session failure emits the stage and created worktree ID, then refreshes worktrees.

Use `FakeSessionsProvider` continuations to pause the first request, as current worktree-list generation tests do.

- [ ] **Step 2: Run the gateway tests and verify failure**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteSessionGatewayTests
```

Expected: FAIL because `RemoteSessionGateway.handle` does not route the new messages.

- [ ] **Step 3: Add generation-guarded refresh methods**

Add separate cancellable tasks and generation counters for project and branch lists. A branch success or failure must carry the captured project ID:

```swift
private func refreshBranchList(projectId: String) {
    branchListGeneration += 1
    let generation = branchListGeneration
    branchListRefresh?.cancel()
    branchListRefresh = Task { @MainActor [weak self] in
        guard let self else { return }
        let result = await provider.remoteBranches(projectId: projectId)
        guard !Task.isCancelled, generation == branchListGeneration else { return }
        switch result {
        case .success(let branches, let preferredBase):
            send(.branchList(projectId: projectId, branches: branches, preferredBase: preferredBase))
        case .failure(let message):
            send(.branchListFailed(projectId: projectId, message: message))
        }
    }
}
```

Cancel both new tasks in `close()`.

- [ ] **Step 4: Route combined creation and refresh lists**

In `handle`, call the provider and map its result. On success, send `worktreeSessionCreated`, refresh sessions, and refresh worktrees. On all failures, send `worktreeSessionCreationFailed`; refresh worktrees when `worktreeId != nil`.

- [ ] **Step 5: Run the gateway tests**

Run the command from Step 2.

Expected: PASS with no stale project or branch response emitted.

- [ ] **Step 6: Commit gateway coordination**

```bash
git add Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift AlasTests/Remote/RemoteSessionGatewayTests.swift
git commit -m "feat(remote): route worktree session creation"
```

### Task 5: Build and test the browser wizard state module

**Files:**
- Create: `Alas/Resources/RemoteWeb/worktree-creation.js`
- Create: `scripts/tests/remote-web-worktree-creation/run.sh`
- Create: `scripts/tests/remote-web-worktree-creation/test-worktree-creation.js`

- [ ] **Step 1: Write the failing Node tests**

Test the module's public operations:

```javascript
const state = creation.initialState();
const loading = creation.selectProject(state, "project-1");
const stale = creation.applyBranchList(loading, "project-old", ["old"], "old");
assert.deepStrictEqual(stale, loading);

const loaded = creation.applyBranchList(loading, "project-1", ["main"], "main");
assert.equal(creation.canSubmit(loaded, "codex", false), true);

const unknown = creation.disconnect(creation.beginCreate(loaded));
assert.equal(unknown.outcomeUnknown, true);
assert.equal(creation.canRetry(unknown), false);
const recovered = creation.markRecoveryListLoaded(
  creation.markRecoveryListLoaded(unknown, "sessions"),
  "worktrees"
);
assert.equal(creation.canRetry(recovered), true);
```

Also cover forward/back step changes preserving values, missing base, branch failure/retry, agent absence, busy state, and session-stage partial success selecting the returned worktree.

- [ ] **Step 2: Run the script and verify failure**

```bash
scripts/tests/remote-web-worktree-creation/run.sh
```

Expected: FAIL because `worktree-creation.js` does not exist.

- [ ] **Step 3: Implement the pure module**

Use the existing global-export pattern from `session-ordering.js`. Export immutable operations through `globalThis.RemoteWorktreeCreation`. Keep DOM access and WebSocket sending out of this file; the Node test loads it with `require(...)` and then reads the global.

The state must include:

```javascript
{
  mode: "existing", step: "worktree",
  projectId: null, projects: [], branches: [], base: "", branch: "",
  branchStatus: "idle", branchError: "",
  agentId: null, busy: false, error: "",
  outcomeUnknown: false,
  recovery: { sessions: false, worktrees: false },
  createdWorktreeId: null
}
```

Return the identical state object for stale project-scoped branch success or failure so callers can skip rendering.

Make `run.sh` executable with `chmod +x scripts/tests/remote-web-worktree-creation/run.sh` before running it directly.

- [ ] **Step 4: Run the Node tests**

```bash
scripts/tests/remote-web-worktree-creation/run.sh
```

Expected output: `remote web worktree creation tests passed`.

- [ ] **Step 5: Commit the state module**

```bash
git add Alas/Resources/RemoteWeb/worktree-creation.js scripts/tests/remote-web-worktree-creation
git commit -m "feat(remote-web): add worktree creation state"
```

### Task 6: Integrate the new-worktree flow into the remote web sheet

**Files:**
- Modify: `Alas/Resources/RemoteWeb/index.html`
- Modify: `Alas/Resources/RemoteWeb/app.js`
- Modify: `Alas/Resources/RemoteWeb/style.css`
- Modify: `Alas/Resources/RemoteWeb/sw.js`
- Modify: `AlasTests/Remote/RemoteWebAssetTests.swift`

- [ ] **Step 1: Add failing asset integration assertions**

Assert that:

- the worktree list contains a `create-new-worktree` button;
- repository, base, and branch controls have labels and stable IDs;
- `worktree-creation.js` loads before `app.js`;
- `app.js` sends and handles all new message names;
- reconnect requests sessions and worktrees and marks both recovery lists loaded;
- `index.html` and `sw.js` use matching new revisions for `app.js`, `style.css`, and `worktree-creation.js`;
- the service-worker shell cache name is incremented.

- [ ] **Step 2: Run asset and Node tests and verify the asset failure**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteWebAssetTests
scripts/tests/remote-web-worktree-creation/run.sh
```

Expected: Swift asset tests FAIL; Node state tests PASS.

- [ ] **Step 3: Add semantic form markup**

In `index.html`, add the create action to `worktree-step` and a hidden `new-worktree-step` containing labeled repository and base `<select>` elements plus a branch `<input>`. Keep the existing agent step. Use the existing action row rather than nesting another sheet or card.

Load `/worktree-creation.js?v=1` after `session-ordering.js` and before `app.js`.

- [ ] **Step 4: Wire state and WebSocket messages in `app.js`**

Use `RemoteWorktreeCreation` for all new-worktree transitions. Keep existing-session creation unchanged.

On sheet open, request worktrees, agents, and projects. Selecting a repository sends `listBranches`. Render loading, inline error with Retry, or branch options. The final action sends exactly one `createWorktreeSession` request.

Handle `worktreeSessionCreated` through the existing `applyCreatedSession`. Handle worktree-stage failures by returning to the worktree form. Handle session-stage failures by selecting `worktreeId`, returning to the existing list, and showing that the worktree exists.

On disconnect during creation, call the pure module's disconnect transition. On reconnect, send `listSessions` and `listWorktrees`; only enable retry after both responses have marked recovery complete. Do not infer success from a matching branch name.

- [ ] **Step 5: Add compact responsive styles**

Reuse `.sheet-input`, `.create-list`, `.create-actions`, and current color variables. Add only layout needed for field labels, selects, loading/error rows, and the full-width create-new action. Verify at 320 CSS pixels that labels, inputs, Back, Create, and Cancel do not overlap or escape the sheet.

- [ ] **Step 6: Rev all cached assets together**

Increment `app.js` from `v=62`, `style.css` from `v=40`, and the shell cache from `v40`. Add `worktree-creation.js?v=1` to `SHELL_ASSETS`. Update every matching assertion in `RemoteWebAssetTests.swift`; do not leave mixed revisions between `index.html`, `sw.js`, and tests.

- [ ] **Step 7: Run focused web tests**

```bash
scripts/tests/remote-web-worktree-creation/run.sh
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteWebAssetTests
```

Expected: Node prints `remote web worktree creation tests passed`; all `RemoteWebAssetTests` pass.

- [ ] **Step 8: Commit the browser integration**

```bash
git add Alas/Resources/RemoteWeb/index.html Alas/Resources/RemoteWeb/app.js Alas/Resources/RemoteWeb/style.css Alas/Resources/RemoteWeb/sw.js AlasTests/Remote/RemoteWebAssetTests.swift
git commit -m "feat(remote-web): create worktrees with sessions"
```

### Task 7: Verify the complete feature

**Files:**
- Verify only; fix failures in the owning task's files and commit those fixes separately.

- [ ] **Step 1: Run both remote-web Node suites**

```bash
scripts/tests/remote-web-session-ordering/run.sh
scripts/tests/remote-web-worktree-creation/run.sh
```

Expected: both scripts print their passing messages and exit 0.

- [ ] **Step 2: Regenerate the Xcode project**

```bash
xcodegen
```

Expected: project generation completes without errors. Because `RemoteWeb` is a folder resource, the new JavaScript file requires no `project.yml` entry.

- [ ] **Step 3: Build the macOS app**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 4: Run the full test suite**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **` with no failed tests.

- [ ] **Step 5: Exercise the paired browser flow**

With a disposable repository and an enabled ACP agent:

1. Open Alas Remote at a 320-pixel-wide responsive viewport.
2. Open **New session**, choose **Create new worktree**, and change repositories while branch loading is active.
3. Confirm only the final repository's branches appear and Back preserves the entered branch.
4. Create the worktree and confirm the browser opens the new session.
5. Confirm Alas switches to the new worktree and activates the matching ACP tab.
6. Repeat with an invalid branch and an occupied destination; confirm the sheet keeps the input and shows a useful error.
7. Disconnect during creation, reconnect, and confirm lists refresh before Retry becomes available.

- [ ] **Step 6: Check the final diff and history**

```bash
git diff --check main...HEAD
git status --short
git log --oneline main..HEAD
```

Expected: no whitespace errors, no unintended files, and focused commits matching the tasks above.
