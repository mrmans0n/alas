# Full GG Stack in Changes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Always show every commit in the active GG stack in Changes and identify an off-tip checkout with a compact current-position row label.

**Architecture:** Keep `gg ls --json` as stack truth, batch-hydrate its SHAs into full `CommitInfo` values with one local Git command, and publish the ordered rows atomically with the existing GG refresh generation. Preserve `RightPaneState.commits` for ordinary Git/business logic and expose a separate GG-only display list to the Commits section.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation, Foundation `Process`, git-gud JSON schema 1, Swift Testing, XcodeGen.

## Global Constraints

- Implement this entirely in Alas; do not change git-gud commands, output, or minimum version.
- Keep all code, comments, logs, tests, and UI copy in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Keep `RightPaneState.commits` authoritative for ahead counts, push/preparation decisions, comparison logic, and initial-tab selection.
- Never publish a partial or mixed-generation GG commit list.
- Keep the existing SHA-derived `CommitRowBatch` identity and batches of eight.
- Order GG stack rows by descending `position`, with the stack tip first.
- Show `Current · X of N` only when the current entry is below the stack tip.
- Keep GG-native guarded mutations available for all entries; hide generic Edit, Cherry-pick, and Revert only above the current position.
- Preserve current non-GG rows, older-history paging/divider behavior, stack chips, merged opacity, and row selection.
- Prefix repository commands with `rtk`; run Xcode builds/tests serially.
- Do not add agent attribution to commits or documentation.

---

## File Map

- Create `Alas/Sources/Git/GitService+StackCommits.swift`: batch-load arbitrary stack SHAs into `CommitInfo` values keyed by full resolved SHA.
- Create `AlasTests/GitServiceStackCommitTests.swift`: real temporary-repository coverage for batch hydration, empty input, missing objects, and malformed parser records.
- Modify `Alas/Sources/Integrations/GG/GGStackModels.swift`: project hydrated commit metadata into stack order and derive current/above/below presentation state.
- Modify `Alas/Sources/Right/RightPaneState.swift`: own the GG display rows, injectable loader seam, atomic refresh publication, failure clearing, and cancellation restoration.
- Modify `Alas/Sources/Right/ChangesTabView.swift`: pass GG display rows to the Commits section without replacing ordinary commits.
- Modify `Alas/Sources/Right/CommitsSectionView.swift`: classify upper rows, suppress only unsafe generic callbacks, and pass the current-position badge model.
- Modify `Alas/Sources/Right/CommitRow.swift`: render and expose accessibility for the selected compact row badge.
- Modify `AlasTests/Integrations/GGStackModelsTests.swift`: pure ordering, missing-commit, relation, and position-badge coverage.
- Modify `AlasTests/RightPaneGGStackTests.swift`: stub hydration for existing fake GG snapshots and cover atomic publication, fallback, cancellation, and stale generations.
- Modify `AlasTests/CommitsSectionTitleTests.swift` and `AlasTests/CommitRowTests.swift`: count/action policy and indicator/accessibility regressions.
- Regenerate `Alas.xcodeproj/project.pbxproj` after adding the two new files.

---

### Task 1: Batch-hydrate GG entry SHAs with one Git command

**Files:**
- Create: `Alas/Sources/Git/GitService+StackCommits.swift`
- Create: `AlasTests/GitServiceStackCommitTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Process.git(_:cwd:stdin:timeout:)`, `CommitInfo`, and the established `%x1e`/`%x1f`/`%x1d` commit-log record format.
- Produces: `GitService.stackCommitInfos(at:shas:) async throws -> [String: CommitInfo]`, keyed by each commit's full resolved SHA; Task 2 injects and consumes this method.
- Produces: `StackCommitInfoError.commandFailed(String)`, `.malformedRecord`, and `.missingCommits([String])` with stable localized descriptions for the existing GG failed-state presentation.

- [ ] **Step 1: Add a compiling test target and a deliberately incomplete loader**

Create `GitService+StackCommits.swift` with the public-to-module interface and empty-input behavior:

```swift
import Foundation

enum StackCommitInfoError: Error, Equatable, LocalizedError {
    case commandFailed(String)
    case malformedRecord
    case missingCommits([String])

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message.isEmpty ? "Could not load the full GG stack." : message
        case .malformedRecord:
            return "Git returned commit metadata that Alas could not read."
        case .missingCommits:
            return "One or more GG stack commits are unavailable locally."
        }
    }
}

extension GitService {
    func stackCommitInfos(at worktree: URL, shas: [String]) async throws -> [String: CommitInfo] {
        guard !shas.isEmpty else { return [:] }
        throw StackCommitInfoError.malformedRecord
    }
}
```

Create `GitServiceStackCommitTests.swift` as `@Suite(.serialized)`. Its helper must initialize a temporary `main` repository, configure a test identity, and create two commits with distinct authors, bodies, conventional subjects, and numstat. Add these assertions:

```swift
@Test func loadsRequestedCommitsByFullResolvedSHA() async throws {
    let fixture = try await makeTwoCommitRepo()
    defer { try? FileManager.default.removeItem(at: fixture.repo) }

    let infos = try await GitService().stackCommitInfos(
        at: fixture.repo,
        shas: [String(fixture.tip.prefix(7)), String(fixture.base.prefix(7))]
    )

    #expect(Set(infos.keys) == [fixture.base, fixture.tip])
    #expect(infos[fixture.base]?.subject == "base layer")
    #expect(infos[fixture.base]?.conventionalTag == "feat")
    #expect(infos[fixture.tip]?.body == "Tip details.")
    #expect(infos[fixture.tip]?.filesChanged == 1)
}

@Test func emptySHAListDoesNotInvokeGit() async throws {
    #expect(try await GitService().stackCommitInfos(
        at: URL(fileURLWithPath: "/missing"),
        shas: [String]()
    ) == [:])
}

@Test func unavailableSHAFailsTheWholeBatch() async throws {
    let fixture = try await makeTwoCommitRepo()
    defer { try? FileManager.default.removeItem(at: fixture.repo) }

    await #expect(throws: StackCommitInfoError.self) {
        _ = try await GitService().stackCommitInfos(at: fixture.repo, shas: [fixture.tip, "deadbeef"])
    }
}
```

