# Peer Repo Hook Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A paired Mac that creates a worktree or opens a shell on a host is asked about that host's unapproved repo hook with the local approval sheet. The host never prompts on its own screen for a peer, and it never waits for a human.

**Architecture:** Every peer request carries an optional `RepoHookConsent` (`ask`, `skip`, `approve(hash:)`). The host checks it against the hook in one gate (`AlasCoreContext.gateRepoHook`). An unapproved hook with `ask`, or with a stale hash, is answered with "needs approval" and the hook, and nothing is created or launched. An `approve` whose hash matches the script now on disk is recorded, and the work then goes ahead, running the approved hook through the existing paths. A request with no consent (web, phone, older Macs) keeps today's silent skip, and a skipped create also posts a worktree notice. The Mac answers "needs approval" with `RepoHookApprovalQueue.requestDecision`, which shows the existing sheet, and then sends the same request again with its answer.

**Tech Stack:** Swift 5.9+, SwiftPM `Packages/AlasCore` (AlasPlatform, AlasHostCore), SwiftUI app (`Alas/`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-25-peer-repo-hook-approval-design.md`. Its "Decisions from the builder check" override its Goals.

**Base:** branch from `origin/main` (658f4d109 at planning time), not from the `nacho/host-run-consoles` checkout. That branch's unmerged commits touch `HostConsoles.swift`, so rebase if it lands first.

## Rulings where the spec and the code disagree

1. **Approval rides on the re-sent request; there is no separate approve request.** In the spec, Approve sends an approve request and then the same create again. Creation actually travels as `RemoteClientMessage.createWorktreeSession` through federation, and shell opens travel as `PeerConsoleRequest.open`. Neither is a `HostRequest`, and the Mac's create path has no host channel. So the Mac re-sends the same create or open with `repoHook: .approve(hash:)`. The host re-reads the script, records the approval only if the hash matches, then proceeds. Without a match it answers "needs approval" again with the current hook. This gives the spec's validation (hash, project and event are all the host's own) in one request, with no window where an approval is stored but the create is lost. The gating stays as decided: `HostProtocolCapability.repoHooksApprovalV1` for create and `PeerConsoleCapability.repoHookApprovalV1` for shells.
2. **Ask-first needs the hook before the worktree exists.** `RepoHookLoader` reads from a worktree root, and none exists before creation. The preflight reads the committed hook with `git show <ref>:.alas/hooks/worktree-create.sh`. `<ref>` is `branch` when that branch exists (git checks it out) and `base` otherwise, matching `WorktreeService`'s `worktree add` choice. After creation, the existing `runWorktreeCreateScripts` re-reads the hook from the checkout and runs it only if that hash is approved.
3. **The bug is wider than `createWorktreeSession`.** `HostProtocolServer`'s `.createWorktree` also uses the environment prompter for `.remotePeer` callers, which is the app's sheet on an app host. Both paths go through `finishCreate`, so the fix is one request flag there.
4. **Notices only from `remoteCreateWorktreeSession`.** These go to clients that sent no consent. Goal 4's notices for CLI, agent and scheduled creates are dropped: the builder check says "only for worktree creation … for a client that can't ask", and those callers keep the silent `.skipping`.

## Global Constraints

- Swift Testing only (`import Testing`), no XCTest.
- No SwiftUI, AppKit or WebKit imports, and nothing the app builds outside SwiftPM, in `Packages/AlasCore`. Anything the app or tests use from the package must be `public` (or `@_spi(AppHost)` / `@_spi(Testing)` as the neighbours are).
- Every new public type used across modules or in `@Test(arguments:)` is declared `Sendable` explicitly. Never rely on implicit Sendable.
- No new files in `Alas/` or `AlasTests/`, so there is no `xcodegen` step. A new file in the SwiftPM package is fine, but none is planned.
- The app cannot be built locally, so CI is the first build of every `Alas/` edit. Keep app edits mechanical, and before pushing, grep for every exhaustive switch over a changed enum (each task names the ones known).
- Core tests: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter <Suite>`. Check that the "Test run with N tests" line counts more than zero tests.
- Git stays real in tests. Use `GitTemplate` copies and add only the one commit the hook needs.
- UI copy, verbatim: notice title `Setup hook not run`, body `It needs approval in Alas.`
- Hooks stay capped at `RepoHookLoader.maximumBytes` (256 KiB). An unloadable hook is skipped, never asked about.
- Conventional Commits, with no attribution trailers or footers.

## Review Focus

1. **The hook changes between the preflight and the checkout** (fetch-before-create moves `base`, or a committed symlink resolves differently). Expected: the hook does not run, and the create still succeeds. Pinned by Task 2's stale-hash test on the approve side. The post-create side is the existing `runWorktreeCreateScripts` approval check, which needs no new test.
2. **An approval that can't be saved** (`projects.json` not writable). Expected: the peer gets the "couldn't save this repository hook approval" message as a create refusal, or as `openFailed` for shells, and the hook does not run. `gateRepoHook` throws `RepoHookPreflightError.approvalPersistenceFailed`. Callers map it, and no extra test is needed beyond the type (the existing `persistRepoHookApproval` tests cover revocation).
3. **Projects whose startup mode is `.overrideGlobal` or `.disabled`.** Expected: never ask, never notify. `gateRepoHook` returns `.ready(nil)` before loading. This is pinned in Task 2's no-consent test by its `.disabled` argument.
4. **An older peer that sends no `repoHook` field, and an older host that ignores it.** Expected: today's behaviour in both directions. Task 2 adds a decode test for a `createWorktreeSession` JSON without the field. Shell opens use synthesized `Codable`, which decodes a missing optional associated value as nil.
5. **The same script approved from two Macs, or approved locally meanwhile.** Expected: `approve` on an already-approved hash is `.ready(text)`, not an error. The gate checks `isRepoHookApproved` before it compares consent, which Task 2's approve test covers.

---

## PR 1: `fix(remote): ask the requesting Mac about a worktree's setup hook`

### Task 1: A peer's worktree creation never prompts on the host

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+WorktreeCreation.swift` (`WorktreeCreateRequest`, `finishCreate` call to `runWorktreeCreateScripts`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+RepoHooks.swift` (`runWorktreeCreateScripts`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/AlasHost+RemoteCreation.swift` (`remoteCreateWorktreeSession`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift` (`.createWorktree` case)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift` (extend; it holds `RepoFixture` over a real template repo)

**Interfaces:**
- Produces: `WorktreeCreateRequest.asksAboutRepoHooks: Bool = true`. When false, `finishCreate` passes `prompter: .skipping`.
- Produces: `runWorktreeCreateScripts(project:worktree:includeUserStartupScript:prompter: RepoHookPrompter? = nil)`, which forwards to `preparedRepoHook(prompter:)`.
- Produces (test support, in `HostProtocolServerTests`): `RepoFixture.commitHook(_ event: RepoHookEvent, _ script: String) async throws -> String`. It writes `<main>/.alas/hooks/<event>.sh`, commits it with the test identity, and returns `RepoHookTrust.hash`. Also `AskingEnvironment: AlasHostEnvironment`, which counts `asks` and approves anything it is asked, with `admitsAgent` returning true.

- [ ] **Step 1: Write the failing test**

```swift
/// A peer is never the person at this Mac: its creation must not reach the
/// app's approval sheet, even when the host has one.
@Test func aPeersWorktreeCreationNeverAsksTheHost() async throws {
    let environment = AskingEnvironment()
    let fixture = try await RepoFixture(environment: environment)
    defer { fixture.tearDown() }
    _ = try await fixture.commitHook(.worktreeCreate, "touch hook-ran\n")
    fixture.host.remoteSessionCreator = { _ in .success(RemoteSessionSummary(id: "s", title: "", agentId: "a", status: "idle", canDrive: true)) }

    let result = await fixture.host.remoteCreateWorktreeSession(
        RemoteWorktreeSessionCreation(projectID: fixture.projectID, base: "main", branch: "feature", agentID: "a"),
        caller: .remotePeer(deviceID: "d"))

    guard case .success = result else { Issue.record("\(result)"); return }
    let created = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first { $0.branch == "feature" })
    #expect(environment.asks == 0)
    #expect(!FileManager.default.fileExists(atPath: created.path.appendingPathComponent("hook-ran").path))
}
```

- [ ] **Step 2: Run it and check that it fails**

Run: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter HostProtocolServerTests/aPeersWorktreeCreationNeverAsksTheHost`
Expected: FAIL, with `asks == 1` and `hook-ran` present.

- [ ] **Step 3: Implement**

Add the field and the forwarded prompter. In `remoteCreateWorktreeSession`, replace `creation.cancelledHookApprovalFails = true` with `creation.asksAboutRepoHooks = false`. In `HostProtocolServer`'s `.createWorktree`, build the request as `var` and set `request.asksAboutRepoHooks = promptsForRepoHooks`.

- [ ] **Step 4: Run the suite and check that it passes**

Run: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter HostProtocolServerTests`
Expected: PASS, with a test count above zero.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore
git commit -m "fix(alas-host): never prompt the host's user for a peer's worktree hook"
```

### Task 2: Creation asks first, approves by hash, and notices a skip

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasPlatform/RepoHooks/RepoHook.swift` (add `RepoHookConsent`, `PeerRepoHook`)
- Modify: `Packages/AlasCore/Sources/AlasPlatform/RepoHooks/RepoHookLoader.swift` (add `loadCommitted`, factor the bytes → result step out of `load`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+RepoHooks.swift` (add `RepoHookGate`, `RepoHookApprovalRequired`, `gateRepoHook`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/AlasHost+RemoteCreation.swift` (`RemoteWorktreeSessionCreation.repoHook`, preflight, notice)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteMessageWireJSON.swift` (`RemoteCreateWorktreeSessionResult.needsRepoHookApproval`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift` (client `createWorktreeSession` gains `repoHook`, with the `repoHook` coding key encoded and decoded if present; server case `worktreeSessionNeedsRepoHookApproval(hook:)`, with a `hook` key in the server `CodingKeys` at ~907; `HostProtocolCapability.repoHooksApprovalV1` added to `served`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteSessionGateway.swift:130-147` (bind `repoHook`, forward it, send the new reply)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Federation/FederatedSessionsProvider.swift:156` (map the new reply to `.createWorktree`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Federation/RemoteMessageSessionScope.swift:98,127` (add the new server case to both lists)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift` (extend)
- Test: `AlasTests/Remote/RemoteProtocolTests.swift` (extend; runs in CI only)

**Interfaces:**
- Consumes: Task 1's `asksAboutRepoHooks`, `RepoFixture.commitHook`, `AskingEnvironment`.
- Produces (AlasPlatform, all `public`):
  - `enum RepoHookConsent: Codable, Equatable, Sendable { case ask, skip, approve(hash: String) }`
  - `struct PeerRepoHook: Codable, Equatable, Sendable { let event: RepoHookEvent; let text: String; let hash: String }`, with `init(_ hook: RepoHook)` and `func repoHook(fromHost host: String) -> RepoHook` (source `.remote(host:)`, bytes `Data(text.utf8)`)
  - `static func RepoHookLoader.loadCommitted(event: RepoHookEvent, ref: String, repoPath: URL, host: String?) async -> RepoHookLoadResult`. It runs `Process.gitData(["show", "\(ref):\(event.relativePath)"], cwd: repoPath)`. A non-zero exit means `.missing`. More than `maximumBytes` means `.failed("Hook exceeds the 256 KiB limit")`. Otherwise the result comes from the same UTF-8, empty and hash step `load` uses.
- Produces (AlasHostCore):
  - `public enum RepoHookGate: Equatable, Sendable { case ready(String?); case skippedUnapproved; case needsApproval(PeerRepoHook) }`
  - `public struct RepoHookApprovalRequired: Error, Equatable, Sendable { public let hook: PeerRepoHook }`, used by Task 4.
  - `@_spi(AppHost) public func gateRepoHook(event: RepoHookEvent, project: ProjectConfig, consent: RepoHookConsent?, load: () async -> RepoHookLoadResult) async throws -> RepoHookGate`. Its decisions, in order:
    1. A project whose mode does not inherit the hook (`usesInheritedRepoHook` is false) gets `.ready(nil)`, without loading.
    2. A hook that is missing, empty or fails to load gets `.ready(nil)`.
    3. An approved hook gets `.ready(text)`.
    4. An unapproved hook, by consent:
       - `.approve(h)` with `h == hook.hash`: `persistRepoHookApproval` (which may throw), then `.ready(text)`;
       - `.ask`, or `.approve` with any other hash: `.needsApproval`;
       - `.skip`: `.ready(nil)`;
       - nil: `.skippedUnapproved`.
  - `RemoteWorktreeSessionCreation.repoHook: RepoHookConsent? = nil` (an init parameter with a default)
  - `RemoteCreateWorktreeSessionResult.needsRepoHookApproval(PeerRepoHook)`
  - `RemoteClientMessage.createWorktreeSession(projectId:base:branch:agentId:modelId:effortId:repoHook: RepoHookConsent? = nil)`
  - `RemoteServerMessage.worktreeSessionNeedsRepoHookApproval(hook: PeerRepoHook)`
  - `HostProtocolCapability.repoHooksApprovalV1 = "host.repoHooks.approval.v1"`

- [ ] **Step 1: Write the failing tests** (in `HostProtocolServerTests`. Each one sets `remoteSessionCreator` as in Task 1. Factor that and the create call into a fixture helper `createForPeer(_ consent: RepoHookConsent?) async -> RemoteCreateWorktreeSessionResult`.)

```swift
@Test func aPeerThatMayAskIsSentTheHookAndNothingIsCreated() async throws {
    let fixture = try await RepoFixture()
    defer { fixture.tearDown() }
    let hash = try await fixture.commitHook(.worktreeCreate, "touch hook-ran\n")

    #expect(await fixture.createForPeer(.ask)
        == .needsRepoHookApproval(PeerRepoHook(event: .worktreeCreate, text: "touch hook-ran\n", hash: hash)))
    #expect(!fixture.core.projects.worktrees(projectId: fixture.projectID).contains { $0.branch == "feature" })
}

/// Only the script now on disk can be approved; a stale hash is asked again.
@Test(arguments: [true, false])
func approvingRunsTheHookOnlyForTheScriptOnDisk(hashMatches: Bool) async throws {
    let fixture = try await RepoFixture()
    defer { fixture.tearDown() }
    let hash = try await fixture.commitHook(.worktreeCreate, "touch hook-ran\n")

    let result = await fixture.createForPeer(.approve(hash: hashMatches ? hash : "stale"))

    #expect(fixture.core.projects.isRepoHookApproved(projectId: fixture.projectID, hash: hash) == hashMatches)
    if hashMatches {
        guard case .success = result else { Issue.record("\(result)"); return }
        let created = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first { $0.branch == "feature" })
        #expect(FileManager.default.fileExists(atPath: created.path.appendingPathComponent("hook-ran").path))
        #expect(try String(contentsOf: fixture.projectsFile, encoding: .utf8).contains(hash))
    } else {
        guard case .needsRepoHookApproval(let hook) = result else { Issue.record("\(result)"); return }
        #expect(hook.hash == hash)
    }
}
```

Extend Task 1's test in place, rather than adding a new one. Rename it `aPeerThatCantAskSkipsTheHookWithoutAskingTheHost` and parameterize it as `@Test(arguments: [(nil, true), (.skip, false)] as [(RepoHookConsent?, Bool)])` with `(consent, notices)`. Subscribe with `fixture.host.subscribe(after:)` before creating, following the `worktreeNotice` assertion in `HostSessionsTests:827-845`. Keep its existing asserts, and add:

```swift
// notices: one `.worktreeNotice` with worktreeID == created.id,
// title == "Setup hook not run", body == "It needs approval in Alas."; none otherwise.
```

Add a third argument for Review Focus 3: consent nil on a project whose `startupScripts.worktreeCreateMode = .disabled` (set it on the fixture's project before creating). It expects no notice.

In `AlasTests/Remote/RemoteProtocolTests.swift`, add one test. A `createWorktreeSession` JSON without `repoHook` decodes with `repoHook == nil`, and `.createWorktreeSession(..., repoHook: .approve(hash: "h"))` and `.worktreeSessionNeedsRepoHookApproval(hook:)` round-trip.

- [ ] **Step 2: Run them and check that they fail**

Run: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter HostProtocolServerTests`
Expected: compile failure (`RepoHookConsent`, `PeerRepoHook` and `needsRepoHookApproval` are undefined).

- [ ] **Step 3: Implement the types, `loadCommitted` and `gateRepoHook`** (signatures as in Interfaces).

- [ ] **Step 4: Implement the preflight and notice in `remoteCreateWorktreeSession`**

After the destination preflight and before `worktrees.create`, call `core.gateRepoHook(event: .worktreeCreate, project:, consent: request.repoHook)`. Its `load` is `RepoHookLoader.loadCommitted(event:ref:repoPath: URL(fileURLWithPath: project.path), host: project.host)`, with `ref` set to `branch` if the branches already loaded for the base check contain it, otherwise `base`. Keep that list in a local, so branches are loaded once.

The gate results map as follows:
- `.needsApproval(hook)` returns `.needsRepoHookApproval(hook)`;
- a thrown error returns `refused(error.localizedDescription)`;
- `.skippedUnapproved`, after the worktree is created, calls `noteAttention([.worktreeNotice(HostWorktreeNotice(id: UUID(), worktreeID: worktree.id, title: "Setup hook not run", body: "It needs approval in Alas."))])` and logs at `.notice`.

In `RemoteSessionGateway`, send `.worktreeSessionNeedsRepoHookApproval(hook:)` for the new result, and refresh nothing.

- [ ] **Step 5: Run the suites and check that they pass**

Run: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter 'HostProtocolServerTests|StartupScriptResolverTests'`
Expected: PASS.

- [ ] **Step 6: Find the app's exhaustive switches over the changed enums**

Run: `git grep -n 'createWorktreeSession(\|worktreeSessionCreationFailed\|RemoteCreateWorktreeSessionResult' Alas AlasTests`
Expected: every `switch` either has a `default` or gets the new case. Positional patterns with all bindings, such as `case .createWorktreeSession(let a, …, let f)`, gain one more `_`.

- [ ] **Step 7: Commit**

```bash
git add Packages/AlasCore AlasTests/Remote/RemoteProtocolTests.swift
git commit -m "feat(alas-host): ask a peer about a worktree hook before creating it"
```

### Task 3: The Mac answers a create's hook approval with the local sheet

App only. CI is the first build, so keep these edits mechanical.

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerSessions.swift` (`init`, `createNewWorktreeSession` ~858, `applyNewSessionReply` ~890)
- Modify: `Alas/Sources/App/AppState.swift:1048-1054` (pass the two new closures)
- Modify: `Alas/Sources/App/AppState+PeerConsoles.swift` (add `decidePeerRepoHook`, which Task 5 reuses)
- Test: `AlasTests/Remote/NativePeerSessionsTests.swift` (extend; runs in CI only)

**Interfaces:**
- Consumes: Task 2's `RepoHookConsent`, `PeerRepoHook.repoHook(fromHost:)`, `RemoteServerMessage.worktreeSessionNeedsRepoHookApproval`, `HostProtocolCapability.repoHooksApprovalV1`.
- Produces:
  - `NativePeerSessions.init(..., supportsRepoHookApproval: @escaping @MainActor (_ serverId: String) -> Bool = { _ in false }, decideRepoHook: @escaping @MainActor (_ serverId: String, PeerRepoHook, RepoHookApprovalContext) async -> RepoHookApprovalDecision = { _, _, _ in .skip })`
  - `AppState.decidePeerRepoHook(serverId: String, hook: PeerRepoHook, context: RepoHookApprovalContext) async -> RepoHookApprovalDecision`. It calls `repoHookApprovalQueue.requestDecision(hook: hook.repoHook(fromHost: <peer display name, else serverId>), projectID: "peer:\(serverId)", context: context)`. That shows the existing `RootRepoHookApprovalPresentationHandler` sheet, with no new UI.

- [ ] **Step 1: Write the failing test**

```swift
@Test(arguments: [RepoHookApprovalDecision.approve, .skip])
func aCreateWaitingOnHookApprovalIsSentAgainWithTheAnswer(_ decision: RepoHookApprovalDecision) async throws {
    // startedClientWithPeerRepo, with supportsRepoHookApproval { _ in true } and decideRepoHook returning `decision`
    client.createNewWorktreeSession(base: "main", branch: "feature/x", agentId: "claude", modelId: nil, effortId: nil)
    #expect(links.sent(to: "B").last == .createWorktreeSession(
        projectId: "p", base: "main", branch: "feature/x", agentId: "claude", repoHook: .ask))
    let hook = PeerRepoHook(event: .worktreeCreate, text: "echo hi\n", hash: "h")
    links.receive(.worktreeSessionNeedsRepoHookApproval(hook: hook), from: "B")
    // poll with the suite's existing helper until the re-send arrives
    #expect(links.sent(to: "B").last == .createWorktreeSession(
        projectId: "p", base: "main", branch: "feature/x", agentId: "claude",
        repoHook: decision == .approve ? .approve(hash: "h") : .skip))
    #expect(client.newSession?.phase == .creating)
}
```

`startedClientWithPeerRepo` probably needs optional parameters for the two closures. Add them with the same defaults as the `init`.

- [ ] **Step 2: Implement**

`createNewWorktreeSession` sends `repoHook: supportsRepoHookApproval(serverId) ? .ask : nil`. On `.worktreeSessionNeedsRepoHookApproval(hook)` for the live token, start a `Task` that awaits `decideRepoHook(serverId, hook, .worktreeCreate)`. Stop if the token changed meanwhile. Map `.approve` to `.approve(hash: hook.hash)` and `.skip` to `.skip`. Any other answer sets `phase = .editing` and stops. Re-send the same create through the request path `createNewWorktreeSession` uses, with the same reply handler, while `phase` stays `.creating`. Wire the closures in `AppState.syncRemotePeers`. The capability check is `remotePeers.capabilities[serverId]?.contains(HostProtocolCapability.repoHooksApprovalV1) == true`.

- [ ] **Step 3: Check the call sites**

Run: `git grep -n 'NativePeerSessions(' Alas AlasTests`
Expected: no call site needs changes, since the new parameters have defaults.

- [ ] **Step 4: Commit and let CI build**

```bash
git add Alas AlasTests
git commit -m "feat(remote): approve a host's worktree hook from the Mac that creates it"
```

---

## PR 2: `feat(alas-host): run session-open hooks in peer shells, approved from the Mac`

### Task 4: Headless shells run the full session-open script, gated by approval

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/PeerConsoleProtocol.swift` (`PeerConsoleCapability.repoHookApprovalV1`, added to `appHost` and `headlessHost`; `PeerConsoleRequest.open(requestId:worktreeId:repoHook: RepoHookConsent? = nil)`; `PeerConsoleEvent.openNeedsRepoHookApproval(requestId: String, hook: PeerRepoHook)`, which joins `.list`, `.opened` and `.openFailed` in `attachmentId`'s nil arm)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/PeerConsoleHost.swift:63,82,158,259-285` (`Environment.open` takes the consent; `open` catches `RepoHookApprovalRequired` and sends the new event)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostConsoles.swift:205-245,358` (`open(worktreeId:repoHook:)`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteSessionGateway.swift:604` (pattern `.open(let requestId, _, _)`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostConsolesTests.swift` (extend)

**Interfaces:**
- Consumes: Task 2's `gateRepoHook`, `RepoHookGate`, `RepoHookApprovalRequired`, `RepoHookConsent`, `PeerRepoHook`.
- Produces:
  - `PeerConsoleCapability.repoHookApprovalV1 = "peerConsoleRepoHookApproval.v1"`
  - `PeerConsoleHost.Environment.open: (@MainActor (_ worktreeId: String, _ repoHook: RepoHookConsent?) async throws -> String)?`. It throws `PeerConsoleOpenError` or `RepoHookApprovalRequired`.
  - `HostConsoles.open(worktreeId: String, repoHook: RepoHookConsent? = nil) async throws -> String`
- Test fixture: `HostConsolesTests.Fixture.init` gains `configuration: AppConfig = .defaults` (passed as `HeadlessHostEnvironment(configuration:)`) and a scratch `projectsFile: root.appendingPathComponent("projects.json")`. Without the scratch file, an approval would write the real `Paths.projectsFile`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aShellOpenWaitsForApprovalOfItsSessionOpenHook() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let hash = try fixture.writeHook("echo hook\n")   // worktree/.alas/hooks/session-open.sh; returns RepoHookTrust.hash
    let consoles = fixture.consoles()

    await #expect(throws: RepoHookApprovalRequired(hook: PeerRepoHook(event: .sessionOpen, text: "echo hook\n", hash: hash))) {
        try await consoles.open(worktreeId: fixture.worktree.id, repoHook: .ask)
    }
    #expect(fixture.launches.isEmpty)
    #expect(consoles.summaries().isEmpty)
}

/// Global, then the approved repo hook, then the project's own script, as
/// the app's terminals run them; without approval the hook is left out.
@Test(arguments: [true, false])
func aShellRunsTheSessionOpenScript(approves: Bool) async throws {
    var config = AppConfig.defaults
    config.terminal.startupScript = "echo global"
    let fixture = try Fixture(configuration: config)   // project: sessionOpenMode .appendToGlobal, script "echo project"
    defer { fixture.tearDown() }
    let hash = try fixture.writeHook("echo hook\n")

    _ = try await fixture.consoles().open(worktreeId: fixture.worktree.id, repoHook: approves ? .approve(hash: hash) : nil)

    let launch = try #require(fixture.launches.first)
    let rc = try String(contentsOfFile: #require(launch.environment["ZDOTDIR"]) + "/.zshrc", encoding: .utf8)
    #expect(rc.contains(approves ? "echo global\necho hook\necho project" : "echo global\necho project"))
    #expect(fixture.core.projects.isRepoHookApproved(projectId: "p", hash: hash) == approves)
}
```

`openLaunchesAShellAndListsIt` must keep passing unchanged. With no script configured, the launch stays a plain `-l` shell.

- [ ] **Step 2: Run them and check that they fail**

Run: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter HostConsolesTests`
Expected: compile failure (`open(worktreeId:repoHook:)` is undefined).

- [ ] **Step 3: Implement `HostConsoles.open(worktreeId:repoHook:)`**

1. After `admittedWorktree`, look up the worktree's project (`core.projectAndWorktree(withWorktreeId:)`).
2. Call `core.gateRepoHook(event: .sessionOpen, project:, consent: repoHook)`. Its `load` is `core.environment.repoHookLoader.load(event: .sessionOpen, worktreeRoot: worktree.path, host: nil)`. A `.needsApproval(hook)` result throws `RepoHookApprovalRequired(hook:)`. A thrown persistence error becomes `PeerConsoleOpenError(error.localizedDescription)`.
3. Build `script = StartupScriptResolver.sessionOpenScript(global: core.environment.globalTerminalConfig(), repoScript: <.ready text, else nil>, project:)`.
4. If `script` is non-empty and `StartupScriptInstaller.supportsStartupScriptInjection(shell:)`, launch with `StartupScriptInstaller.plan(shell:startupScript: script, sessionId: id)`, the way `launch(_:in:)` does: `shellArguments: plan.args`, merged `plan.envOverrides`, and `defer { if !registered { StartupScriptInstaller.removeArtifacts(sessionId: id) } }` until the entry is appended or recorded. `forget` already removes the artifacts of recorded entries. Otherwise keep today's plain launch.

Update `PeerConsoleHost` and `HostConsoles`' environment closure (`open: { try await self.open(worktreeId: $0, repoHook: $1) }`). Then fix the gateway pattern.

- [ ] **Step 4: Run the suites and check that they pass**

Run: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter 'HostConsolesTests|HostProtocolServerTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore
git commit -m "feat(alas-host): run the approved session-open script in peer shells"
```

### Task 5: App-host peer shells and the Mac's console client use the same flow

App only. CI is the first build. This task must ship in the same PR as Task 4, because Task 4 changes the `PeerConsoleHost.Environment.open` type and an exhaustive switch, which break the app build until updated.

**Files:**
- Modify: `Alas/Sources/App/AppState+PeerConsoles.swift:14-17,26-47` (`openPeerConsole(worktreeId:repoHook:)`; the closure forwards `$1`), `:122-150` (`makeNativePeerConsoles` passes the two new closures)
- Modify: `Alas/Sources/Remote/Native/NativePeerConsoles.swift` (`init`, `openTerminal` ~197, `receive` ~133-145)
- Modify: `Alas/Sources/Remote/Native/PeerConsoleViewer.swift:443` (add `.openNeedsRepoHookApproval` to the ignored arm)
- Test: `AlasTests/PeerConsoleClientTests.swift` (extend; runs in CI only)

**Interfaces:**
- Consumes: Task 4's `PeerConsoleCapability.repoHookApprovalV1`, `PeerConsoleEvent.openNeedsRepoHookApproval`, and the consent-taking `open`. Task 3's `AppState.decidePeerRepoHook`. Task 2's `gateRepoHook`.
- Produces: `NativePeerConsoles.init(..., supportsRepoHookApproval: @escaping @MainActor (String) -> Bool = { _ in false }, decideRepoHook: @escaping @MainActor (String, PeerRepoHook, RepoHookApprovalContext) async -> RepoHookApprovalDecision = { _, _, _ in .skip })`

- [ ] **Step 1: Write the failing test**

```swift
@Test(arguments: [RepoHookApprovalDecision.approve, .skip, .cancel])
func anOpenWaitingOnHookApprovalIsSentAgainWithTheAnswer(_ decision: RepoHookApprovalDecision) async throws {
    // consoles built as the suite does, with supportsRepoHookApproval { _ in true } and decideRepoHook returning `decision`
    consoles.openTerminal(serverId: "srv", worktreeId: "w")
    guard case .console(.open(let first, "w", .ask))? = sent.last else { Issue.record("\(sent)"); return }
    consoles.receive(serverId: "srv", .openNeedsRepoHookApproval(requestId: first, hook: PeerRepoHook(event: .sessionOpen, text: "x", hash: "h")))
    // poll with the suite's helper
    switch decision {
    case .approve: // last sent is .console(.open(<new id>, "w", .approve(hash: "h")))
    case .skip:    // last sent is .console(.open(<new id>, "w", .skip))
    default:       // nothing more sent, and no error shown
    }
}
```

- [ ] **Step 2: Implement**

`openTerminal` sends `repoHook: supportsRepoHookApproval(serverId) ? .ask : nil`. On `.openNeedsRepoHookApproval` for a pending request, clear that request id. Then await `decideRepoHook(serverId, hook, .sessionOpen)`, and for `.approve` or `.skip` send a fresh `.open` with a new pending id. `.cancel` drops it silently.

`AppState.openPeerConsole(worktreeId:repoHook:)` first runs `core.gateRepoHook(event: .sessionOpen, project:, consent: repoHook) { await core.environment.repoHookLoader.load(event: .sessionOpen, worktreeRoot: worktree.path, host: project.host) }`. A `.needsApproval(hook)` result throws `RepoHookApprovalRequired(hook:)`. Then it keeps the existing `openTerminalTabPreparingRemoteZmxIfNeeded(..., promptsForRepoHooks: false)` call, which now runs the just-approved hook. Rethrow `RepoHookApprovalRequired` before the existing `catch` turns errors into `PeerConsoleOpenError`.

The capability check is `remotePeers.capabilities[serverId]?.contains(PeerConsoleCapability.repoHookApprovalV1) == true`.

- [ ] **Step 3: Check the call sites and switches**

Run: `git grep -n 'NativePeerConsoles(\|PeerConsoleHost(environment\|case .inputAck, .list, .opened\|open: {' Alas AlasTests`
Expected: each site compiles against the new signatures. Existing `.open(requestId:worktreeId:)` test calls are fine because of the default.

- [ ] **Step 4: Commit and let CI build**

```bash
git add Alas AlasTests
git commit -m "feat(remote): approve a host shell's session-open hook from the Mac"
```

---

## Self-review

- **Spec coverage:**
  - Ask-first create: Task 2.
  - Approve and Skip re-send: Tasks 3 and 5.
  - Combined script order: unchanged `runWorktreeCreateScripts` for creates; `sessionOpenScript` for shells in Task 4.
  - No host sheet for peers: Task 1, plus Task 5 (the app host shell path gates before opening the tab).
  - Silent skip and notice for clients that can't ask: Task 2.
  - Headless shells run the full script: Task 4.
  - Capability gating: Tasks 2 and 4 advertise; Tasks 3 and 5 check.
  - No failure UI: unloadable hooks are `.ready(nil)`.
  - Non-goals untouched: run consoles keep `request.command` only; workspace hooks unchanged.
- **Types:** `RepoHookConsent`, `PeerRepoHook`, `RepoHookGate`, `RepoHookApprovalRequired`, `gateRepoHook(event:project:consent:load:)` and `decidePeerRepoHook(serverId:hook:context:)` are named the same in every task.
- **Tests:** 4 new core tests, 2 of them parameterized. Task 1's test is extended rather than duplicated. There are 3 CI-only app tests, and the protocol one is a single round-trip.
