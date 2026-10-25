# Shepherds and Schedules on a Headless Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `alas-host` runs the PR shepherd, the stack shepherd and run schedules, relays their alerts to paired Macs, and the Mac shows a host session's shepherd pill read-only.

**Architecture:** Core gains headless defaults (`installDefaultShepherdEffects()`, `installDefaultRunScheduleRunner()`) that only `AlasHost.boot` installs; the app keeps its own installs and shares the moved, UI-free pieces (prompt delivery, session state, notification text, schedule fan-out, `ScheduledAgentTurns`). A headless host replaces `NotificationService.notificationAdder` with a relay: a notification naming a loaded ACP session becomes the existing `.notice`; anything else naming a worktree becomes a new opt-in `.worktreeNotice`. The pill rides an optional field on `HostSessionSummary`.

**Tech Stack:** Swift 5.9+, SwiftPM `Packages/AlasCore` (AlasIntegrations, AlasHostCore, `alas-host`), SwiftUI app (mechanical edits only), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-25-host-shepherds-schedules-design.md`

All paths and line numbers are at `origin/main` 866e26a7f. Start each PR's branch from current `origin/main`.

## Global Constraints

- Swift Testing only (`import Testing`); no XCTest. One behavior per test; `@Test(arguments:)` for variants; no fixed `Task.sleep` waits (reuse `eventually` from `Tests/AlasCoreTests/TestSupport/Eventually.swift`).
- Git stays real; no new git fixtures are needed by this plan (refusal, route and pill tests are pure or use existing fixtures).
- `Packages/AlasCore` must not import SwiftUI, AppKit, WebKit, GhosttyKit, MLX, TreeSitterPack or FffC. Anything the app uses from the package is `public`.
- Core tests: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter <Suite>`; check the `Test run with N tests` line is non-zero.
- The app cannot be built locally: app edits are mechanical (moves, forwarders, one small view), each called out; CI is their first build.
- No new files under `Alas/` or `AlasTests/` (so no `xcodegen`). New core files go under `Packages/AlasCore/Sources/...` (SwiftPM picks them up).
- Conventional Commits; no `Co-Authored-By`, no generated-by footers, no AI notes.
- Anti-goals: no app behaviour change; the host never calls `UNUserNotificationCenter`, never prompts; new wire state ignored by older peers.
- Copy (verbatim):
  - terminal-agent schedule: `"<agent name> runs in a terminal; terminal agents run only in the app."`
  - SSH-project schedule: `"<project name> is on <host>; schedules there run only in the app."`
  - review-prompt schedule: `"The schedule leaves its prompt for review; it runs only in the app."`

## Review Focus

- A profile whose shepherd records point at SSH-project worktrees, served by the host and then handed back to the app: the records must come back byte-for-byte (no removal, escalation, phase or `archivePending` change). Test in Task 3.
- A composition with an empty prompt and `sendsPromptAutomatically == false` only opens the agent; it must not be refused as "leaves its prompt for review". Test in Task 5.
- A Mac that subscribed accepting only `notice` (every Mac before PR B) must never receive `.worktreeNotice`, which it cannot decode. Test in Task 6.
- A notification whose `sessionId` is a run console or worktree id, not an ACP session, must reach the Mac as a worktree notice, not be dropped or sent as a session notice to a session the Mac can't open. Test in Task 6.
- A `HostSessionSummary` from a host without this change (no `shepherd` key), or with a badge this Mac doesn't know, must decode and show no pill. Test in Task 8.

---

## PR A — `feat(alas-host): run the PR and stack shepherds and run schedules on a headless host`