- [ ] **Step 2: Regenerate project membership and run the new suite RED**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-full-gg-stack-task1 test -only-testing:AlasTests/GitServiceStackCommitTests
```

Expected: `loadsRequestedCommitsByFullResolvedSHA` fails with `StackCommitInfoError.malformedRecord`; empty input passes.

- [ ] **Step 3: Implement the single-command loader and strict parser**

Replace the incomplete method with one `git log` call:

```swift
func stackCommitInfos(at worktree: URL, shas: [String]) async throws -> [String: CommitInfo] {
    guard !shas.isEmpty else { return [:] }
    let format = "%x1e%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1f%b%x1d"
    let result = try await Process.git(
        ["log", "--no-walk=unsorted", "--stdin", "--pretty=tformat:\(format)", "--numstat"],
        cwd: worktree,
        stdin: shas.joined(separator: "\n") + "\n"
    )
    guard result.exitCode == 0 else {
        throw StackCommitInfoError.commandFailed(
            result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    let infos = try Self.parseStackCommitInfoRecords(result.stdout)
    let missing = shas.filter { requested in
        !infos.keys.contains { full in full.hasPrefix(requested) || requested.hasPrefix(full) }
    }
    guard missing.isEmpty else { throw StackCommitInfoError.missingCommits(missing) }
    return infos
}
```

Implement `static func parseStackCommitInfoRecords(_ stdout: String) throws -> [String: CommitInfo]` in the same extension. Split on `\u{1e}`, require six header fields split on `\u{1f}`, split the body from numstat on `\u{1d}`, require an ISO-8601 author date parsed with `.withInternetDateTime`, call `CommitInfo.parseConventional(subject:)`, and aggregate every non-empty tab-separated numstat line. Count binary `-` values as a changed file with zero additions/deletions. Throw `.malformedRecord` for any non-empty record with the wrong field count, invalid date, malformed numstat line, or duplicate resolved SHA key rather than trapping in `Dictionary(uniqueKeysWithValues:)`.

The produced value must populate every field used by existing rows:

```swift
let info = CommitInfo(
    sha: fullSHA,
    shortSha: shortSHA,
    author: author,
    authorInitials: CommitInfo.initials(for: author),
    date: date,
    subject: subject,
    rawSubject: rawSubject,
    body: body.trimmingCharacters(in: .whitespacesAndNewlines),
    conventionalTag: tag,
    filesChanged: filesChanged,
    insertions: insertions,
    deletions: deletions
)
```

- [ ] **Step 4: Extend parser edge coverage and run GREEN**

Add direct parser tests for deliberately reversed records, malformed header fields, binary numstat, and duplicate SHA records. Assert the dictionary is correct regardless of record order and malformed/duplicate records throw `.malformedRecord`.

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-full-gg-stack-task1 test -only-testing:AlasTests/GitServiceStackCommitTests
```

Expected: all `GitServiceStackCommitTests` pass.

- [ ] **Step 5: Commit the batch loader**

```bash
git add Alas/Sources/Git/GitService+StackCommits.swift AlasTests/GitServiceStackCommitTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(gg): batch load stack commit metadata"
```

---

### Task 2: Publish complete GG rows atomically from `RightPaneState`

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGStackModels.swift:105-198`
- Modify: `Alas/Sources/Right/RightPaneState.swift:114-198, 938-1075, 1615-1638`
- Modify: `AlasTests/Integrations/GGStackModelsTests.swift:1-95`
- Modify: `AlasTests/RightPaneGGStackTests.swift:393-1921`

**Interfaces:**
- Consumes: `GitService.stackCommitInfos(at:shas:)` from Task 1.
- Produces: `GGStackCommitRelation`, `GGCurrentPositionIndicator`, `GGStack.projectCommits(_:)`, `GGStack.relation(for:)`, and `GGStack.currentPositionIndicator(for:)` for Task 3.
- Produces: `RightPaneState.ggStackDisplayCommits`, `RightPaneState.commitsForDisplay`, and injectable `RightPaneState.ggStackCommitLoader` for the view and state tests.

- [ ] **Step 1: Write pure projection tests RED**

Extend `GGStackModelsTests` with a four-entry stack whose current position is 2 and a full-SHA `CommitInfo` dictionary inserted in a deliberately unrelated order. Assert:

```swift
let projected = try stack.projectCommits(infosBySHA)
#expect(projected.map(\.sha) == [full4, full3, full2, full1])
#expect(stack.relation(for: stack.entries[3]) == .aboveCurrent)
#expect(stack.relation(for: stack.entries[1]) == .current)
#expect(stack.relation(for: stack.entries[0]) == .belowCurrent)
#expect(stack.currentPositionIndicator(for: stack.entries[1]) == GGCurrentPositionIndicator(
    text: "Current · 2 of 4",
    accessibilityLabel: "Current GG commit, position 2 of 4"
))
```

Add separate expectations that `projectCommits` throws `GGStackCommitProjectionError.missingCommit(sha:)` when any entry is absent, the tip gets no indicator at `4 of 4`, and a nil/inconsistent `currentPosition` returns `.unknown` relation and no indicator.

- [ ] **Step 2: Run model tests RED**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-full-gg-stack-task2 test -only-testing:AlasTests/GGStackModelsTests
```

Expected: compilation fails because the projection types and methods do not exist.

- [ ] **Step 3: Add the pure stack projection model**

Add these module-internal types beside `GGStack`:

```swift
enum GGStackCommitRelation: Equatable {
    case aboveCurrent
    case current
    case belowCurrent
    case unknown
}

struct GGCurrentPositionIndicator: Equatable {
    let text: String
    let accessibilityLabel: String
}

enum GGStackCommitProjectionError: Error, Equatable, LocalizedError {
    case missingCommit(sha: String)

    var errorDescription: String? {
        "One or more GG stack commits are unavailable locally."
    }
}
```

Implement the methods with prefix-safe SHA matching and no inferred position:

```swift
func projectCommits(_ infosBySHA: [String: CommitInfo]) throws -> [CommitInfo] {
    try entries.sorted { $0.position > $1.position }.map { entry in
        guard let info = infosBySHA.first(where: {
            $0.key.hasPrefix(entry.sha) || entry.sha.hasPrefix($0.key)
        })?.value else {
            throw GGStackCommitProjectionError.missingCommit(sha: entry.sha)
        }
        return info
    }
}

func relation(for entry: GGStackEntry) -> GGStackCommitRelation {
    guard entries.contains(where: { $0.id == entry.id }),
          let currentPosition,
          entries.contains(where: { $0.position == currentPosition && $0.isCurrent })
    else { return .unknown }
    if entry.position > currentPosition { return .aboveCurrent }
    if entry.position == currentPosition, entry.isCurrent { return .current }
    return .belowCurrent
}

func currentPositionIndicator(for entry: GGStackEntry) -> GGCurrentPositionIndicator? {
    guard relation(for: entry) == .current,
          let currentPosition,
          currentPosition < totalCommits,
          totalCommits == entries.count
    else { return nil }
    return GGCurrentPositionIndicator(
        text: "Current · \(currentPosition) of \(totalCommits)",
        accessibilityLabel: "Current GG commit, position \(currentPosition) of \(totalCommits)"
    )
}
```

Run `GGStackModelsTests` and confirm GREEN before editing state.

- [ ] **Step 4: Add failing state tests for complete, failed, and superseded hydration**

In `RightPaneGGStackTests`, add a `makeState(worktree:)` helper that creates `RightPaneState` and installs a deterministic loader returning a full `CommitInfo` per requested SHA. Replace direct state construction in this file with that helper so existing fake GG snapshots continue testing GG behavior rather than a nonexistent on-disk repository.

Add focused tests:

```swift
@Test func successfulRefreshPublishesFullStackRowsInPositionOrder() async {
    let state = makeState()
    let reachable = commit(sha: String(repeating: "f", count: 40), stackShaped: true)
    state.commits = [reachable]
    state.ggService = GGService(runner: CountingFakeGGRunner(
        result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
    ))
    state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
    state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

    await state.refreshGGStack()

    #expect(state.ggStackLoadState == .loaded)
    #expect(state.ggStackDisplayCommits.map(\.shortSha) == ["ccccccc", "bbbbbbb", "aaaaaaa"])
    #expect(state.commitsForDisplay == state.ggStackDisplayCommits)
    #expect(state.commits == [reachable])
}
```

Add one test whose loader throws `StackCommitInfoError.missingCommits`, asserting `ggStack == nil`, `ggStackDisplayCommits.isEmpty`, `commitsForDisplay == commits`, `ggStackCommitsKey == nil`, and `.failed("One or more GG stack commits are unavailable locally.")`.

Extend the existing stale/cancellation tests to use distinct hydrated subjects per loader invocation. Assert a cancelled same-key refresh restores the previous display rows, a changed-key cancellation clears them, and a delayed stale refresh cannot overwrite the newer display rows.

