# Commit and Publish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a recoverable commit-and-publish action that pushes and creates or updates a review request for normal Git branches and runs `gg sync` for active GG stacks.

**Architecture:** Persist the user's preferred commit action and any post-commit recovery checkpoint in `DraftCommitTabState`. A testable `CommitPublishWorkflow` sequences injected commit, push, provider, and GG operations, while the existing views only select intent, render progress, and persist workflow transitions. Existing `ReviewLoopState` and `GGMutationCoordinator` remain the owners of provider and GG behavior.

**Tech Stack:** Swift 5.9, SwiftUI, Observation, Swift Testing, XcodeGen, existing `GitService`, code-host providers, and GG integration.

---

## File map

**Create:**

- `Alas/Sources/Center/Commit/CommitPublishModels.swift` owns Codable intent,
  target, checkpoint, phase, availability, and presentation values.
- `Alas/Sources/Center/Commit/CommitPublishWorkflow.swift` owns the injected
  operations and resumable phase sequence.
- `AlasTests/Center/CommitPublishModelsTests.swift` covers model compatibility,
  labels, enablement, and shortcut-independent presentation rules.
- `AlasTests/Center/CommitPublishWorkflowTests.swift` covers operation order,
  checkpoints, deduplication, and retry safety.

**Modify:**

- `Alas/Sources/Center/Tab.swift` persists the new draft fields with tolerant
  decoding.
- `Alas/Sources/Center/TabsManager.swift` accepts and updates the preferred
  action for live and stashed drafts.
- `Alas/Sources/Shortcuts/ShortcutBinding.swift` adds the pure Shift-variant
  helper.
- `Alas/Sources/Center/Commit/CommitPrimaryAction.swift` defines stable
  leading/trailing composer action placement.
- `Alas/Sources/Center/Commit/CommitMessageEditorView.swift` renders an optional
  alternate action and assigns emphasis and shortcuts.
- `Alas/Sources/Right/ChangesPreparationModel.swift` models normal publish and
  GG commit-and-sync destinations.
- `Alas/Sources/Right/ChangesPreparationCard.swift` renders the normal action
  pair and the GG two-column grid.
- `Alas/Sources/Right/ChangesTabView.swift` derives publish availability and
  routes the selected intent into `TabsManager`.
- `Alas/Sources/Integrations/CodeHost/ReviewLoopState.swift` exposes a fresh,
  targeted review-request lookup for duplicate prevention.
- `Alas/Sources/Git/GitService+ReviewLoop.swift` probes the checkpointed remote
  branch for the exact commit before push and provides a strict HEAD
  publication probe for Amend safety.
- `Alas/Sources/Right/RightPaneState.swift` exposes an awaitable GG sync method
  that preserves existing action state and error reporting.
- `Alas/Sources/Center/Commit/DraftCommitTabView.swift` wires live operations,
  progress, persistence, retry, and completion into the composer.
- `AlasTests/DraftCommitTabStateTests.swift` and
  `AlasTests/DraftCommitTabsManagerTests.swift` cover persisted compatibility
  and intent routing.
- `AlasTests/ShortcutBindingTests.swift` covers Shift toggling.
- `AlasTests/Right/ChangesPreparationModelTests.swift` and
  `AlasTests/ChangesTabViewTests.swift` cover action construction and preflight
  presentation.
- `AlasTests/Integrations/ReviewLoopStateTests.swift` covers targeted fresh
  lookup.
- `AlasTests/GitServiceUpstreamTests.swift` covers strict publication state and
  exact remote-branch containment.
- `AlasTests/RightPaneGGStackTests.swift` covers awaited sync success and
  failure.
- `Alas.xcodeproj/project.pbxproj` is regenerated after adding source and test
  files.

## Task 1: Persist intent and recovery models

**Files:**

- Create: `Alas/Sources/Center/Commit/CommitPublishModels.swift`
- Create: `AlasTests/Center/CommitPublishModelsTests.swift`
- Modify: `Alas/Sources/Center/Tab.swift:490-530`
- Modify: `AlasTests/DraftCommitTabStateTests.swift:1-35`
- Modify: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing model and compatibility tests**

Add tests that define the required model behavior before the types exist:

