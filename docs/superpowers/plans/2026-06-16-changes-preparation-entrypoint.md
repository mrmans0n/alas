# Changes Preparation Entry Point Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace separate Changes-tab draft/review trigger rows with one coherent preparation card that opens the existing review, draft commit, and PR/MR workflows.

**Architecture:** Add a pure `ChangesPreparationModel` that converts existing Changes tab state into a small set of presentation actions. Add a SwiftUI `ChangesPreparationCard` that renders those actions and calls existing handlers. Wire `ChangesTabView` to render the new card above the working tree while keeping the review-loop drawer as the detailed status surface.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, existing Alas theme/icons, existing `ReviewReadinessModel` and tab-opening APIs.

---

## File Structure

- Create `Alas/Sources/Right/ChangesPreparationModel.swift`
  - Owns the pure model for the card: primary review action, draft action, review-request action, stats, labels, and action-priority selection.
- Create `Alas/Sources/Right/ChangesPreparationCard.swift`
  - Owns SwiftUI rendering for the preparation card only.
- Modify `Alas/Sources/Right/ChangesTabView.swift`
  - Computes `ChangesPreparationModel`.
  - Replaces `DraftCommitTriggerRow` and `ReviewChangesTriggerRow` with `ChangesPreparationCard`.
  - Removes obsolete private trigger row views after integration.
- Modify `AlasTests/ReviewChangesModelsTests.swift`
  - Adds model tests for card visibility, review/draft action rules, conflicts, and readiness action priority.

The Xcode project is generated. If new source files are not picked up by a build, run `xcodegen` and commit resulting project changes only if `xcodegen` actually changes `Alas.xcodeproj`.

---

### Task 1: Pure Preparation Model

**Files:**
- Create: `Alas/Sources/Right/ChangesPreparationModel.swift`
- Modify: `AlasTests/ReviewChangesModelsTests.swift`

- [ ] **Step 1: Add failing model tests**

Append these tests inside `struct ReviewChangesModelsTests` in `AlasTests/ReviewChangesModelsTests.swift`, before the closing `}`:

```swift
    @Test func preparationModelShowsReviewActionForNonConflictChangesOnly() throws {
        let changes = [
            changedFile("conflicted.swift", stage: .unstaged, add: 40, del: 5, conflict: .bothModified),
            changedFile("Sources/App.swift", stage: .unstaged, add: 8, del: 2),
        ]

        let model = ChangesPreparationModel(
            changes: changes,
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: []
        )

        #expect(model.isVisible)
        let review = try #require(model.reviewAction)
        #expect(review.fileCount == 1)
        #expect(review.additions == 8)
        #expect(review.deletions == 2)
        #expect(review.title == "Review current changes")
    }

    @Test func preparationModelHidesReviewActionWhenOnlyConflictsExist() {
        let changes = [
            changedFile("conflicted.swift", stage: .unstaged, add: 40, del: 5, conflict: .bothModified),
        ]

        let model = ChangesPreparationModel(
            changes: changes,
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: []
        )

        #expect(model.reviewAction == nil)
        #expect(!model.isVisible)
    }

    @Test func preparationModelShowsDraftActionForStagedChanges() throws {
        let model = ChangesPreparationModel(
            changes: [
                changedFile("Sources/App.swift", stage: .staged, add: 3, del: 1),
                changedFile("Sources/View.swift", stage: .unstaged, add: 9, del: 0),
            ],
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: []
        )

        let draft = try #require(model.draftAction)
        #expect(draft.title == "Draft commit")
        #expect(draft.stagedCount == 1)
        #expect(draft.additions == 3)
        #expect(draft.deletions == 1)
        #expect(!draft.hasNonEmptyDraft)
    }

    @Test func preparationModelShowsExistingDraftWithoutStagedChanges() throws {
        let model = ChangesPreparationModel(
            changes: [],
            hasDraft: true,
            draftNonEmpty: true,
            readinessActions: []
        )

        #expect(model.isVisible)
        let draft = try #require(model.draftAction)
        #expect(draft.title == "Open draft")
        #expect(draft.stagedCount == 0)
        #expect(draft.additions == 0)
        #expect(draft.deletions == 0)
        #expect(draft.hasNonEmptyDraft)
    }

    @Test func preparationModelSelectsSingleReadinessActionByPriority() throws {
        let actions = [
            ReviewReadinessModel.Action(kind: .refresh, title: "Refresh", isEnabled: true),
            ReviewReadinessModel.Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true),
            ReviewReadinessModel.Action(kind: .openReviewRequest, title: "Open PR", isEnabled: true),
            ReviewReadinessModel.Action(kind: .createReviewRequest, title: "Create PR", isEnabled: true),
        ]

        let model = ChangesPreparationModel(
            changes: [],
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: actions
        )

        let reviewRequest = try #require(model.reviewRequestAction)
        #expect(reviewRequest.kind == .createReviewRequest)
        #expect(reviewRequest.title == "Create PR")
    }

    @Test func preparationModelFallsBackToPushBeforeOpenRequest() throws {
        let actions = [
            ReviewReadinessModel.Action(kind: .openReviewRequest, title: "Open PR", isEnabled: true),
            ReviewReadinessModel.Action(kind: .pushBranch, title: "Push", isEnabled: true),
        ]

        let model = ChangesPreparationModel(
            changes: [],
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: actions
        )

        let reviewRequest = try #require(model.reviewRequestAction)
        #expect(reviewRequest.kind == .pushBranch)
        #expect(reviewRequest.title == "Push")
    }
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests test
```