### Task 1: Share the schedule fan-out and scheduled-turn tracking from core

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/Schedules/ScheduledAgentTurns.swift`
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/Schedules/AlasCoreContext+RunSchedules.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift:34-40` (add `scheduledAgentTurns`)
- Modify (app, mechanical): `Alas/Sources/App/AppState+RunSchedules.swift:31-79, 146-195, 605-635, 839-907`
- Test: move three tests from `AlasTests/AppStateRunScheduleTests.swift:1110-1173` into `Packages/AlasCore/Tests/AlasCoreTests/RunSchedulerTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor public final class ScheduledAgentTurns` — the app's class moved verbatim, every method `public`, plus `public init()`, plus the three app statics moved onto it:
    - `public static func scheduledTurn(in messages: [ACPMessage]) -> (messages: ArraySlice<ACPMessage>, successorStarted: Bool)`
    - `public static func finalAgentReply(in messages: ArraySlice<ACPMessage>) -> String?`
    - `public static func reply(in session: ACPSession) async -> String?` (the app's `scheduledTurnReply(in:)`, body unchanged)
  - `AlasCoreContext.scheduledAgentTurns: ScheduledAgentTurns` (`public let`, built in `init`).
  - `extension AlasCoreContext`:
    - `public enum ScheduleTargetResolution { case targets([(project: ProjectConfig, worktree: Worktree)]); case unavailable(String) }`
    - `public func resolveScheduleTargets(_ target: RunScheduleTarget, invocation: RunScheduleInvocation = .scheduled) -> ScheduleTargetResolution` — the app's body with `projects` → `projects.projects`, `projectsManager` → `projects`.
    - `public func runSchedule(_ schedule: RunSchedule, invocation: RunScheduleInvocation, target: @escaping @MainActor (RunSchedule, ProjectConfig, Worktree) async -> RunScheduleRunReport) async -> RunScheduleRunReport` — the app's fan-out (lines 31-79), calling `target` per resolved target; folder filter uses `Self.folderWorktreeCreationMessage`.

- [ ] **Step 1: Move the tests.** Cut `turn(_:_:)`, `scheduledTurnsAreHandedOverWhicheverSideArrivesFirst`, `aScheduledTurnWaitEndsOnTimeoutCancellationAndSessionClose` and `theReportIsTheScheduledTurnsFinalAgentReply` from `AppStateRunScheduleTests` into `RunSchedulerTests`, replacing `AppState.finalAgentReply`/`AppState.scheduledTurn` with `ScheduledAgentTurns.finalAgentReply`/`.scheduledTurn`. Assertions unchanged. Leave `aScheduledTurnsResultBecomesTheFiringOutcome` where it is.
- [ ] **Step 2: Run to see them fail to compile.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter RunSchedulerTests` — Expected: build error, `ScheduledAgentTurns` not found.
- [ ] **Step 3: Create the two core files** with the interfaces above (moves, not rewrites).
- [ ] **Step 4: App forwarders (mechanical).** In `AppState+RunSchedules.swift`: delete the `ScheduledAgentTurns` class (839-907), `scheduledTurn`, `finalAgentReply`, `scheduledTurnReply`, `ScheduleTargetResolution` and `resolveScheduleTargets`; `runSchedule(_:invocation:)` becomes `await core.runSchedule(schedule, invocation: invocation) { await self.runSchedule($0, project: $1, worktree: $2) }`; `scheduledTurnReply(in: session)` call → `ScheduledAgentTurns.reply(in: session)`. `AppState.swift:318` (`let scheduledAgentTurns = ScheduledAgentTurns()`) stays as is and now names the core type. Grep `Alas/` and `AlasTests/` for `resolveScheduleTargets|scheduledTurn(|finalAgentReply|ScheduleTargetResolution` and fix any leftover.
- [ ] **Step 5: Run.** Same command — Expected: PASS, 3 more tests than before in the suite.
- [ ] **Step 6: Commit.** `git commit -m "refactor(schedules): share the schedule fan-out and scheduled-turn tracking from core"`

### Task 2: Share shepherd prompt delivery, session state and notification text from core

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/Shepherd/AlasCoreContext+ShepherdSessions.swift`
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/ShepherdPresentation.swift` (append `ShepherdNotification`)
- Modify (app, mechanical): `Alas/Sources/App/AppState+Shepherd.swift:135-189, 429-450, 452-538`; `Alas/Sources/App/AppState+StackShepherd.swift:204-288`

**Interfaces:**
- Produces:
  - `extension AlasCoreContext`:
    - `public func deliverShepherdPrompt(sessionID: String, worktreeID: String, prompt: ShepherdPrompt, isStillWanted: @MainActor () -> Bool, in manager: ACPSessionManager) async -> ReviewShepherd.Delivery` — the app body from line 143 on (the `guard let worktree/manager` lines stay in the app).
    - `public func shepherdSessionState(sessionID: String, in manager: ACPSessionManager) async -> ShepherdSessionState` — app body from line 171 on.
    - the two private statics `shepherdSessionIsBusy(_:now:)`, `shepherdQueueItemIsDue(_:now:)` move here.
  - `public enum ShepherdNotification` (AlasIntegrations):
    - `public static func review(for event: ReviewShepherd.Event, host: (ShepherdRecord) -> String?) -> (record: ShepherdRecord, escalation: ShepherdEscalation?, title: String, body: String)` — app's `shepherdNotification` + `shepherdReference`, verbatim.
    - `public static func stack(for event: StackShepherd.Event, host: (StackShepherdRecord) -> String?) -> (record: StackShepherdRecord, escalation: ShepherdEscalation?, title: String, body: String)` — app's `stackShepherdNotification` + `reference`, verbatim.

- [ ] **Step 1: Move the code** to the core files above.
- [ ] **Step 2: App forwarders (mechanical).** `deliverShepherdPrompt` keeps its signature: `guard let worktree = worktree(withId: worktreeID), let manager = acpManager(for: worktree) else { return .failed }` then `return await core.deliverShepherdPrompt(…, in: manager)`. `shepherdSessionState` likewise, returning `.missing` when there is no manager. `notifyShepherdEvent` calls `ShepherdNotification.review(for:host:)`; `notifyStackShepherdEvent` calls `ShepherdNotification.stack(for:host:)`. Delete the moved statics. Grep `Alas/` for `shepherdSessionIsBusy|shepherdQueueItemIsDue|stackShepherdNotification|shepherdNotification(` — none may remain.
- [ ] **Step 3: Verify core builds and shepherd suites pass.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter "ReviewShepherdTests|StackShepherdTests"` — Expected: PASS, counts unchanged.
- [ ] **Step 4: Commit.** `git commit -m "refactor(shepherd): share prompt delivery, session state and notices from core"`

### Task 3: A "not served here" outcome for shepherd records

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/ReviewShepherd.swift:125-176` (Effects), `:591-599` (`evaluate`), `:979-984` (`archiveAfterMerge`)
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/StackShepherd.swift:84-143` (Effects), `:559-561` (evaluate guard), `:760` (archive)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ReviewShepherdTests.swift`

**Interfaces:**
- Produces: on both `ReviewShepherd.Effects` and `StackShepherd.Effects`, `public var servesWorktree: @MainActor (_ worktreeID: String) -> Bool`, a trailing init parameter defaulting to `{ _ in true }` (app and test call sites compile unchanged). Semantics: false means the record belongs to another instance (the app); this one never reads, changes, escalates, archives or removes it.

- [ ] **Step 1: Write the failing test** in `ReviewShepherdTests`; give `makeShepherd` a `servesWorktree: @escaping @MainActor (String) -> Bool = { _ in true }` parameter passed to `Effects`,.

```swift
@Test func aRecordInAWorktreeNotServedHereIsLeftAlone() async {
    let request = F.request(threads: [F.trustedThread])
    var delivered: [String] = []
    let shepherd = makeShepherd(request: request, deliverPrompt: { text, _ in
        delivered.append(text); return .delivered
    }, servesWorktree: { _ in false })
    let record = await shepherd.bind(
        sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
        autoFix: true, autoMerge: true, contextRules: nil
    )
    shepherd.start()
    await shepherd.evaluateNow(record.id)
    shepherd.stop()

    #expect(shepherd.records[record.id] == record)
    #expect(delivered.isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter ReviewShepherdTests` — Expected: compile error (`servesWorktree` unknown), then FAIL on `records[record.id] == record` / `delivered` once the parameter exists.
- [ ] **Step 3: Implement.** First line of each shepherd's `evaluate` after the `effects`/record guard: `guard effects.servesWorktree(id.worktreeID) else { dueAt[id] = .distantFuture; return }` (before the `dueAt` floor and the context read, so nothing else runs). `archiveAfterMerge` in both: return before touching `archivePending` when not served. `makeAllDue()` may still reset `dueAt` on start/wake; the guard pushes it back, which is fine.
- [ ] **Step 4: Run.** Same command plus `StackShepherdTests` — Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(shepherd): leave records of worktrees another instance serves untouched"`

### Task 4: Headless shepherd effects, turn completion and host lifecycle

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/Shepherd/AlasCoreContext+HeadlessShepherd.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift:405-434` (`sessionManagerFactory` gains `onTurnCompleted`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Boot.swift:85-104` (install, feed turns), `:112-113` (stop first in `shutdown`)
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift:396-402` (start after projects load)

**Interfaces:**
- Consumes: Task 2's `deliverShepherdPrompt(…in:)`, `shepherdSessionState(sessionID:in:)`, `ShepherdNotification`; Task 3's `servesWorktree`; Task 1's `scheduledAgentTurns`.
- Produces:
  - `public func installDefaultShepherdEffects()` on `AlasCoreContext`, setting both `reviewShepherd.effects` and `stackShepherd.effects`.
  - `public func turnCompleted(_ completion: ACPTurnCompletion)` on `AlasCoreContext`: `scheduledAgentTurns.deliver`, `reviewShepherd.turnCompleted`, `stackShepherd.turnCompleted`.
  - `sessionManagerFactory(config:onChipsObserved:alasTools:onTurnCompleted: ((ACPTurnCompletion) -> Void)? = nil)`, forwarded to `ACPSessionManager(…, onTurnCompleted:)`.
  - `public func startAutomation() async` on `AlasHost`: `await GGAvailability.shared.probe()`, then `reviewShepherd.start()`, `stackShepherd.start()`, `runScheduler.start()` (the runner comes in Task 5).

Effect decisions (bodies are the implementer's):

| Effect | Headless default |
|---|---|
| `servesWorktree` | `projectAndWorktree(withWorktreeId:)?.project.host == nil`; an unresolvable id is **not** served (it may be an SSH worktree the host doesn't list) |
| `worktreeContext` | nil when unresolved or `projects.isWorktreeHidden`; `baseBranch` = `environment.configuration().worktrees.baseBranch`; `isEligible` = `!project.isFolder` (`// ponytail: Workspace checkout members aren't excluded on the host; add a store lookup if one gets shepherded`) |
| stack `worktreeContext.stackName` | `GGWorktreeContextResolver.resolve(...)` with the arguments `AppState.resolveGGWorktreeContext` (`AppState.swift:14161-14182`) passes, `worktreeOverride` from `projects.ggWorktreeMode(projectId:worktreeId:)`, `branch: worktree.branch`; `.active(name)` → name |
| `sessionState` / `deliverPrompt` | `try? environment.sessionManager(for: worktree, in: self)` then Task 2's functions; no manager → `.missing` / `.failed` |
| `rules` | `ShepherdRulesResolver.load(worktreePath:projectSettings: project.shepherd)` |
| `notify` | `ShepherdNotification.review/stack(for:host:)` → `harness.notifications.notifyAlas(body:title:agent:projectId:worktreeId:sessionId:owner:)`; agent from the session's `agentId` via `ACPHarnessBridge.agentKind(for:)`, else `.codex`. No attention-history or external-activity writes. |
| `refreshPaneIfCached` | no-op |
| `archiveWorktreeIfAllowed` | the app's checks (`AppState+Shepherd.swift:552-586`) without the unsaved-tabs check and the in-app posts (those become `shepherdLogger` lines), then `try await WorktreesAPI(core: self).archive(worktree, caller: .cli)`; a throw → `.declined` |
| `loadStack` | as the app (`AppState+StackShepherd.swift:16-20`) |
| `syncStack` / `rebaseStack` | a `GGMutationCoordinator` built per call over `GGService()` and a fresh `GGStackActionState()`, `GGMutationContext` reads from `GGService`/`GitService`, every refresh a no-op; refuse with `GGMutationError.staleConfirmation` while `AlasCoreContext.hasPendingCheckpointRecovery(worktree)`; then the same `startApplying` calls as `RightPaneState.syncGGForCommitPublish`/`rebaseGGForShip` (`RightPaneState.swift:2839-2873`), including the `syncUntilDraft` capability check and the `syncTerminalFailure` throw. `// ponytail: one coordinator per call; stack_ship already serializes per worktree` |

- [ ] **Step 1: Implement** the file and the factory parameter.
- [ ] **Step 2: Wire boot.** In `AlasHost.boot` pass `onTurnCompleted: { completion in Task { @MainActor in builtCore?.turnCompleted(completion) } }`, where `turnCompleted` feeds both shepherds, `scheduledAgentTurns.deliver`, and `await orchestration.childTurnCompleted(completion)` — the same set, in the same order, as the app's `onTurnCompleted` (AppState.swift ~12377-12383, minus `computerUse`). Controller ruling: include `childTurnCompleted`, because delegation on the host shipped in #2199 and without it a parent never gets its child's outcome (wake/notice) on the host; the app already does this, so it's parity, not new behaviour and call `core.installDefaultShepherdEffects()` before `return`. In `shutdown()`, before `isStopping`'s work: `core.reviewShepherd.stop(); core.stackShepherd.stop(); core.runScheduler.stop()`. In `main.swift`'s startup `Task`, `await host.startAutomation()` right after `await host.loadProjectWorktrees()`.
- [ ] **Step 3: Verify.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter "AlasHostTests|HeadlessCLIRouterTests|StackShepherdTests"` — Expected: PASS. Then `swift build --package-path Packages/AlasCore --product alas-host` — Expected: builds.
- [ ] **Step 4: Commit.** `git commit -m "feat(alas-host): run the PR and stack shepherds"`

### Task 5: Headless schedule runner

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Schedules/RunSchedulePresentation.swift` (add `headlessRefusal`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/Schedules/AlasCoreContext+RunSchedules.swift` (Task 1's file)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Boot.swift` (install the runner)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/RunSchedulerTests.swift`

**Interfaces:**
- Consumes: Task 1's `runSchedule(_:invocation:target:)`, `scheduledAgentTurns`, `ScheduledAgentTurns.reply(in:)`.
- Produces:
  - `public static func headlessRefusal(composition: RunScheduleComposition?, projectName: String, projectHost: String?, agentName: String?, agentSpeaksACP: Bool) -> String?` on `RunSchedulePresentation`. Order: SSH host → terminal agent (only with a composition) → review prompt (only with a composition whose trimmed prompt is non-empty and `sendsPromptAutomatically == false`) → nil. Copy is in Global Constraints.
  - `public func installDefaultRunScheduleRunner()` on `AlasCoreContext`: `runScheduler.runner` = `runSchedule(_:invocation:target: runHeadlessScheduleTarget)`.
  - `func runHeadlessScheduleTarget(_ schedule: RunSchedule, project: ProjectConfig, worktree: Worktree) async -> RunScheduleRunReport` (internal).

- [ ] **Step 1: Write the failing test.**

```swift
@Test(arguments: [
    (RunScheduleComposition?.none, String?.none, true, String?.none),           // local script only
    (.none, "mini.local", true, "app is on mini.local; schedules there run only in the app."),
    (.some(.init(prompt: "Go", sendsPromptAutomatically: true)), nil, false,
     "Claude runs in a terminal; terminal agents run only in the app."),
    (.some(.init(prompt: "Go", sendsPromptAutomatically: false)), nil, true,
     "The schedule leaves its prompt for review; it runs only in the app."),
    (.some(.init(prompt: "  ", sendsPromptAutomatically: false)), nil, true, nil), // opens the agent only
    (.some(.init(prompt: "Go", sendsPromptAutomatically: true)), nil, true, nil),
])
func aHostRefusesOnlyTheSchedulesItCannotRunUnattended(
    composition: RunScheduleComposition?, host: String?, speaksACP: Bool, reason: String?
) {
    #expect(RunSchedulePresentation.headlessRefusal(
        composition: composition, projectName: "app", projectHost: host,
        agentName: "Claude", agentSpeaksACP: speaksACP
    ) == reason)
}
```

- [ ] **Step 2: Run to verify it fails.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter RunSchedulerTests` — Expected: compile error, `headlessRefusal` missing.
- [ ] **Step 3: Implement `headlessRefusal`**, run again — Expected: PASS.
- [ ] **Step 4: Implement `runHeadlessScheduleTarget`**, mirroring `AppState.runSchedule(_:project:worktree:)` (`AppState+RunSchedules.swift:197-259`), with these headless pieces:
  - Agent id: `composition.agentId ?? SessionsAPI(core: self).defaultAgent(projectID:worktreeRoot:)` at the origin worktree's path; `agentSpeaksACP` = `ACPLaunchCatalog.spec(for:) != nil`; agent name from `environment.agent(id:)?.displayName ?? id`. Check `headlessRefusal` **before** creating a worktree; a refusal reports and returns `.launchFailed(reason)`, which the scheduler records as a failure and retimes like any other.
  - Worktree: `RunSchedulePlanner.renderBranch`, `GitNameValidator.validateBranchName`, then `WorktreesAPI.withFreeName(projectID:rendered:caller: .cli) { prepared in … try await WorktreesAPI.create(prepared.request, caller: .cli) … }`.
  - Script: `RunScriptStore.discoverScripts(worktreeRoot:remoteHost:)`, the same skipped/already-running outcomes, then `startRun(script, in: worktree, onSettled:)` in a continuation, mapping `RunStart` as the app maps its launch result (`:358-388`).
  - Agent: `scheduledAgentTurns.expect(id)` when `awaitsScheduledTurn` (move that static to `ScheduledAgentTurns` as `public static func awaits(_ prompt: String?, sendsAutomatically: Bool) -> Bool` and have the app call it), set `orchestrationManager(for: worktree)?.pendingModel[id] = composition.modelId`, then `SessionsAPI.start(id, agentID:, in: worktree, promptID: UUID(), prompt: composition.prompt, caller: .cli)`; afterwards the same `lastError`, wait (`AppState.scheduledAgentTurnTimeout`, move it next to `ScheduledAgentTurns`), outcome and `ScheduledAgentTurns.reply(in:)` handling as `scheduledChatSessionOutcome` (`:506-593`). `defer { scheduledAgentTurns.abandon(id) }`.
  - Failures go through one `reportScheduleFailure` that calls `harness.notifications.notifyScheduleFailed(...)` unless `Task.isCancelled`. Every app `inAppNotifications.post` becomes a log line.
- [ ] **Step 5: Install** `core.installDefaultRunScheduleRunner()` in `AlasHost.boot` next to the shepherd install.
- [ ] **Step 6: Verify.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter "RunSchedulerTests|AlasHostTests"` — Expected: PASS.
- [ ] **Step 7: Commit.** `git commit -m "feat(alas-host): fire run schedules"`

### Task 6: Relay notifications to paired Macs, with worktree notices

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Events.swift:26-51` (case), `:54-59` (coding keys), `:61-79` (key), `:84-101` (new struct), `:534-540` (`optInKind`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Attention.swift` (`relayNotifications()`; make `agent(of:)` internal)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+Runs.swift:552-554` (run outcomes on a relaying host)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerHostChannel.swift:54-56` (exhaustive switch only)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Boot.swift` (call `relayNotifications()`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostSessionsTests.swift`

**Interfaces:**
- Produces:
  - `public struct HostWorktreeNotice: Codable, Equatable, Sendable { public var id: UUID; public var worktreeID: String; public var title: String?; public var body: String }` with a public memberwise init.
  - `HostEvent.worktreeNotice(HostWorktreeNotice)`, key `.notice(id)`, `optInKind == "worktreeNotice"`, coding key `"notice"` as `.notice` uses.
  - `public func relayNotifications()` on `AlasHost`: when `core.environment.relaysNotices`, sets `core.harness.notifications.notificationAdder` to a relay. Rule: read `title`, `body`, `userInfo["sessionId"]`, `userInfo["worktreeId"]` synchronously; on the main actor, a `sessionId` with `core.acpSessionOwner(_:)` → publish `.notice(HostNotice(owner:sessionID:agent:title:body:))`; else a `worktreeId` → `.worktreeNotice`; else log and drop. Publish through `noteAttention(_:)`.
  - In `observe`'s `onFinished`: when `environment.relaysNotices`, also `harness.notifications.notifyRunScriptFinished(scriptName:exitCode:projectId:worktreeId:sessionId: record.sessionID ?? worktree.id, runID:)`.

- [ ] **Step 1: Write the failing test** next to `aNoticeOnAHeadlessHostReachesSubscribersAndHoldsTheSessionWaitingUntilItsNextPrompt`, reusing its `Fixture` and `Collected`:

```swift
@Test func aHeadlessHostRelaysEveryNotificationToTheSessionOrWorktreeItNames() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    fixture.host.relayNotifications()
    let id = try await fixture.host.sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
    let received = Collected(fixture.host.subscribe())
    let notifications = fixture.core.harness.notifications
    notifications.notifyAlas(body: "Merged", title: "Merged", agent: .gemini,
        projectId: fixture.worktree.projectId, worktreeId: fixture.worktree.id, sessionId: id)
    notifications.notifyRunScriptFinished(scriptName: "test", exitCode: 1,
        projectId: fixture.worktree.projectId, worktreeId: fixture.worktree.id, sessionId: "console-1", runID: "r")

    try await eventually { await received.events.count { if case .notice(let n) = $0 { n.sessionID == id && n.body == "Merged" } else { false } } == 1 }
    try await eventually { await received.events.contains {
        if case .worktreeNotice(let n) = $0 { n.worktreeID == fixture.worktree.id && n.title == "test finished" } else { false } } }
    #expect(HostEvent.worktreeNotice(.init(id: UUID(), worktreeID: "w", title: nil, body: "")).optInKind == "worktreeNotice")
}
```

(`Fixture` must not set an adder that records an issue for this test; if it does by default, override it before `relayNotifications()`.)

- [ ] **Step 2: Run to verify it fails.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter HostSessionsTests` — Expected: compile error (`relayNotifications`, `.worktreeNotice` missing).
- [ ] **Step 3: Implement** the interfaces; add `.worktreeNotice` to `PeerHostChannel.State.apply`'s ignored cases. Call `host.relayNotifications()` in `AlasHost.boot` after `AlasHost(core:)` is built (assign to a local, call, return).
- [ ] **Step 4: Run.** `… --filter "HostSessionsTests|HostProtocolServerTests|PeerHostChannelTests"` — Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(alas-host): relay shepherd, schedule and run notifications to paired Macs"`

### Task 7: `alas-host setup` checks code-host sign-in; docs

**Files:**
- Modify: `Packages/AlasCore/Sources/alas-host/Setup.swift:9-19`
- Modify: `docs/headless-host.md:192-215, 242-244`

**Interfaces:**
- Consumes: `AlasCoreContext.prProviderSetupMessage(kind:isInstalled:)` (`AlasCoreContext+PRShepherd.swift:432`), `CodeHostRemoteDetector.detect(from:)`, `CodeHostProviderRegistry.live().provider(for:)`.
- Produces: `private static func codeHostSignInNotice(_ projects: [ProjectSnapshot]) async -> String?` in `HostSetup`.

- [ ] **Step 1: Implement.** For each local, non-folder project read `GitService().remotes(worktreePath:)`, detect its kind and remote; per kind once, `isAvailable(cwd:)` then `isAuthenticated(remote:cwd:)`; join the `prProviderSetupMessage` of each failing kind with `"\n"`. Only kinds some project uses are checked, so `glab` only with a GitLab project. Set it as the model's first `notice` before `Terminal.enter()`. No test: I/O over an already-pinned message.
- [ ] **Step 2: Docs.** In "The alas CLI and MCP tools": PRs are created and watched on the host (fix prompts, auto-merge, archive after merge per the project's shepherd rules), which needs `gh` (or `glab`) installed and signed in for the host's user, as `alas-host setup` reports. New "Shepherds and schedules" paragraph: schedules saved in the profile fire on the host; script runs get a run console; a schedule for a terminal agent, an SSH project, or one that leaves its prompt for review fails each time with the reason and runs only in the app; shepherd records of SSH-project worktrees are left for the app; settings are read at start (`alas-host restart` after changing them); alerts go to paired Macs as notifications. In "What it does not do yet": terminal-agent and SSH-project schedules; starting or stopping a shepherd from a paired Mac.
- [ ] **Step 3: Verify.** `swift build --package-path Packages/AlasCore --product alas-host` — Expected: builds.
- [ ] **Step 4: Commit.** `git commit -m "feat(alas-host): check code-host sign-in in setup and document shepherds and schedules"`

---

## PR B — `feat(remote): show a host session's shepherd and the host's worktree notices on the paired Mac`

### Task 8: Carry the shepherd pill on host session summaries

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/Shepherd/HostSessionShepherd.swift`
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/ShepherdPresentation.swift:8` (`ShepherdBadgeState: String`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift:426-474` (field + `summary(of:in:core:)`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Events.swift:453-468` (observe shepherd state)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ReviewShepherdTests.swift`, `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift`

**Interfaces:**
- Produces:
  - `public enum ShepherdBadgeState: String, Equatable, Sendable` (cases unchanged).
  - `public struct HostSessionShepherd: Codable, Equatable, Sendable { public var badge: String; public var number: String?; public var tooltip: String }`, `public init(_ presentation: ShepherdPresentation)` (`badge.rawValue`), and `@MainActor public static func make(sessionID: String, review: ReviewShepherd, stack: StackShepherd) -> HostSessionShepherd?`: the session's unfinished stack record → `ShepherdPresentation.make(stack:requests:gatePasses:)`; else its review record → `ShepherdPresentation.make(record:request:mergeGatePasses:)` with the record's snapshot only when it carries that record's request (as `ShepherdSessionContext.carries`) and `review.gatePasses[id] ?? false`; else its finished stack record; else nil (no Ship invitation on a read-only peer).
  - `HostSessionSummary.shepherd: HostSessionShepherd? = nil`, filled by `summary(of:in:core:)`. No capability: older decoders ignore the key; a missing key decodes as nil.
  - `HostEventSource.observeInMemoryState` also reads `core.reviewShepherd.records/.snapshots/.gatePasses` and `core.stackShepherd.records/.requests/.gatePasses`, so a shepherd change republishes `sessionChanged`.

- [ ] **Step 1: Write the failing tests.**

```swift
// ReviewShepherdTests
@Test func onlyTheBoundSessionCarriesAShepherdPill() async {
    let request = F.request(threads: [])
    let shepherd = makeShepherd(request: request, deliverPrompt: { _, _ in .delivered })
    let stack = StackShepherd(store: MemoryStore(), fileURL: URL(fileURLWithPath: "/memory/stack-shepherds.json"))
    let record = await shepherd.bind(sessionID: "session-1", worktreeID: "wt-1", request: request,
        baseBranch: "main", autoFix: true, autoMerge: false, contextRules: nil)

    let pill = HostSessionShepherd.make(sessionID: "session-1", review: shepherd, stack: stack)
    #expect(pill?.number == ShepherdPresentation.make(record: record, request: nil, mergeGatePasses: false).number)
    #expect(pill?.badge == ShepherdPresentation.make(record: record, request: nil, mergeGatePasses: false).badge.rawValue)
    #expect(HostSessionShepherd.make(sessionID: "session-2", review: shepherd, stack: stack) == nil)
}

// HostProtocolTests
@Test func aSummaryFromAHostWithoutShepherdsDecodesWithNone() throws {
    var summary = /* any HostSessionSummary this suite already builds */
    summary.shepherd = HostSessionShepherd(badge: "fixing", number: "#7", tooltip: "t")
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as! [String: Any]
    json["shepherd"] = nil
    let old = try JSONDecoder().decode(HostSessionSummary.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.shepherd == nil)
    #expect(ShepherdBadgeState(rawValue: "a-badge-from-a-newer-host") == nil)
}
```

- [ ] **Step 2: Run to verify they fail.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter "ReviewShepherdTests|HostProtocolTests"` — Expected: compile errors (`HostSessionShepherd`, `shepherd` missing).
- [ ] **Step 3: Implement** the interfaces.
- [ ] **Step 4: Run.** Same, plus `HostSessionsTests` — Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(alas-host): carry each session's shepherd pill in its summary"`

### Task 9: The peer channel keeps shepherds and hands on worktree notices

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerHostChannel.swift:15-58, 77-78, 109, 137`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/PeerHostChannelTests.swift:50-110` (extend the two existing tests)

**Interfaces:**
- Consumes: Task 6's `HostWorktreeNotice`, Task 8's `HostSessionSummary.shepherd`.
- Produces:
  - `PeerHostChannel.State.shepherds: [String: HostSessionShepherd]` by session id: seeded from `snapshot.sessions`, set or removed on `.sessionChanged`, removed on `.sessionRemoved`.
  - `public var onWorktreeNotice: (@MainActor (HostWorktreeNotice) -> Void)?`, called for each `.worktreeNotice` in a batch, like `onNotice`.
  - `connect()` subscribes with `events: ["notice", "worktreeNotice"]`.

- [ ] **Step 1: Extend the tests.** In `connectTakesASnapshotThenSubscribesAfterItsCursor` change the expected request to `.subscribeAccepting(after: cursor, events: ["notice", "worktreeNotice"])`. In `eventsApplyOnlyWhileSubscribedAndResyncTakesANewSnapshot`, after the notice block: a `.worktreeNotice` reaches `onWorktreeNotice` and leaves `state` unchanged; a `.sessionChanged` whose summary has `shepherd` sets `state?.shepherds["s"]`, and `.sessionRemoved(owner: .worktree("w"), id: "s")` clears it.
- [ ] **Step 2: Run to verify they fail.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter PeerHostChannelTests` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Same — Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(remote): follow host shepherds and worktree notices over the peer channel"`

### Task 10: Mac banners for worktree notices and the read-only pill (app, mechanical)

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/NotificationService.swift:215-231` (`notifyPeerNotice(…, peerWorktreeId: String? = nil)` → `userInfo["peerWorktreeId"]`)
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/NotificationDelegate.swift:55-66` (`NotificationClickContext.peerWorktreeId`)
- Modify (app): `Alas/Sources/Remote/Native/NativePeerHosts.swift:9-44, 156-170`; `Alas/Sources/App/AppState+PeerHosts.swift:6-22`; `Alas/Sources/App/AppState.swift:6917-6922`; `Alas/Sources/Remote/Native/NativePeerSessions.swift:254-266`; `Alas/Sources/Remote/Native/NativePeerSessionView.swift:735-772`

**Interfaces:**
- Consumes: Task 9's `onWorktreeNotice`, `State.shepherds`.
- Produces (app):
  - `NativePeerHosts`: init parameter `worktreeNotice: @escaping @MainActor (_ serverId: String, HostWorktreeNotice) -> Void = { _, _ in }`; `private(set) var shepherds: [String: [String: HostSessionShepherd]]` updated in the channel's `onChange` like `runs`.
  - `NativePeerSessions.selectHostWorktree(serverId: String, worktreeID: String)`: the group on `serverId` whose `host?.snapshot.worktree.id == worktreeID`, then `selectWorktree(NativePeerWorktreeSelection(serverId:, worktreeId: group.id))`.
  - `NativePeerSessions.selectedShepherd: HostSessionShepherd?` from `selectedSessionId` via `RemoteFederatedSessionID.parse(_:peers:)` and `hosts?.shepherds`.

- [ ] **Step 1: Core click plumbing** (NotificationService/Delegate). Run `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter PeerHostChannelTests` — Expected: PASS (compiles).
- [ ] **Step 2: App wiring.** `AppState+PeerHosts`: `worktreeNotice:` posts `notifyPeerNotice(body:title:agent: .codex, serverId:, sessionId: notice.worktreeID, peerWorktreeId: notice.worktreeID)`. `AppState.swift:6917`: when `context.peerWorktreeId` is set, `nativePeerSessions?.selectHostWorktree(serverId:worktreeID:)` and return, before the session branch.
- [ ] **Step 3: Pill.** In `NativePeerSessionView`, a private `NativePeerShepherdPill(shepherd:)` placed before `contextUsageButton` in both toolbars, shown only when `ShepherdBadgeState(rawValue: shepherd.badge)` decodes: the badge's `symbolName` and `color(theme:)` (the app extension in `ACPShepherdButton.swift:188-214`), the `number` in the same 11 pt monospaced style, `.help(tooltip)`, `.accessibilityLabel("Shepherd")`, no button action. No test: view composition; the decision is Task 8's.
- [ ] **Step 4: Verify.** Push and let CI build the app (`xcodebuild … -quiet build` cannot run locally). Expected: CI build green.
- [ ] **Step 5: Commit.** `git commit -m "feat(remote): show host worktree notices and a session's shepherd on the paired Mac"`

---

## Self-review notes

- **Spec contradictions and rulings.**
  - "The host already serves per-worktree review status to followers": `followReviewStatus` only refreshes `core.reviewLoops`; no event or response carries it, and the peer view shows none. Ruling: the pill rides an optional `HostSessionSummary.shepherd` (Task 8); no capability is needed, because older decoders ignore the key.
  - Worktree notice "carries worktree plus optional sessionID": a notification that names a loaded session already has `.notice`, which older Macs decode and which opens the session on click. Ruling: those stay `.notice`; `.worktreeNotice` carries only the worktree, which keeps the spec's click rule.
  - "Effects move into core as defaults; the app overrides": the app installs every effect itself and none of its pieces can be swapped one by one without behaviour risk. Ruling: the headless defaults are installed by `AlasHost.boot` only. The app shares the moved, UI-free code (Tasks 1-2) and keeps its own installs, so it doesn't change.
  - Setup "reports whether gh (and glab…)": Ruling: it checks only the CLIs of providers that local projects' remotes use.
- **Folded in (controller ruling).** The headless factory never fed `onTurnCompleted`, so `orchestration.childTurnCompleted` didn't run on the host, so delegated children's outcomes never reached their parent there. Task 4 now feeds it, matching the app.
- **Known ceilings (ponytail).** Records of local worktrees deleted while the host runs are kept (not served), so the app drops them later. Scheduled-turn waits on the host end only on a turn or the 4 h timeout, because there is no tab close.