```swift
@Test func draftDefaultsToLocalCommitAndRegularReviewRequest() {
    let state = DraftCommitTabState(worktreeId: "wt-1")
    #expect(state.preferredAction == .commit)
    #expect(state.createReviewRequestAsDraft == false)
    #expect(state.publishCheckpoint == nil)
}

@Test func legacyDraftJSONDecodesNewFieldsWithDefaults() throws {
    let data = Data(#"{"id":"draft-commit:wt-1","worktreeId":"wt-1","subject":"Subject","bodyText":"Body","amend":false}"#.utf8)
    let state = try JSONDecoder().decode(DraftCommitTabState.self, from: data)
    #expect(state.preferredAction == .commit)
    #expect(state.createReviewRequestAsDraft == false)
    #expect(state.publishCheckpoint == nil)
}

@Test func reviewCheckpointRoundTripsEveryCapturedField() throws {
    let checkpoint = CommitPublishCheckpoint(
        commitSHA: "abc123",
        baseRef: "main",
        commitTitle: "abc123 Subject",
        subject: "Subject",
        body: "Body",
        destination: .review(.init(
            provider: .github,
            host: "github.com",
            owner: "owner",
            repository: "repo",
            repositorySlug: "owner/repo",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/owner/repo")!,
            branch: "feature",
            upstreamBranch: nil,
            headOwner: nil,
            baseBranch: "main",
            reviewRequestExisted: false,
            createAsDraft: true
        )),
        nextPhase: .push
    )
    let data = try JSONEncoder().encode(checkpoint)
    #expect(try JSONDecoder().decode(CommitPublishCheckpoint.self, from: data) == checkpoint)
}
```

Also cover the GG destination and every `CommitPublishPhase` value.

- [ ] **Step 2: Regenerate the project and verify the tests fail**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DraftCommitTabStateTests -only-testing:AlasTests/CommitPublishModelsTests test
```

Expected: compilation fails because the new model types and draft properties do
not exist.

- [ ] **Step 3: Add the minimal Codable models**

Define the persisted values in `CommitPublishModels.swift`:

```swift
enum DraftCommitPreferredAction: String, Codable, Equatable, Sendable {
    case commit
    case publish
}

enum CommitPublishPhase: String, Codable, Equatable, Sendable {
    case push
    case createReviewRequest
    case sync
}

struct CommitPublishReviewTarget: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let owner: String
    let repository: String
    let repositorySlug: String
    let remoteName: String
    let webURL: URL
    let branch: String
    let upstreamBranch: String?
    let headOwner: String?
    let baseBranch: String
    let reviewRequestExisted: Bool
    let createAsDraft: Bool
}

enum CommitPublishDestination: Codable, Equatable, Sendable {
    case review(CommitPublishReviewTarget)
    case gg
}

struct CommitPublishCheckpoint: Codable, Equatable, Sendable {
    let commitSHA: String
    let baseRef: String
    let commitTitle: String
    let subject: String
    let body: String
    let destination: CommitPublishDestination
    var nextPhase: CommitPublishPhase
}
```

Give `CommitPublishReviewTarget` a computed `remote` that reconstructs the exact
captured `CodeHostRemote`. This makes retry independent of the current review
snapshot and preserves self-hosted host and web URL identity across relaunch.

Add non-optional `preferredAction`, `createReviewRequestAsDraft`, and optional
`publishCheckpoint` fields to `DraftCommitTabState`. Implement explicit
`CodingKeys` and `init(from:)` so missing keys decode to `.commit`, `false`, and
`nil`. Keep encoded field names stable and keep `presentationRevision`
backward-compatible.

- [ ] **Step 4: Run the focused tests and confirm they pass**

Run the focused `xcodebuild` command from Step 2.

Expected: both suites pass.

- [ ] **Step 5: Commit the persisted model**

```bash
rtk git add Alas/Sources/Center/Commit/CommitPublishModels.swift Alas/Sources/Center/Tab.swift AlasTests/Center/CommitPublishModelsTests.swift AlasTests/DraftCommitTabStateTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(commit): persist publish workflow state"
```

## Task 2: Route Prepare intent through TabsManager

**Files:**

- Modify: `Alas/Sources/Center/TabsManager.swift:970-1015`
- Modify: `AlasTests/DraftCommitTabsManagerTests.swift:1-205`

- [ ] **Step 1: Write failing live, new, and stashed intent tests**

Add tests for these cases:

```swift
@Test func openDraftWithPublishIntentCreatesPublishFirstDraft() {
    let worktreeID = "publish-intent-new"
    defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeID)) }
    let manager = TabsManager()
    let tab = manager.openOrFocusDraftCommit(
        worktreeId: worktreeID,
        preferredAction: .publish
    )
    guard case .draftCommit(let state) = tab else {
        Issue.record("Expected draft commit")
        return
    }
    #expect(state.preferredAction == .publish)
}
```

Add `changingIntentPreservesLiveDraftContents` by creating a draft, populating
subject, body, Draft PR, Amend, selection, and checkpoint through
`updateDraftCommit`, then reopening with `.publish`. Assert that only
`preferredAction` changes when `resetAmend` is false. Keep the draft selected
throughout this case and assert the manager's live tab state changes in place;
this covers switching intent from Prepare while the composer is already
visible. Add the same test after closing the populated draft to exercise
stashed state, then assert the stored stash also contains `.publish`.

Add a checkpoint-only close test by clearing subject and body after installing
a checkpoint, closing the tab, and asserting `stashedDraft` retains that
checkpoint. This protects recovery against future model changes.

- [ ] **Step 2: Run the manager suite and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DraftCommitTabsManagerTests test
```