Expected: FAIL because `ChangesPreparationModel` does not exist.

- [ ] **Step 3: Add `ChangesPreparationModel`**

Create `Alas/Sources/Right/ChangesPreparationModel.swift`:

```swift
import Foundation

struct ChangesPreparationModel: Equatable {
    struct ReviewAction: Equatable {
        let title: String
        let fileCount: Int
        let additions: Int?
        let deletions: Int?
    }

    struct DraftAction: Equatable {
        let title: String
        let stagedCount: Int
        let additions: Int
        let deletions: Int
        let hasNonEmptyDraft: Bool
    }

    struct ReviewRequestAction: Equatable {
        let kind: ReviewReadinessActionKind
        let title: String
        let isEnabled: Bool
        let iconName: String
        let emphasis: ReviewReadinessModel.Action.Emphasis
    }

    let reviewAction: ReviewAction?
    let draftAction: DraftAction?
    let reviewRequestAction: ReviewRequestAction?

    var isVisible: Bool {
        reviewAction != nil || draftAction != nil || reviewRequestAction != nil
    }

    init(
        changes: [ChangedFile],
        hasDraft: Bool,
        draftNonEmpty: Bool,
        readinessActions: [ReviewReadinessModel.Action]
    ) {
        if let summary = ReviewChangesTriggerSummary.summary(for: changes) {
            reviewAction = ReviewAction(
                title: "Review current changes",
                fileCount: summary.fileCount,
                additions: summary.additions,
                deletions: summary.deletions
            )
        } else {
            reviewAction = nil
        }

        let stagedChanges = changes.filter { $0.stage == .staged }
        if !stagedChanges.isEmpty || hasDraft {
            draftAction = DraftAction(
                title: hasDraft ? "Open draft" : "Draft commit",
                stagedCount: stagedChanges.count,
                additions: stagedChanges.reduce(0) { $0 + $1.add },
                deletions: stagedChanges.reduce(0) { $0 + $1.del },
                hasNonEmptyDraft: draftNonEmpty
            )
        } else {
            draftAction = nil
        }

        reviewRequestAction = Self.compactReviewRequestAction(from: readinessActions)
    }

    private static func compactReviewRequestAction(
        from actions: [ReviewReadinessModel.Action]
    ) -> ReviewRequestAction? {
        for kind in compactActionPriority {
            guard let action = actions.first(where: { $0.kind == kind }) else { continue }
            return ReviewRequestAction(
                kind: action.kind,
                title: action.title,
                isEnabled: action.isEnabled,
                iconName: action.iconName,
                emphasis: action.emphasis
            )
        }
        return nil
    }

    private static let compactActionPriority: [ReviewReadinessActionKind] = [
        .createReviewRequest,
        .pushBranch,
        .openReviewRequest,
        .inspectReviewEvidence,
        .refresh,
    ]
}
```