- [ ] **Step 5: Run state tests RED**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-full-gg-stack-task2 test -only-testing:AlasTests/RightPaneGGStackTests -only-testing:AlasTests/RightPaneGGStackErrorPresentationTests
```

Expected: compilation fails because the display state and loader seam do not exist.

- [ ] **Step 6: Add GG display state and atomic hydration**

Add state fields near `ggStack`:

```swift
var ggStackDisplayCommits: [CommitInfo] = []
var commitsForDisplay: [CommitInfo] {
    ggStackLoadState == .loaded ? ggStackDisplayCommits : commits
}
@ObservationIgnored
var ggStackCommitLoader: @MainActor (URL, [String]) async throws -> [String: CommitInfo] = {
    worktree, shas in
    try await GitService().stackCommitInfos(at: worktree, shas: shas)
}
```

In `refreshGGStack`, capture `previousDisplayCommits` with the existing previous stack/key/load state. Clear `ggStackDisplayCommits` when entering a changed-key load. After `currentStack` returns, hydrate before the publication guards:

```swift
let displayCommits: [CommitInfo]
if let stack, !stack.entries.isEmpty {
    let infos = try await ggStackCommitLoader(worktree.path, stack.entries.map(\.sha))
    displayCommits = try stack.projectCommits(infos)
} else {
    displayCommits = []
}
```

After cancellation and generation guards pass, publish `ggStack`, `ggStackDisplayCommits`, key, load state, and summary in one synchronous main-actor block. Restore `previousDisplayCommits` only in the same-key cancellation branch that restores `previousStack`; clear display rows in every inactive, empty, changed-key cancellation, error, and `markSnapshotUnknown()` path that clears the stack. Convert `LocalizedError.errorDescription` through `error.localizedDescription`, preserving the existing special handling for `GGServiceError.userMessage`.

Do not assign hydrated rows to `commits` or `ggStackSourceCommits`.

- [ ] **Step 7: Run model and state suites GREEN**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-full-gg-stack-task2 test -only-testing:AlasTests/GGStackModelsTests -only-testing:AlasTests/RightPaneGGStackTests -only-testing:AlasTests/RightPaneGGStackErrorPresentationTests
```

Expected: all focused tests pass, including the existing cancellation/cache/undo regressions.

- [ ] **Step 8: Commit state publication**

```bash
git add Alas/Sources/Integrations/GG/GGStackModels.swift Alas/Sources/Right/RightPaneState.swift AlasTests/Integrations/GGStackModelsTests.swift AlasTests/RightPaneGGStackTests.swift
git commit -m "feat(gg): hydrate full stack commit presentation"
```

---

### Task 3: Render the selected position label and safe upper-row actions

**Files:**
- Modify: `Alas/Sources/Right/ChangesTabView.swift:315-352`
- Modify: `Alas/Sources/Right/CommitsSectionView.swift:82-338`
- Modify: `Alas/Sources/Right/CommitRow.swift:19-261`
- Modify: `AlasTests/CommitsSectionTitleTests.swift:4-88`
- Modify: `AlasTests/CommitRowTests.swift:64-153`

**Interfaces:**
- Consumes: `RightPaneState.commitsForDisplay`, `GGStack.relation(for:)`, and `GGStack.currentPositionIndicator(for:)` from Task 2.
- Produces: `CommitsSectionView.genericGitActionsAllowed(for:in:) -> Bool` and `CommitRow.currentPositionIndicator` rendering.

- [ ] **Step 1: Write failing action, count, and badge tests**

In `CommitsSectionTitleTests`, add a four-entry stack with current position 2 and assert:

```swift
#expect(!CommitsSectionView.genericGitActionsAllowed(for: stack.entries[3], in: stack))
#expect(!CommitsSectionView.genericGitActionsAllowed(for: stack.entries[2], in: stack))
#expect(CommitsSectionView.genericGitActionsAllowed(for: stack.entries[1], in: stack))
#expect(CommitsSectionView.genericGitActionsAllowed(for: stack.entries[0], in: stack))
#expect(CommitsSectionView.sectionCount(primary: fourCommits, older: twoCommits) == 6)
```

Also assert an unknown current position permits generic actions rather than hiding them on a guess, and `sectionCount(primary: [], older: []) == nil`.

In `CommitRowTests`, construct the off-tip indicator and assert its exact text/accessibility copy. Keep existing context-menu tests proving `canEdit: false, canReview: true` yields only `.review`; add a test that GG menu construction still includes Checkout and existing guarded mutations for an above-current entry.

- [ ] **Step 2: Run UI-model suites RED**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-full-gg-stack-task3 test -only-testing:AlasTests/CommitsSectionTitleTests -only-testing:AlasTests/CommitRowTests -only-testing:AlasTests/GGCommitMenuModelTests
```

Expected: compilation fails because the action/count helpers and row indicator input do not exist.

- [ ] **Step 3: Route full display rows and classify callbacks**

Change the `ChangesTabView` call site to `commits: rps.commitsForDisplay`.

In `CommitsSectionView`, expose pure helpers:

```swift
static func sectionCount(primary: [CommitInfo], older: [CommitInfo]) -> Int? {
    let count = primary.count + older.count
    return count == 0 ? nil : count
}