Expected: compilation fails because `preferredAction` is not accepted by
`openOrFocusDraftCommit`, then the checkpoint-only stash assertion fails.

- [ ] **Step 3: Implement intent updates without clearing draft data**

Change the API to:

```swift
func openOrFocusDraftCommit(
    worktreeId: String,
    resetAmend: Bool = false,
    preferredAction: DraftCommitPreferredAction? = nil
) -> Tab
```

Apply a non-nil preference to new, live, and stashed state before focusing or
appending the tab. Preserve all other fields. Update `captureDraftIfNeeded` so
`publishCheckpoint != nil` also qualifies the draft for stashing.

- [ ] **Step 4: Run the manager suite and confirm it passes**

Run the command from Step 2.

Expected: all `DraftCommitTabsManagerTests` pass.

- [ ] **Step 5: Commit intent routing**

```bash
rtk git add Alas/Sources/Center/TabsManager.swift AlasTests/DraftCommitTabsManagerTests.swift
rtk git commit -m "feat(commit): route draft publish intent"
```

## Task 3: Add paired composer actions and Shift shortcuts

**Files:**

- Modify: `Alas/Sources/Shortcuts/ShortcutBinding.swift:1-85`
- Modify: `Alas/Sources/Center/Commit/CommitPrimaryAction.swift:1-40`
- Modify: `Alas/Sources/Center/Commit/CommitMessageEditorView.swift:1-125`
- Modify: `AlasTests/ShortcutBindingTests.swift:1-70`
- Modify: `AlasTests/Center/CommitPublishModelsTests.swift`

- [ ] **Step 1: Write failing Shift-variant and action-assignment tests**

```swift
@Test func shiftVariantAddsShift() {
    let base = ShortcutBinding(key: "return", modifiers: [.command])
    #expect(base.togglingShift() == .init(key: "return", modifiers: [.command, .shift]))
}

@Test func shiftVariantRemovesExistingShift() {
    let base = ShortcutBinding(key: "j", modifiers: [.command, .shift])
    #expect(base.togglingShift() == .init(key: "j", modifiers: [.command]))
}

@Test func preferredTrailingActionReceivesBaseShortcut() {
    let pair = CommitComposerActionPair.shortcuts(
        preferred: .trailing,
        base: .init(key: "return", modifiers: [.command])
    )
    #expect(pair.leading == .init(key: "return", modifiers: [.command, .shift]))
    #expect(pair.trailing == .init(key: "return", modifiers: [.command]))
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ShortcutBindingTests -only-testing:AlasTests/CommitPublishModelsTests test
```

Expected: compilation fails on `togglingShift` and the paired-action helper.

- [ ] **Step 3: Implement pure shortcut assignment**

Add `ShortcutBinding.togglingShift()`, preserving modifier order after toggling.
Add a small `CommitComposerActionPosition` and pure shortcut-assignment helper
beside `CommitPrimaryAction`. Do not add a new `ShortcutAction` setting.

- [ ] **Step 4: Render the optional alternate action**

Extend `CommitMessageEditorView` with optional `alternateAction` and
`preferredActionPosition`, defaulting to the current single leading action.
Render buttons in stable leading/trailing order. The preferred button uses the
accent fill and base shortcut; the other button uses the Shift variant and a
subtle fill. Both display their actual shortcut badges. Keep the existing
saved-state behavior for single-action callers.

Extract one `actionButton` builder so enabled, busy, accessibility, and badge
behavior cannot drift between the two buttons.

- [ ] **Step 5: Run focused tests and a compile check**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ShortcutBindingTests -only-testing:AlasTests/CommitPublishModelsTests test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: tests and build pass; existing call sites compile unchanged.

- [ ] **Step 6: Commit paired composer actions**