- [ ] **Step 4: Run model tests and build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests test
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: both commands exit 0. If the build cannot find the new source file, run `xcodegen` and rerun both commands.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Right/ChangesPreparationModel.swift AlasTests/ReviewChangesModelsTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(changes): model preparation entry points"
```

If `Alas.xcodeproj/project.pbxproj` is unchanged, omit it from `git add`.

---

### Task 2: Preparation Card View

**Files:**
- Create: `Alas/Sources/Right/ChangesPreparationCard.swift`
- Modify: `AlasTests/ReviewChangesModelsTests.swift`

- [ ] **Step 1: Add card formatting tests**

Append these tests inside `struct ReviewChangesModelsTests`:

```swift
    @Test func preparationStatsFormatFileAndLineCounts() {
        let single = ChangesPreparationCardText.reviewStats(
            fileCount: 1,
            additions: 3,
            deletions: 1
        )
        #expect(single == "1 file · +3 −1")

        let duplicatePath = ChangesPreparationCardText.reviewStats(
            fileCount: 2,
            additions: nil,
            deletions: nil
        )
        #expect(duplicatePath == "2 files")
    }

    @Test func preparationStatsFormatDraftCounts() {
        let staged = ChangesPreparationCardText.draftStats(
            stagedCount: 2,
            additions: 9,
            deletions: 4
        )
        #expect(staged == "2 staged · +9 −4")

        let empty = ChangesPreparationCardText.draftStats(
            stagedCount: 0,
            additions: 0,
            deletions: 0
        )
        #expect(empty == "0 staged")
    }
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests test
```

Expected: FAIL because `ChangesPreparationCardText` does not exist.

- [ ] **Step 3: Add `ChangesPreparationCardText` and `ChangesPreparationCard`**

Create `Alas/Sources/Right/ChangesPreparationCard.swift`:

```swift
import SwiftUI

enum ChangesPreparationCardText {
    static func reviewStats(fileCount: Int, additions: Int?, deletions: Int?) -> String {
        let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
        guard let additions, let deletions else { return files }
        return "\(files) · +\(additions) −\(deletions)"
    }

    static func draftStats(stagedCount: Int, additions: Int, deletions: Int) -> String {
        guard stagedCount > 0 else { return "0 staged" }
        let staged = stagedCount == 1 ? "1 staged" : "\(stagedCount) staged"
        return "\(staged) · +\(additions) −\(deletions)"
    }
}