static func genericGitActionsAllowed(for entry: GGStackEntry?, in stack: GGStack?) -> Bool {
    guard let entry, let stack else { return true }
    return stack.relation(for: entry) != .aboveCurrent
}
```

Use `sectionCount` for the header. For each primary row, resolve `entry` once, derive `allowsGenericGitActions`, and pass:

```swift
onEdit: allowsGenericGitActions ? { onEdit(commit) } : nil,
onReview: { onReview(commit) },
onCherryPick: allowsGenericGitActions ? { rps.requestCherryPick(sha: commit.sha) } : nil,
onRevert: allowsGenericGitActions ? { rps.runRevert(sha: commit.sha) } : nil,
ggMenu: ggMenu(for: commit),
currentPositionIndicator: entry.flatMap { ggStack?.currentPositionIndicator(for: $0) },
stackEntry: entry
```

Keep `ggMenu` independent of `allowsGenericGitActions`, so stable-ID GG Checkout/Split/Drop/Unstack/Land continue through their existing guards and confirmation flows. For GG primary rows, use `rps.commitRemote` for commit URLs; retain today's `commitsNeedPush`/`primaryCommitRemote` behavior when no GG stack is loaded. Do not change older-history row actions.

- [ ] **Step 4: Render the compact metadata-line badge**

Add `var currentPositionIndicator: GGCurrentPositionIndicator? = nil` to `CommitRow`. In `metaLine`, keep the existing metadata and trailing spacer, then render:

```swift
if let indicator = currentPositionIndicator {
    Text(indicator.text)
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundColor(theme.color("accent"))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(theme.color("accent").opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel(indicator.accessibilityLabel)
}
```

Do not move the badge into `subjectLine`; the commit subject retains its current width and two-line behavior. Keep the existing blue leading rail driven by `stackEntry.isCurrent`.

- [ ] **Step 5: Run focused UI and full GG regressions GREEN**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-full-gg-stack-task3 test -only-testing:AlasTests/CommitsSectionTitleTests -only-testing:AlasTests/CommitRowTests -only-testing:AlasTests/GGCommitMenuModelTests -only-testing:AlasTests/GGStackModelsTests -only-testing:AlasTests/RightPaneGGStackTests -only-testing:AlasTests/RightPaneStateLoadOlderTests
```

Expected: all focused suites pass; the existing batching, title, GG menu, cancellation, and older-history tests remain green.

- [ ] **Step 6: Run formatting, generation, build, and full tests serially**

```bash
rtk swiftformat Alas AlasTests --lint --reporter github-actions-log
rtk git diff --check
rtk xcodegen
rtk git diff --check
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: formatting and diff checks report no issues, XcodeGen is deterministic, the macOS build succeeds, and the full test suite passes. If the full suite exposes a pre-existing failure, rerun the failing test unchanged on `main` before classifying it as unrelated; do not describe an incomplete or stalled run as passing.

- [ ] **Step 7: Perform focused manual QA**

In a disposable multi-commit GG stack, check out a non-tip entry and open Changes. Verify the entire stack is visible tip-first, the correct row shows the rail and `Current · X of N`, upper rows open details/reviews and expose GG Checkout but omit Edit/Cherry-pick/Revert, lower/current rows retain those generic actions, and selecting a row does not navigate the stack. Return to the tip and verify the rail remains while the position capsule disappears. Trigger Retry after a deliberately unavailable local stack object and confirm ordinary reachable commits remain visible without partial GG rows.

- [ ] **Step 8: Commit the UI and regression coverage**

```bash
git add Alas/Sources/Right/ChangesTabView.swift Alas/Sources/Right/CommitsSectionView.swift Alas/Sources/Right/CommitRow.swift AlasTests/CommitsSectionTitleTests.swift AlasTests/CommitRowTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(gg): show full stack position in Changes"
```

Verify the final tree contains exactly the three implementation commits after the design/plan documentation commits, with no generated or temporary files staged.