```bash
rtk git add Alas/Sources/Shortcuts/ShortcutBinding.swift Alas/Sources/Center/Commit/CommitPrimaryAction.swift Alas/Sources/Center/Commit/CommitMessageEditorView.swift AlasTests/ShortcutBindingTests.swift AlasTests/Center/CommitPublishModelsTests.swift
rtk git commit -m "feat(commit): add paired composer actions"
```

## Task 4: Add Prepare publish destinations

**Files:**

- Modify: `Alas/Sources/Center/Commit/CommitPublishModels.swift`
- Modify: `Alas/Sources/Right/ChangesPreparationModel.swift:1-390`
- Modify: `Alas/Sources/Right/ChangesPreparationCard.swift:35-430`
- Modify: `Alas/Sources/Right/ChangesTabView.swift:10-210,260-290,660-715`
- Modify: `AlasTests/Center/CommitPublishModelsTests.swift`
- Modify: `AlasTests/Right/ChangesPreparationModelTests.swift`
- Modify: `AlasTests/ChangesTabViewTests.swift`

- [ ] **Step 1: Write failing publish-availability tests**

Define a pure availability resolver and test supported-host states:

```swift
@Test func noRequestOffersCommitAndPR() {
    let availability = CommitPublishAvailability.review(snapshot: snapshot(reviewRequest: nil))
    #expect(availability?.label == "Commit & PR")
    #expect(availability?.disabledReason == nil)
    #expect(availability?.showsDraftToggle == true)
}

@Test func existingRequestOffersCommitAndPush() {
    let availability = CommitPublishAvailability.review(snapshot: snapshot(reviewRequest: request))
    #expect(availability?.label == "Commit & push")
    #expect(availability?.showsDraftToggle == false)
}

@Test func unsupportedHostHidesPublishDestination() {
    #expect(CommitPublishAvailability.review(snapshot: unsupportedSnapshot) == nil)
}
```

Cover loading, unavailable CLI, authentication, create capability, base branch,
stale/diverged upstream, and published Amend. Model Amend publication as an
explicit probe state: loading, not published (including no upstream), published,
or failed. Publish stays disabled unless the probe resolved to not published.
The existing warning can render from the same state.

- [ ] **Step 2: Write failing preparation-model tests**

Update the normal model expectation to contain Draft commit plus the supplied
publish destination. Update GG expectations to:

```swift
#expect(model.ggActions.map(\.kind) == [
    .newStackCommit, .commitAndSync, .amendCurrent, .absorbIntoStack,
])
```

Test that Commit & sync shares New stack commit's staged/draft and stack-head
requirements, plus the common GG mutation blocker. Test that a combined
destination suppresses a redundant compact Push or Create PR action while
leaving unrelated review actions intact.

- [ ] **Step 3: Run model tests and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitPublishModelsTests -only-testing:AlasTests/ChangesPreparationModelTests -only-testing:AlasTests/ChangesTabViewTests test
```

Expected: compilation or assertions fail because publish availability and the
fourth GG action are missing.

- [ ] **Step 4: Implement availability and model construction**

Add `CommitPublishAvailability` with `label`, `detail`, `disabledReason`, and
`showsDraftToggle`. Build normal availability from `ReviewLoopSnapshot?`,
refresh state, current branch/base, conflicting action, Amend, and the supported
remote. Build GG availability from the existing GG context, stack-head, paused,
in-flight, and merge-operation values.

When Amend is selected, start a strict asynchronous HEAD publication probe.
Keep publish disabled while it is loading or failed, and report the failure in
help text. A published result disables publish but leaves local Commit enabled.
The eventual workflow preflight repeats the strict probe to close the race
between rendering and invocation.

Extend `ChangesPreparationModel` with an optional publish draft action and add
`.commitAndSync` to `GGChangesPreparationAction`. Keep current Draft, Amend, and
Absorb behavior unchanged.

- [ ] **Step 5: Render the normal pair and GG grid**

Render Draft commit and the normal publish action in the existing
`ViewThatFits` path. For GG, replace the one-row `HStack` with a two-column
`LazyVGrid` or `Grid` using stable equal-width tracks and the approved order.
Use existing `secondaryButton` and `ggDestinationButton` styles. Add distinct
accessibility identifiers:

```text
changes-preparation-draft
changes-preparation-publish
changes-preparation-gg-new
changes-preparation-gg-sync
changes-preparation-gg-amend
changes-preparation-gg-absorb
```

- [ ] **Step 6: Route both entry intents**

Change `openDraftTab` and `handleGGPreparationAction` so Draft/New stack commit
passes `.commit`, while Commit & PR/Push/Sync passes `.publish`. Keep
`resetAmend: true` for both GG first-row actions.

- [ ] **Step 7: Run focused tests and build**

Run the command from Step 3, then:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: focused tests and build pass.

- [ ] **Step 8: Commit Prepare destinations**

```bash
rtk git add Alas/Sources/Center/Commit/CommitPublishModels.swift Alas/Sources/Right/ChangesPreparationModel.swift Alas/Sources/Right/ChangesPreparationCard.swift Alas/Sources/Right/ChangesTabView.swift AlasTests/Center/CommitPublishModelsTests.swift AlasTests/Right/ChangesPreparationModelTests.swift AlasTests/ChangesTabViewTests.swift
rtk git commit -m "feat(changes): add commit publish destinations"
```

## Task 5: Build the resumable workflow engine

**Files:**

- Create: `Alas/Sources/Center/Commit/CommitPublishWorkflow.swift`
- Create: `AlasTests/Center/CommitPublishWorkflowTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing happy-path sequence tests**