struct ChangesPreparationCard: View {
    let model: ChangesPreparationModel
    let onReviewChanges: () -> Void
    let onDraftCommit: () -> Void
    let onReviewRequestAction: (ReviewReadinessActionKind) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let reviewAction = model.reviewAction {
                primaryReviewButton(reviewAction)
            }
            if model.draftAction != nil || model.reviewRequestAction != nil {
                HStack(spacing: 8) {
                    if let draftAction = model.draftAction {
                        secondaryDraftButton(draftAction)
                    }
                    if let reviewRequestAction = model.reviewRequestAction {
                        secondaryReviewRequestButton(reviewRequestAction)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.color("bg-1"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line").opacity(0.75), lineWidth: 0.75)
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityIdentifier("changes-preparation-card")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Icon(name: "diff", size: 11, color: theme.color("fg-faint"))
            Text("Prepare")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
    }

    private func primaryReviewButton(_ action: ChangesPreparationModel.ReviewAction) -> some View {
        Button(action: onReviewChanges) {
            HStack(spacing: 9) {
                Icon(name: "diff", size: 13, color: theme.color("bg-0"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.color("bg-0"))
                    Text(ChangesPreparationCardText.reviewStats(
                        fileCount: action.fileCount,
                        additions: action.additions,
                        deletions: action.deletions
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("bg-0").opacity(0.72))
                }
                Spacer(minLength: 8)
                Icon(name: "chev-right", size: 11, color: theme.color("bg-0").opacity(0.72))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.color("accent"))
        )
        .help(action.title)
        .accessibilityIdentifier("changes-preparation-review")
    }

    private func secondaryDraftButton(_ action: ChangesPreparationModel.DraftAction) -> some View {
        secondaryButton(
            title: action.title,
            subtitle: ChangesPreparationCardText.draftStats(
                stagedCount: action.stagedCount,
                additions: action.additions,
                deletions: action.deletions
            ),
            iconName: "commit",
            showsDot: action.hasNonEmptyDraft,
            isEnabled: true,
            action: onDraftCommit
        )
        .accessibilityIdentifier("changes-preparation-draft")
    }

    private func secondaryReviewRequestButton(
        _ action: ChangesPreparationModel.ReviewRequestAction
    ) -> some View {
        secondaryButton(
            title: action.title,
            subtitle: "Branch review",
            iconName: action.iconName,
            showsDot: action.emphasis == .primary,
            isEnabled: action.isEnabled,
            action: { onReviewRequestAction(action.kind) }
        )
        .accessibilityIdentifier("changes-preparation-review-request")
    }

    private func secondaryButton(
        title: String,
        subtitle: String,
        iconName: String,
        showsDot: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(name: iconName, size: 11, color: theme.color("fg-dim"))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(theme.color("fg"))
                            .lineLimit(1)
                        if showsDot {
                            Circle()
                                .fill(theme.color("accent"))
                                .frame(width: 5, height: 5)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.color("bg-2").opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line").opacity(0.65), lineWidth: 0.75)
        )
        .help(title)
    }
}
```

- [ ] **Step 4: Run focused tests and build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests test
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: both commands exit 0. If the build cannot find the new source file, run `xcodegen` and rerun both commands.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Right/ChangesPreparationCard.swift AlasTests/ReviewChangesModelsTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(changes): add preparation card view"
```

If `Alas.xcodeproj/project.pbxproj` is unchanged, omit it from `git add`.

---

### Task 3: Integrate Card Into Changes Tab

**Files:**
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Modify: `AlasTests/ReviewChangesModelsTests.swift`

- [ ] **Step 1: Add model construction test for readiness actions**

Append this test inside `struct ReviewChangesModelsTests`:

```swift
    @Test func preparationModelCanBeBuiltFromReadinessModelActions() throws {
        let readiness = ReviewReadinessModel(
            snapshot: ReviewChangesReadinessFixtures.makeSnapshot(reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        let model = ChangesPreparationModel(
            changes: [changedFile("Sources/App.swift", stage: .unstaged, add: 2, del: 1)],
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: readiness.actions
        )

        #expect(model.reviewAction?.title == "Review current changes")
        #expect(model.reviewRequestAction?.kind == .createReviewRequest)
        #expect(model.reviewRequestAction?.title == "Create PR")
    }
```

Then add this helper after the existing private helpers in `AlasTests/ReviewChangesModelsTests.swift`:

```swift
private enum ReviewChangesReadinessFixtures {
    static func makeSnapshot(reviewRequest: ReviewRequest?) -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
        return ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: "feature/entrypoint",
                headSHA: "abc123",
                baseBranch: "main",
                hasWorkingTreeChanges: true,
                hasStagedChanges: true,
                aheadCommitCount: 1,
                hasUpstream: true,
                upstreamAheadCommitCount: 0,
                needsPush: false
            ),
            remote: remote,
            reviewRequest: reviewRequest,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }
}
```

- [ ] **Step 2: Run tests and verify they pass before UI integration**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests test
```

Expected: PASS. This confirms the model can consume real readiness actions before the view is rewired.

- [ ] **Step 3: Modify `ChangesTabView`**

In `Alas/Sources/Right/ChangesTabView.swift`, replace the old trigger rows:

```swift
            if stagedCount > 0 {
                DraftCommitTriggerRow(
                    stagedCount: stagedCount,
                    stagedAdd: stagedAdd,
                    stagedDel: stagedDel,
                    hasDraft: hasDraftTab,
                    draftNonEmpty: draftNonEmpty,
                    onOpen: openDraftTab
                )
            }
            if let reviewChangesSummary {
                ReviewChangesTriggerRow(
                    summary: reviewChangesSummary,
                    onOpen: openReviewChangesTab
                )
            }
```

with:

```swift
            if preparationModel.isVisible {
                ChangesPreparationCard(
                    model: preparationModel,
                    onReviewChanges: openReviewChangesTab,
                    onDraftCommit: openDraftTab,
                    onReviewRequestAction: { action in
                        rps.handleReviewReadinessAction(action, appState: appState)
                    }
                )
            }
```

Add this computed model near the existing `reviewChangesSummary` property:

```swift
    private var preparationModel: ChangesPreparationModel {
        let readiness = ReviewReadinessModel(
            snapshot: rps.reviewLoop.snapshot,
            lastError: rps.reviewLoop.lastError,
            canOpenAgentHandoff: rps.canOpenReviewLoopHandoff(appState: appState)
        )
        return ChangesPreparationModel(
            changes: rps.changes,
            hasDraft: hasDraftTab,
            draftNonEmpty: draftNonEmpty,
            readinessActions: readiness.actions
        )
    }
```

Remove the now-unused `reviewChangesSummary` computed property from `ChangesTabView`.

Delete the obsolete private view types from the bottom of `ChangesTabView.swift`:

- `private struct ReviewChangesTriggerRow: View`, currently beginning near line
  256, through its closing brace.
- `private struct DraftCommitTriggerRow: View`, currently beginning near line
  300, through its closing brace at the end of the file.

Keep `ReviewChangesTriggerSummary` in `ChangesTabView.swift` for now, because the model and existing tests use it.

- [ ] **Step 4: Run focused tests and build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests -only-testing:AlasTests/Integrations/ReviewReadinessModelTests test
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Right/ChangesTabView.swift AlasTests/ReviewChangesModelsTests.swift
git commit -m "feat(changes): surface preparation card"
```

---

### Task 4: Final Verification and Cleanup

**Files:**
- Review all changed files from Tasks 1-3.

- [ ] **Step 1: Scan for obsolete trigger-row references**

Run:

```bash
rg -n "DraftCommitTriggerRow|ReviewChangesTriggerRow|reviewChangesSummary" Alas/Sources AlasTests
```

Expected: no references to `DraftCommitTriggerRow` or `ReviewChangesTriggerRow`. `ReviewChangesTriggerSummary` references are expected.

- [ ] **Step 2: Regenerate project**

Run:

```bash
xcodegen
git status --short
```

Expected: no `project.yml` changes. If `Alas.xcodeproj/project.pbxproj` changes because new source files were not already present, include it in the final commit.

- [ ] **Step 3: Run focused tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests -only-testing:AlasTests/Integrations/ReviewReadinessModelTests test
```

Expected: exit 0.

- [ ] **Step 4: Run quiet build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 5: Run full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0. If a known flaky unrelated test fails, rerun that exact test once and document the result before final reporting.

- [ ] **Step 6: Commit final project cleanup if needed**

If Step 2 changed the generated Xcode project and no task commit already included it:

```bash
git add Alas.xcodeproj/project.pbxproj
git commit -m "chore: update generated project"
```

If no files changed, do not create a commit.