Use a closure-backed spy that records calls. Cover these exact sequences:

```swift
#expect(spy.calls == ["commit", "head", "remoteContainsCommit", "push", "lookupPR", "createPR"])
#expect(checkpoints.map(\.nextPhase) == [.push, .createReviewRequest])
```

For an existing review request, expect commit, HEAD verification, push probe,
push, and completion with no create call. For GG, expect commit, HEAD
verification, sync, and completion.

- [ ] **Step 2: Write failing recovery tests**

Cover each boundary:

- commit failure emits no checkpoint;
- push failure leaves `.push`;
- successful push followed by lookup failure leaves `.createReviewRequest`;
- create failure leaves `.createReviewRequest`;
- sync failure leaves `.sync`;
- resume never invokes commit;
- HEAD mismatch invokes no network or GG operation;
- remote branch containment of the checkpointed SHA skips push, including when
  the original branch had no upstream;
- an existing request from fresh lookup skips create;
- checkpoint completion is cleared before a best-effort refresh callback.

- [ ] **Step 3: Regenerate and run the tests to verify failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitPublishWorkflowTests test
```

Expected: compilation fails because `CommitPublishWorkflow` and its operations
do not exist.

- [ ] **Step 4: Implement injected operations and activity state**

Use a main-actor closure bundle so tests do not require real repositories or
providers:

```swift
@MainActor
struct CommitPublishOperations {
    var createCommit: (_ subject: String, _ body: String, _ amend: Bool) async throws -> CommitPublishCreatedCommit
    var currentHeadSHA: () async throws -> String
    var remoteBranchContainsCommit: (_ target: CommitPublishReviewTarget, _ commitSHA: String) async throws -> Bool
    var push: (_ target: CommitPublishReviewTarget, _ commitSHA: String) async throws -> Void
    var currentReviewRequestExists: (_ target: CommitPublishReviewTarget) async throws -> Bool
    var createReviewRequest: (_ target: CommitPublishReviewTarget, _ subject: String, _ body: String) async throws -> URL
    var syncGG: () async throws -> Void
    var refreshAfterCompletion: () async -> Void
}

enum CommitPublishActivity: Equatable {
    case idle, committing, pushing, creatingReviewRequest, syncing
}
```

`CommitPublishCreatedCommit` contains SHA, comparison base, and commit-editor
title. `CommitPublishWorkflow.start` creates and checkpoints the commit, then
calls `resume`. `resume` validates HEAD and advances one persisted phase at a
time through a checkpoint callback. Clear the checkpoint before the final
best-effort refresh callback.

- [ ] **Step 5: Run workflow tests and confirm they pass**

Run the command from Step 3.

Expected: all workflow sequence and recovery tests pass.

- [ ] **Step 6: Commit the workflow engine**

```bash
rtk git add Alas/Sources/Center/Commit/CommitPublishWorkflow.swift AlasTests/Center/CommitPublishWorkflowTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(commit): add resumable publish workflow"
```

## Task 6: Add strict Git, provider, and GG operations

**Files:**

- Modify: `Alas/Sources/Integrations/CodeHost/ReviewLoopState.swift:320-365`
- Modify: `Alas/Sources/Git/GitService+ReviewLoop.swift:1-80`
- Modify: `Alas/Sources/Right/RightPaneState.swift:1360-1415,1840-1910`
- Modify: `AlasTests/Integrations/ReviewLoopStateTests.swift:340-560,1208-1335`
- Modify: `AlasTests/GitServiceUpstreamTests.swift:1-70`
- Modify: `AlasTests/RightPaneGGStackTests.swift`

- [ ] **Step 1: Write a failing fresh review-request lookup test**

Add a test where the captured snapshot has no request, the fake provider now
has one, and the new lookup returns it using the captured branch, head owner,
base, and remote. Add provider-error propagation coverage.

The intended API is:

```swift
func currentReviewRequest(
    remote: CodeHostRemote,
    branch: String,
    headOwner: String?,
    baseBranch: String
) async throws -> ReviewRequest?

func createReviewRequest(
    remote: CodeHostRemote,
    branch: String,
    headOwner: String?,
    baseBranch: String,
    title: String,
    body: String,
    draft: Bool
) async throws -> URL
```

- [ ] **Step 2: Run the review-loop tests and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewLoopStateTests test
```

Expected: compilation fails because the targeted lookup is missing.

- [ ] **Step 3: Implement provider lookup through the existing registry**

Resolve the provider from the explicit remote, call its existing
`currentReviewRequest` API with the explicit branch, head owner, and base, and
return the result. Do not fetch checks; the workflow only needs existence for
deduplication. Refactor `createReviewRequest` through the same explicit-remote
path, pass the explicit head owner to the provider, and preserve a
snapshot-taking overload for existing callers. Reuse the current
unsupported-provider error behavior and return the created request URL.
Workflow lookup and creation must reconstruct the remote from
`CommitPublishReviewTarget`; neither may substitute the current review
snapshot's remote identity.

- [ ] **Step 4: Write failing exact-remote and strict-Amend Git tests**

Extend `GitServiceUpstreamTests` with local and bare repositories. Cover:

- a missing remote branch does not contain the checkpointed SHA;
- a newly pushed branch contains it even when no upstream existed before push;
- a remote branch advanced beyond the SHA still contains its ancestor;
- an unrelated remote tip does not contain it;
- transport or fetch failure throws instead of being treated as absent;
- strict HEAD publication returns no-upstream, unpublished, and published
  states, and throws on an actual ancestry-probe failure.

Implement `remoteBranchContainsCommit` by first running `ls-remote --exit-code
--heads <remote> refs/heads/<branch>`. Treat its documented no-match status as
`false` and propagate every other nonzero result. Fetch the exact advertised
branch into a UUID-scoped temporary ref under `refs/alas/publish-check/`, check
`merge-base --is-ancestor <checkpoint-sha> <temporary-ref>`, and delete only
that temporary ref in `defer`. Propagate transport, fetch, and ancestry-probe
errors. Never rely only on `@{u}` or `ls-remote` tip equality.

Add a strict `headPublicationState` helper and let the existing
`isHeadAtOrBehindUpstream` warning helper adapt it to Bool for current callers.
The strict API must distinguish no upstream from command failure.

- [ ] **Step 5: Run Git and review-loop tests**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceUpstreamTests -only-testing:AlasTests/ReviewLoopStateTests test
```

Expected: exact remote containment, strict publication state, and provider
lookup tests pass.

- [ ] **Step 6: Write failing awaited GG sync tests**

Using `RightPaneState.ggService` with existing fake runners, assert that:

- the new async method does not return before sync finishes;
- success preserves normal progress/summary and refresh behavior;
- failure throws to the caller and also updates `ggActionState` once;
- concurrent mutation refusal throws `GGMutationError.operationInFlight`.

- [ ] **Step 7: Implement one shared awaited GG mutation path**

Extract the body currently duplicated by the two `runGGMutation` overloads into
an async throwing helper that starts the coordinator operation, applies sync
refresh deferral, awaits `operation.value`, publishes existing presentation
errors, and schedules deferred refresh in `defer`.

Keep existing fire-and-forget callers by wrapping the helper in `Task`. Add:

```swift
@MainActor
func syncGGForCommitPublish() async throws {
    try await performGGMutation(.sync)
}
```

Do not create a second `GGService.sync` call path.

- [ ] **Step 8: Run provider and GG tests**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceUpstreamTests -only-testing:AlasTests/ReviewLoopStateTests -only-testing:AlasTests/RightPaneGGStackTests test
```

Expected: both suites pass.

- [ ] **Step 9: Commit live operation support**

```bash
rtk git add Alas/Sources/Git/GitService+ReviewLoop.swift Alas/Sources/Integrations/CodeHost/ReviewLoopState.swift Alas/Sources/Right/RightPaneState.swift AlasTests/GitServiceUpstreamTests.swift AlasTests/Integrations/ReviewLoopStateTests.swift AlasTests/RightPaneGGStackTests.swift
rtk git commit -m "feat(commit): expose publish operation adapters"
```

## Task 7: Wire publishing into DraftCommitTabView

**Files:**

- Modify: `Alas/Sources/Center/Commit/DraftCommitTabView.swift:1-465`
- Modify: `Alas/Sources/Center/Commit/CommitPublishWorkflow.swift`
- Modify: `AlasTests/Center/CommitPublishWorkflowTests.swift`

- [ ] **Step 1: Add failing live-operation adapter tests**

Extend the workflow tests with a small adapter harness and verify:

- push arguments match `RightPaneState.reviewLoopPushArguments`, including
  upstream branch and `-u` fallback behavior;
- the exact-remote containment probe uses the checkpointed remote and branch,
  including a branch that had no upstream at preflight;
- push errors use `RightPaneState.reviewLoopPushFailureMessage`;
- provider lookup and creation use the checkpointed remote, host,
  branch/base/head-owner values even if the live snapshot changes;
- commit creation computes the same parent or empty-tree comparison base as the
  current `runCommit` implementation;
- completion refresh is best-effort and happens after checkpoint clear.

Keep shell processes behind injected closures in these tests.

- [ ] **Step 2: Run workflow tests and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitPublishWorkflowTests test
```

Expected: the new adapter assertions fail until the live closure construction
is extracted from the view.

- [ ] **Step 3: Hydrate and persist the new draft fields**

Add view state for Draft PR, checkpoint, and current activity, and hydrate those
values from `tabState`. Do not copy `preferredAction` into one-time view state.
Derive action emphasis directly from the current `tabState.preferredAction` so
reopening an already-visible draft from Prepare updates the default action
immediately. Extend the existing `persist` helper so mutable draft changes write
through `TabsManager.updateDraftCommit`. When a checkpoint exists, disable
subject, body, Amend, Draft PR, AI generation, staging mutations, and the
alternate local-commit action.

- [ ] **Step 4: Build the contextual action pair**

Read normal review state and GG context from the active `RightPaneState`, using
the same pure availability resolver as Prepare. Build:

- Commit as the stable leading action;
- Commit & PR, Commit & push, or Commit & sync as the trailing action;
- Retry push, Retry create PR, or Retry sync when a checkpoint exists;
- the preferred position directly from the current persisted tab intent, except
  recovery always makes the retry action preferred;
- an accessory `HStack` containing Draft PR when applicable and the existing
  Amend checkbox.

Pass the configured `commitInComposer` shortcut as the base. The shared editor
assigns its Shift variant.

- [ ] **Step 5: Replace direct publish sequencing with the workflow**

Keep commit-only behavior and its immediate draft-to-editor replacement intact.
For publish:

1. Build and validate an immutable review or GG destination before commit.
2. Build `CommitPublishOperations` from the existing `GitService`, active
   `ReviewLoopState`, and `RightPaneState.syncGGForCommitPublish`.
3. Call `CommitPublishWorkflow.start` when there is no checkpoint or `resume`
   when one exists.
4. Persist every checkpoint callback immediately.
5. Update the button label from activity and publish inline errors on failure.
6. On success, replace the draft with the commit editor and refresh Amend state.

The push phase first calls `git.remoteBranchContainsCommit` with the
checkpointed remote, branch, and SHA. A true result advances without pushing.
Otherwise run the existing push arguments. The PR phase always calls the new
fresh lookup against the checkpoint's reconstructed remote before create. Use
the exact trimmed commit subject and body and the checkpointed Draft PR value.

Before creating or amending the commit for a publish action, repeat the strict
`headPublicationState` check when Amend is selected. Abort before commit unless
it resolves to not published (which includes no upstream). Do not trust the
earlier UI probe.

- [ ] **Step 6: Guard recovery against branch movement**

On resume, let the workflow compare `git rev-parse HEAD` with checkpoint SHA.
Render a specific inline error when they differ and leave the checkpoint intact.
Do not move HEAD, recommit, or start a remote operation.

- [ ] **Step 7: Run focused tests and build**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitPublishWorkflowTests -only-testing:AlasTests/DraftCommitTabStateTests -only-testing:AlasTests/DraftCommitTabsManagerTests test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: focused tests and the app build pass.

- [ ] **Step 8: Commit composer integration**

```bash
rtk git add Alas/Sources/Center/Commit/DraftCommitTabView.swift Alas/Sources/Center/Commit/CommitPublishWorkflow.swift AlasTests/Center/CommitPublishWorkflowTests.swift
rtk git commit -m "feat(commit): wire commit and publish workflow"
```

## Task 8: Close presentation and recovery gaps

**Files:**

- Modify: `Alas/Sources/Center/Commit/CommitPublishModels.swift`
- Modify: `Alas/Sources/Center/Commit/DraftCommitTabView.swift`
- Modify: `Alas/Sources/Right/ChangesPreparationCard.swift`
- Modify: `AlasTests/Center/CommitPublishModelsTests.swift`
- Modify: `AlasTests/Center/CommitPublishWorkflowTests.swift`
- Modify: `AlasTests/Right/ChangesPreparationModelTests.swift`

- [ ] **Step 1: Add failing edge-case presentation tests**

Cover exact labels and control rules for:

- Commit selected versus publish selected;
- normal PR, existing PR, GG, and all retry phases;
- empty body still allowing publication;
- empty subject and no staged changes disabling initial actions;
- checkpoint recovery remaining enabled without staged changes;
- Draft PR persisting when Commit is preferred;
- published Amend disabling publish but not Commit;
- busy state disabling both actions;
- unsupported host hiding publish while a supported blocked host shows it
  disabled with a reason.

- [ ] **Step 2: Run focused tests and verify failures**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitPublishModelsTests -only-testing:AlasTests/CommitPublishWorkflowTests -only-testing:AlasTests/ChangesPreparationModelTests test
```

Expected: any missing labels or enablement rules fail explicitly.

- [ ] **Step 3: Centralize labels and enablement in pure presentation values**

Move remaining conditional strings and button-enable decisions out of the
SwiftUI body into `CommitPublishModels.swift`. Views should render the returned
values rather than independently infer recovery or availability.

Add help text and stable accessibility identifiers to the composer buttons and
Draft PR toggle. Use provider terminology already exposed by
`CodeHostKind.reviewRequestLabel` where the existing UI requires PR versus MR
wording; keep the approved GitHub labels unchanged.

- [ ] **Step 4: Run focused tests and build**

Run the command from Step 2, then:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: focused tests and build pass.

- [ ] **Step 5: Commit presentation hardening**

```bash
rtk git add Alas/Sources/Center/Commit/CommitPublishModels.swift Alas/Sources/Center/Commit/DraftCommitTabView.swift Alas/Sources/Right/ChangesPreparationCard.swift AlasTests/Center/CommitPublishModelsTests.swift AlasTests/Center/CommitPublishWorkflowTests.swift AlasTests/Right/ChangesPreparationModelTests.swift
rtk git commit -m "test(commit): cover publish recovery states"
```

## Task 9: Regenerate and verify the complete change

**Files:**

- Modify: `Alas.xcodeproj/project.pbxproj` if XcodeGen output changed

- [ ] **Step 1: Regenerate the Xcode project**

```bash
rtk xcodegen
rtk git diff --exit-code project.yml
```

Expected: `project.yml` is unchanged; `Alas.xcodeproj/project.pbxproj` contains
all new source and test files.

- [ ] **Step 2: Run all focused suites together**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/CommitPublishModelsTests \
  -only-testing:AlasTests/CommitPublishWorkflowTests \
  -only-testing:AlasTests/DraftCommitTabStateTests \
  -only-testing:AlasTests/DraftCommitTabsManagerTests \
  -only-testing:AlasTests/ShortcutBindingTests \
  -only-testing:AlasTests/ChangesPreparationModelTests \
  -only-testing:AlasTests/ChangesTabViewTests \
  -only-testing:AlasTests/ReviewLoopStateTests \
  -only-testing:AlasTests/GitServiceUpstreamTests \
  -only-testing:AlasTests/RightPaneGGStackTests test
```

Expected: all focused suites pass with zero failures.

- [ ] **Step 3: Run the required clean build**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit code 0.

- [ ] **Step 4: Run the full test suite**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: all tests pass with zero failures.

- [ ] **Step 5: Inspect final scope and formatting**

```bash
rtk git diff --check
rtk git status --short
rtk git diff --stat e92aafb3..HEAD
```

Expected: no whitespace errors, no unrelated files, and only the planned source,
test, generated project, spec, and plan changes.

- [ ] **Step 6: Commit final generated-project changes if needed**

If Step 1 changed the generated project after the last feature commit:

```bash
rtk git add Alas.xcodeproj/project.pbxproj
rtk git commit -m "chore: regenerate Xcode project"
```
