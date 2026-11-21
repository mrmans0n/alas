# iOS Code Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the phone's one-file diff screen with a review screen showing a whole change in one scroll, with line and range comments, PR threads inline, Submit, and Send to agent.

**Architecture:**
- **Pure logic in AlasRemoteKit,** where `swift test` covers it: rows, folding, selection to anchor, comment placement, viewed marks and PR diff splitting.
- **The screen** is a `UICollectionView` wrapped for SwiftUI. It has one section per file entry and one row per diff line, with pinned file headers and a SwiftUI file strip above it.
- **Ships as four PRs,** in order: 1. the screen; 2. selection and comments; 3. PR reviews; 4. Send to agent. Each PR merges before the next one starts.

**Tech Stack:** Swift 5.9+, UIKit (`UICollectionView`, compositional layout), SwiftUI, Swift Testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-11-21-ios-code-review-design.md`

## Global Constraints

- **Package rules:** `AlasRemoteKit` builds for iOS: Foundation, CryptoKit and Observation only. Anything the app uses from the package is `public`.
- **New iOS files** need `cd Mobile && xcodegen`; commit the regenerated `Mobile/AlasMobile.xcodeproj/project.pbxproj`. Never commit the `AlasMobile.xcscheme` or `Config/AlasMobile-Local.xcconfig` changes.
- **Changing the host hello** means updating every pin of it: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift`, `AlasTests/Remote/RemoteProtocolTests.swift` and `AlasTests/Remote/RemoteServerIntegrationTests.swift` (two places).
- **Tests:** Swift Testing, pure logic only. Use `@Test(arguments:)` for variants. Extend existing suites before creating a file (`RemoteWireCompatibilityTests` for wire shapes). No view tests.
- **Commits and PRs:** Conventional Commits. No agent attribution anywhere: no Co-Authored-By, no 🤖, no "Generated with".
- **Diff colours** match today's `DiffView`: add uses `.green`, delete uses `.red`, and the row background is `tint.opacity(0.12)`. The sign glyphs are `+`, U+2212 and a space. Syntax spans come from `DiffHunksView.spans(forLines:path:)` (detached task), drawn with `ThemeTokens.attributed`.
- **Staged and unstaged stay separate entries.** The comment namespace is the stage string, as `SessionWorkspace.commentOnDiff` does.
- **Selection rule:**
  - A range stays within one hunk and one file.
  - Added and context lines anchor to the `"new"` side; removed lines anchor to `"old"`.
  - A range that mixes added and removed lines anchors to `"new"`, using the new-side numbers of the lines it covers.
- **No-target text (Mac copy):** when there's no agent to send to, use the Mac's text: "No agent to send to. Open an agent chat in this worktree, or pick an available agent in Settings → Changes."
- **Local checks per PR:**
  - `swift test --package-path Packages/AlasCore --filter '<suites>'`, then check the "Test run with N tests" line.
  - The iOS build: `xcodebuild -project AlasMobile.xcodeproj -scheme AlasMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/alas-review-dd ARCHS=arm64 -skipPackagePluginValidation -skipMacroValidation OTHER_SWIFT_FLAGS='-Xfrontend -warn-long-expression-type-checking=300' build > /tmp/review-ios.log 2>&1`, then grep for `error:` and `BUILD SUCCEEDED`.
  - `swiftformat --lint` on changed files.
  - Don't run the full Mac build; CI does it.

## Review Focus

1. **A file's diff changes while the screen is open** (an agent edits it). Refresh keeps the scroll position on the same file. A selection whose lines vanished is cleared. A viewed file whose hash changed unfolds. Covered by Task 2 (`viewedMarkClearsWhenTheDiffChanges`) and Task 4 (`selectionDropsWhenItsLinesAreGone`).
2. **A change with 200 files or 10,000 lines.** Only on-screen sections fetch their diffs. Files folded for size never fetch. Scrolling stays smooth. Covered by Task 1 (`largeAndGeneratedFilesStartFolded`) and Task 3's lazy-fetch step.
3. **Binary, truncated, renamed, deleted or empty files.** The section shows a note row instead of lines and offers nothing to select. Covered by Task 1 (`rowsForEachKindOfFile`).
4. **A comment or thread whose lines are no longer in the diff.** It shows at the top of its file, marked "Outdated"; it never disappears and never lands on the wrong line. Covered by Task 5 (`commentsPlaceUnderTheirLastLine`).
5. **An older host without a new capability, or a host that goes offline mid-review.** The matching buttons are hidden, and requests fail with the host's message rather than hanging. Covered by Task 9's gate test. The phone side is checked by hand in Task 10.

---

## PR 1: the review screen

### Task 1: Rows and folding (pure)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Review/ReviewLayout.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/RemoteWireCompatibilityTests.swift`, extended. Or create `ReviewLayoutTests.swift` if that suite has no review layout tests yet; one file for this type is fine.

**Interfaces:**
- Produces:
  ```swift
  public struct ReviewEntryID: Hashable, Sendable { public let namespace: String; public let path: String }
  public enum ReviewEntryContent: Equatable, Sendable { case notLoaded, loading, hunks([RemoteDiffHunk], truncated: Bool), note(String) }
  public struct ReviewEntry: Equatable, Sendable { public let id: ReviewEntryID; public let status: String; public let add: Int; public let del: Int; public let renameFrom: String?; public var content: ReviewEntryContent }
  public enum ReviewRow: Hashable, Sendable {
      case hunkHeader(entry: ReviewEntryID, hunk: Int)
      case line(entry: ReviewEntryID, hunk: Int, line: Int)
      case placeholder(entry: ReviewEntryID)  // loading or not yet loaded
      case note(entry: ReviewEntryID, text: String)
      case comment(entry: ReviewEntryID, id: String)   // used from Task 5
  }
  public enum ReviewLayout {
      public static func rows(for entry: ReviewEntry, folded: Bool) -> [ReviewRow]
      public static func startsFolded(path: String, add: Int, del: Int) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests.**
  - **`rowsForEachKindOfFile`** (parameterized):
    - A folded entry gives `[]`.
    - `.notLoaded` and `.loading` give `[.placeholder]`.
    - `.note("Binary file")` gives `[.note]`.
    - `.hunks` gives a `.hunkHeader` followed by one `.line` per line, for each hunk. When `truncated` is true, a final `.note("Diff truncated on the Mac")` is added.
    - Empty hunks give `[.note("No changes to show")]`.
  - **`largeAndGeneratedFilesStartFolded`** (parameterized). Each of these is `true`:
    - `Package.resolved`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`, `Podfile.lock`, `Gemfile.lock`, `go.sum`, `poetry.lock`;
    - any path under `.xcodeproj/` ending in `.pbxproj`;
    - `add + del > 1500`.

    `Sources/App.swift` with 10/2 is `false`.
- [ ] **Step 2:** Run `swift test --package-path Packages/AlasCore --filter ReviewLayout`. Expected: it fails to compile.
- [ ] **Step 3: Implement `ReviewLayout`** as specified.
- [ ] **Step 4:** Run the tests. Expected: they pass.
- [ ] **Step 5: Commit** as `feat(remote): lay out a review's rows and fold generated files`.

### Task 2: Viewed marks (pure + storage)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Review/ReviewViewedMarks.swift`
- Create: `Mobile/Sources/Workspace/Review/ReviewPreferences.swift`
- Test: the suite from Task 1.

**Interfaces:**
- Produces:
  ```swift
  public struct ReviewViewedMarks: Equatable, Sendable {
      public init(stored: [String: String] = [:])          // entry key -> diff hash
      public static func hash(of hunks: [RemoteDiffHunk]) -> String   // joins each hunk's linesHash
      public func isViewed(_ id: ReviewEntryID, hunks: [RemoteDiffHunk]) -> Bool
      public mutating func mark(_ id: ReviewEntryID, hunks: [RemoteDiffHunk])
      public mutating func unmark(_ id: ReviewEntryID)
      public var stored: [String: String] { get }
  }
  ```
- `@MainActor @Observable final class ReviewPreferences` in Mobile, with `static let shared`:
  - `var wrapsLines: Bool`, key `"reviewWrapsLines"`, default `true`.
  - `func marks(for scope: String) -> ReviewViewedMarks` and `func save(_ marks: ReviewViewedMarks, for scope: String)`, stored as a dictionary under `"reviewViewed." + scope`.
  - Follows the `ChangesComparison.shared` `didSet` pattern in `SessionWorkspace.swift`.
- The scope is the review session ID: `RemoteReviewRequest.localChangesSessionID(...)` for local changes, the provider review session for a PR, or `"commit." + sha` for a commit.

- [ ] **Step 1:** Write **`viewedMarkClearsWhenTheDiffChanges`**:
  - mark entry A with hunks H1, then `isViewed(A, H1)` is true;
  - `isViewed(A, H2)` is false when H2 differs in one line;
  - `unmark` makes it false;
  - `stored` round-trips through `init(stored:)`.
- [ ] **Step 2:** Run it and see it fail.
- [ ] **Step 3: Implement both types.**
- [ ] **Step 4:** Run the test and see it pass.
- [ ] **Step 5: Commit** as `feat(ios): remember viewed review files until their diff changes`.

### Task 3: The review screen (local changes and commits)

**Files:**
- Create: `Mobile/Sources/Workspace/Review/ReviewScreen.swift`: the SwiftUI shell, with the file strip, toolbar (wrap/scroll and "Fold All") and action bar.
- Create: `Mobile/Sources/Workspace/Review/ReviewCollectionView.swift`: the `UIViewControllerRepresentable` and its controller.
- Create: `Mobile/Sources/Workspace/Review/ReviewCells.swift`: `FileHeaderView` (pinned supplementary), `HunkHeaderCell`, `LineCell`, `NoteCell`.
- Create: `Mobile/Sources/Workspace/Review/ReviewDocument.swift`: the model.
- Modify: `Mobile/Sources/Workspace/SessionWorkspace.swift`: a keyed diff fetch.
- Modify: `Mobile/Sources/Workspace/ChangesView.swift`: open `ReviewScreen` instead of `DiffView`.
- Delete: `Mobile/Sources/Workspace/DiffView.swift`, once nothing references it. Keep `DiffHunksView` (Transcript) as it is.

**Interfaces:**
- Consumes: Tasks 1–2; `SessionWorkspace.changeHunk(_:index:_:)`, `canChangeHunks`, `ChangeListReply`, `CommitFilesReply`, `DiffKey`, `DiffReply`.
- Produces:
  - `SessionWorkspace.loadDiff(_ key: DiffKey) async -> Result<DiffReply, RemoteGitFailure>`. It sends the same message `requestDiff` sends. Replies are matched to waiters by key (path, stage and sha), and the existing reply handlers at `SessionWorkspace.swift` ~688/~702 also resume these waiters. The current `diff` singleton stays only while something still uses it; remove it if nothing does.
  - `@MainActor @Observable final class ReviewDocument`:
    - `init(workspace: SessionWorkspace, source: ReviewSource, focus: ReviewEntryID?)`
    - `var entries: [ReviewEntry]`
    - `var folded: Set<ReviewEntryID>`
    - `var marks: ReviewViewedMarks`
    - `func load(_ id: ReviewEntryID)`, idempotent
    - `func refresh() async`
    - `func toggleViewed(_ id: ReviewEntryID)`
  - `enum ReviewSource: Equatable { case localChanges, commit(sha: String) }`. Task 8 adds `case pullRequest(sessionID: String)`.
  - Local entries are `staged` first, then `unstaged`, from `ChangeListReply`. Commit entries use the namespace `"commit"` and the commit's files.
  - `ReviewScreen(workspace:source:focus:)` is pushed from ChangesView. Tapping a file opens it focused on that entry.

- [ ] **Step 1: Keyed fetch.** Add `loadDiff` and its waiter map in SessionWorkspace. Two concurrent loads of the same key share one request.
- [ ] **Step 2: `ReviewDocument`.**
  - Build entries from the source and set `folded` from `ReviewLayout.startsFolded` and the viewed marks.
  - `load` fetches through `loadDiff` and sets `content`.
  - `refresh` re-fetches the change list, keeps the entries' order where paths match, and re-fetches the loaded entries and the viewed ones. A viewed entry whose hash changed is unmarked and unfolded.
  - Syntax spans are computed per entry with `DiffHunksView.spans(forLines:path:)` in a detached task and cached by the entry's hunk hash.
- [ ] **Step 3: Collection view.**
  - Use a compositional list layout with one section per entry. Each section has a pinned header showing the path, `+add −del`, a fold chevron and a Viewed checkbox.
  - Use a diffable data source whose items are `ReviewRow`s.
  - `collectionView(_:willDisplay:forItemAt:)` on a `.placeholder` calls `document.load`. Folded sections have no rows, so they never fetch.
  - The hunk header cell shows the `@@` header. Its menu holds stage/unstage/discard when `canChangeHunks` allows them; this is today's `DiffView.hunkActions` logic, moved.
  - `LineCell` has a fixed-width gutter (old and new numbers), the sign, then the code in a `UILabel` showing the attributed line.
  - Scroll to the focused entry on first load.
- [ ] **Step 4: Wrap/scroll.**
  - **Wrap:** `numberOfLines = 0`, and cells self-size.
  - **Scroll:** `numberOfLines = 1` with no truncation. A `UIPanGestureRecognizer` on the collection view starts only when the horizontal velocity is greater than the vertical velocity. It moves a per-section offset (`[ReviewEntryID: CGFloat]`, clamped to the widest line minus the code width), applied as a `transform` on every visible code label of that section. The gutter does not move.
  - The toggle reads and writes `ReviewPreferences.shared.wrapsLines`.
- [ ] **Step 5: File strip.** A horizontal `ScrollView` of chips, one per entry: the file name, a check when viewed, and accent when current. The current entry is the topmost visible section, reported by the controller. Tapping a chip scrolls its section header to the top.
- [ ] **Step 6: Wire into ChangesView.** Replace the `DiffView` destinations, both the working-tree one and the commit one in `CommitFilesView`, with `ReviewScreen`. Delete `DiffView.swift`.
- [ ] **Step 7: VoiceOver.** Each line cell reads `"line \(n), added|removed|unchanged, \(text)"`. The header reads the path, the counts and the viewed state.
- [ ] **Step 8: Checks.** Run the iOS build with the long-expression flag (no `error:`, `BUILD SUCCEEDED`), `cd Mobile && xcodegen` for the new files, and `swiftformat --lint`.
- [ ] **Step 9: Commit** as `feat(ios): review a whole change in one scroll, with a file strip`.

Ship PR 1 (push, PR, Codex, CI) before starting PR 2.

## PR 2: line selection and comments

### Task 4: Selection to anchor (pure)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Review/ReviewSelection.swift`
- Test: the Task 1 suite.

**Interfaces:**
- Produces:
  ```swift
  public struct ReviewSelection: Equatable, Sendable {
      public let entry: ReviewEntryID; public let hunk: Int
      public private(set) var start: Int; public private(set) var end: Int   // line indexes in the hunk, start <= end
      public init(entry: ReviewEntryID, hunk: Int, line: Int)
      public mutating func extend(to line: Int, inHunk hunk: Int)   // ignored for another hunk
      public func anchor(in hunk: RemoteDiffHunk) -> RemoteReviewAnchor  // per the Selection rule
      public func isValid(in hunks: [RemoteDiffHunk]) -> Bool
      public func quotedText(in hunk: RemoteDiffHunk) -> String           // "+ "/"- "/"  " prefixed lines
  }
  ```

- [ ] **Step 1: Write the failing tests.**
  - **`selectionAnchorsToOneSide`** (parameterized):
    - one added line 42 gives `.line(side: "new", startLine: 42, endLine: nil)`;
    - added 42–43 gives `.line("new", 42, 43)`;
    - removed old 10–11 gives `.line("old", 10, 11)`;
    - removed old 10 plus added new 10–11 gives `.line("new", 10, 11)`;
    - context only, new 5–7, gives `.line("new", 5, 7)`.
  - **`extendingStaysInItsHunk`:** extending into another hunk changes nothing; extending backwards swaps start and end.
  - **`selectionDropsWhenItsLinesAreGone`:** `isValid` is false when the hunk index or the end index is out of range.
- [ ] **Step 2:** Run the tests and see them fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the tests and see them pass.
- [ ] **Step 5: Commit** as `feat(remote): turn a selected line range into a review anchor`.

### Task 5: Comment placement (pure)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Review/ReviewCommentPlacement.swift`
- Test: the Task 1 suite.

**Interfaces:**
- Produces:
  ```swift
  public struct ReviewPlaceable: Equatable, Sendable { public let id: String; public let side: String?; public let line: Int?; public let endLine: Int? }
  public enum ReviewCommentPlacement {
      /// Row index (into ReviewLayout.rows(for:folded:false)) after which each comment goes; nil = top of file, shown as Outdated.
      public static func place(_ items: [ReviewPlaceable], in hunks: [RemoteDiffHunk]) -> [String: Int?]
  }
  ```
- `ReviewLayout.rows` gains `comments: [String: Int?] = [:]`:
  - the `.comment` rows are inserted after their row;
  - `nil` ones go after the first row of the file. Show them as rows directly under the file header (the hunk header row is index 0).

- [ ] **Step 1: Write `commentsPlaceUnderTheirLastLine`** (parameterized):
  - a `"new"` 42–43 comment goes after the row of new line 43;
  - an `"old"` 10 comment goes after the row of old line 10;
  - line 999, which isn't in the diff, gives `nil`;
  - `side: nil, line: nil` (a file comment) gives `nil`;
  - two comments on the same line keep their input order.
- [ ] **Step 2:** Run the test and see it fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the test and see it pass.
- [ ] **Step 5: Commit** as `feat(remote): place review comments under the lines they're on`.

### Task 6: Selecting and commenting on the screen

**Files:**
- Modify: `ReviewCollectionView.swift`, `ReviewCells.swift`, `ReviewDocument.swift`, `ReviewScreen.swift`
- Create: `Mobile/Sources/Workspace/Review/ReviewCommentCell.swift`
- Modify: `SessionWorkspace.swift`: generalize `commentOnDiff`.

**Interfaces:**
- Consumes: Tasks 4–5; `SessionWorkspace.review(_:)`, `changeReview(_:_:)`, `CommentSheet` (in `ReviewsView.swift`, with the optional `confirmation:` from #2661), `RemoteReviewMutation`.
- Produces:
  - `SessionWorkspace.comment(in sessionID: String, entry: ReviewEntryID, anchor: RemoteReviewAnchor, body: String) async -> String?`. It replaces `commentOnDiff`, using `RemoteReviewFileID(namespace: entry.namespace, path: entry.path)`.
  - `ReviewDocument`:
    - `var selection: ReviewSelection?`
    - `var comments: [RemoteReviewComment]`
    - `var reviewSessionID: String?` (the local-changes ID for `.localChanges`, nil for commits, so commits can't be commented on)
    - `func loadComments() async`
  - `ReviewScreen` exposes a `ReviewCommentCell` that Task 8 reuses for threads.

- [ ] **Step 1: Tap gestures.** Tapping a line's gutter starts a selection. Tapping another gutter in the same hunk extends it; tapping one in another hunk starts a new selection. Tapping the code area does nothing.
- [ ] **Step 2: Long-press and drag.**
  - A `UILongPressGestureRecognizer` (minimum duration 0.3 s) starts the selection at the pressed line, then extends it as the finger moves.
  - Within 60 pt of the top or bottom edge, a `CADisplayLink` auto-scrolls at a speed proportional to the depth into the edge band, capped at 900 pt/s.
  - Scrolling and the sideways pan must fail while the long press is active.
- [ ] **Step 3: Selection UI.**
  - Selected rows get the accent background, `opacity(0.18)`.
  - A floating "Comment" pill at the bottom of the selection opens `CommentSheet`, titled `"Lines 42–43"` (or `"Line 42"`), with `quotedText` shown above the field.
  - Saving calls `comment(in:entry:anchor:body:)`, then `loadComments()`, and clears the selection.
- [ ] **Step 4: Inline comments.**
  - Comments are placed through `ReviewCommentPlacement`. Each one shows as a `ReviewCommentCell` with the author, the Markdown body, the state, and "Outdated" when its placement is nil.
  - Its context menu holds Edit, Resolve, Dismiss and Delete, through `changeReview`; this is the logic `ReviewsView` uses today.
  - Remove "Comment on Hunk…" and "Comment on File" from the old code paths. Keep "Comment on File" in the file header's menu, with a `.file` anchor.
- [ ] **Step 5: VoiceOver custom actions** on line cells: "Select line", "Extend selection to here" and "Comment on selection".
- [ ] **Step 6: Run the checks** (iOS build, lint).
- [ ] **Step 7: Commit** as `feat(ios): comment on a line or a range in the review, by tap or drag`.

Ship PR 2 before PR 3.

## PR 3: pull request reviews in the screen

### Task 7: The PR diff and thread positions on the wire

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasRemoteKit/Protocol/RemoteReviewRequest.swift`
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Review/PullRequestDiff.swift`
- Test: `RemoteWireCompatibilityTests` (extend `phoneReadsAndAnswersAPullRequestsThreads`) and the Task 1 suite.

**Interfaces:**
- Produces:
  - `RemoteReviewRequest.readProvider(id:projectID:path:sessionID:withDiff: Bool)`, where `withDiff` defaults to `false`.
  - `RemoteProviderReview` gains `diff: String?`, `diffTruncated: Bool` and `baseSHA: String?`.
  - `RemoteProviderThread` gains `side: String?` and `startLine: Int?`, decoded from the host's `ReviewThread`.
  - `PullRequestDiff.entries(raw: String, namespace: String) -> [ReviewEntry]`. It splits on `diff --git ` boundaries and parses each section with `DiffParser.parse`, then converts to `RemoteDiffHunk`/`RemoteDiffLine` (`kind` strings `"add"`, `"delete"`, `"context"`). Binary sections become `.note("Binary file")`. If `ReviewRequestDiffLoader.splitFileSections` in AlasIntegrations is dependency-free, move it to AlasRemoteKit and call it from both places; otherwise reimplement it here.
  - The namespace is the one the Mac's PR review files its comments under. Find it in `ReviewRequestDiffLoader.namespace(for:)` and use that exact value.

- [ ] **Step 1: Write the failing tests.**
  - Extend `phoneReadsAndAnswersAPullRequestsThreads`: the `withDiff: true` request decodes as the Mac's `HostRequest` with `withDiff == true`, and a real `HostProviderReview` with `diff` and a thread with `side`/`startLine` decodes on the phone.
  - **`pullRequestDiffSplitsIntoEntries`:** a 3-file raw diff (a modified file, a renamed one with `renameFrom`, a binary one) gives 3 entries with the right paths, statuses and contents.
- [ ] **Step 2:** Run the tests and see them fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the tests and see them pass.
- [ ] **Step 5: Commit** as `feat(remote): read a pull request's diff and thread positions on the phone`.

### Task 8: The PR review in the screen

**Files:**
- Modify: `ReviewDocument.swift`, `ReviewScreen.swift`, `ReviewCollectionView.swift`
- Modify: `Mobile/Sources/Workspace/ReviewsView.swift`: move `SubmitReviewSheet` into `Mobile/Sources/Workspace/Review/SubmitReviewSheet.swift`, and add a "Review Code" button.
- Modify: `SessionWorkspace.swift`: `pullRequestReview(_ sessionID:, withDiff: Bool)`.

**Interfaces:**
- Consumes: Task 7; `submitReview(_:_:body:headSHA:)`, `changeThread`, `PullRequestThreadRow` (#2661).
- Produces: `ReviewSource.pullRequest(sessionID: String)`. For this source:
  - entries come from `PullRequestDiff.entries`, which loads everything at once, so there's no lazy fetch;
  - `reviewSessionID` is the PR session;
  - threads are placed with `ReviewCommentPlacement`, using the thread's `side`, `startLine` and `line`.

- [ ] **Step 1: "Review Code" button.** In `ReviewDetailView`, for a `review-request` review, add a "Review Code" toolbar button that pushes `ReviewScreen(source: .pullRequest(sessionID:))`.
- [ ] **Step 2: Threads inline.** Show threads with the existing reply/resolve actions and confirmations from #2661. Drafts and threads share the comment cell style.
- [ ] **Step 3: Truncated diffs and refresh.**
  - When `diffTruncated`, show a top banner: "This pull request's diff is too big for the phone; some files are missing."
  - Pull-to-refresh re-reads with `withDiff: true`; nothing polls.
- [ ] **Step 4: Action bar.** It shows the draft count and **Submit…**, which opens `SubmitReviewSheet` with the review's `headSHA`.
- [ ] **Step 5: Run the checks.**
- [ ] **Step 6: Commit** as `feat(ios): review a pull request's code on the phone, threads inline`.

Ship PR 3 before PR 4.

## PR 4: Send to agent

### Task 9: Host request, seam and capability

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`: two `HostRequest` cases and two responses.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift`: serve them; phone or headless gate.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/...AlasCoreContext.swift`: the seam.
- Modify: `Packages/AlasCore/Sources/AlasRemoteKit/Protocol/RemoteProtocol.swift`: the capability constant.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol+Host.swift`: advertise it after `reviewsProviderPhoneV1`.
- Modify: `Alas/Sources/App/AppState.swift` (near the `core.worktreeDestinationExistence =` assignment, ~:422): install the seam.
- Modify: `Packages/AlasCore/Sources/AlasRemoteKit/Protocol/RemoteReviewRequest.swift`: phone requests and replies.
- Tests: `HostProtocolServerTests`, `HostProtocolTests` (hello pin), `RemoteWireCompatibilityTests`, and the AlasTests hello pins (3 places).

**Interfaces:**
- Produces:
  - `HostProtocolCapability.reviewsAgentPhoneV1 = "host.reviews.agent.phone.v1"`.
  - `HostRequest.reviewAgentTargets(worktree: WorktreeRef, sessionID: String)` returns `.reviewAgentTargets(targets: [ReviewFeedbackAgentTarget])`.
  - `HostRequest.sendReviewToAgent(worktree: WorktreeRef, sessionID: String, target: ReviewFeedbackAgentTarget)` returns `.reviewSentToAgent`.
  - The seam:
    ```swift
    public struct ReviewAgentSeam: Sendable {
        public var targets: @Sendable (_ worktreeID: String) async -> [ReviewFeedbackAgentTarget]
        public var send: @Sendable (_ worktreeID: String, _ sessionID: String, _ target: ReviewFeedbackAgentTarget) async throws -> Void
    }
    // on AlasCoreContext:
    public var reviewAgents: ReviewAgentSeam?
    ```
    When `reviewAgents` is nil, as on headless hosts, both requests throw `HostError.invalidRequest(reason: "This host can't send reviews to agents.")`.
  - On the Mac, `AppState` installs the seam:
    - `targets` uses `ReviewFeedbackAgentSender.production(appState:worktreeID:).availableTargets()`;
    - `send` loads the review session's draft comments, builds the `ReviewFeedbackBundle` the way `DiffReviewSurface` does (~:221), and calls `ReviewFeedbackPromptActions.sendToAgent(_:target:sender:sessionID:recordHandoff:...)`;
    - for a local-changes session, the sender is wrapped in `.recordingReviewedWorkingTree(<current working tree>, worktreeID:)`, capturing the tree the same way the Mac's Review workspace does when its user sends.
  - Phone side: `RemoteReviewRequest.agentTargets(...)`, `.sendToAgent(...)` and `agentTargets(in:) -> [RemoteAgentTarget]`, with `RemoteAgentTarget { kind: "newChat" | "existingSession", id, title, sessionID? }` mirroring `ReviewFeedbackAgentTarget`'s Codable shape.

- [ ] **Step 1: Write the failing tests.**
  - In `HostProtocolServerTests`:
    - a phone caller on an app host with a fake seam gets its targets;
    - `send` reaches the seam with the session and target;
    - with no seam, the request is refused with the exact reason above.
  - In `RemoteWireCompatibilityTests`: both phone requests decode as `HostRequest`, and the targets reply decodes on the phone.
  - Update the hello pins in `HostProtocolTests` and in the three AlasTests places.
- [ ] **Step 2:** Run `swift test --package-path Packages/AlasCore --filter 'HostProtocolServerTests|HostProtocolTests|RemoteWireCompatibilityTests'` and see it fail.
- [ ] **Step 3: Implement** the host side and the seam. Install it in AppState.
- [ ] **Step 4:** Run the tests and see them pass. Grep `AlasTests` for any other pin of the capability list.
- [ ] **Step 5: Commit** as `feat(remote): let the phone send a review to an agent through the Mac`.

### Task 10: Send to agent on the phone

**Files:**
- Modify: `SessionWorkspace.swift`: `reviewAgentTargets(_ sessionID:) async -> Result<[RemoteAgentTarget], RemoteGitFailure>` and `sendReview(_ sessionID:, to: RemoteAgentTarget) async -> String?`.
- Modify: `ReviewScreen.swift`: the action-bar button and the target picker.

**Interfaces:**
- Consumes: Task 9.

- [ ] **Step 1: The button.** **Send to agent** shows when the host supports `reviewsAgentPhoneV1` and the review has at least one open draft. It sits next to Submit… for a PR.
- [ ] **Step 2: Targets.**
  - Tapping it fetches the targets.
  - **None:** show the Mac's no-target text.
  - **One:** a confirmation alert, "Send N comments to <title>?".
  - **Several:** a `confirmationDialog` listing them, with the phone's current session (`existingSession` whose `sessionID` is the workspace's `sessionId`) first and marked "(this chat)".
- [ ] **Step 3: After sending.**
  - **Success:** a brief "Sent to <title>" banner, then reload the comments, which the Mac marks as sent.
  - **Failure:** show the host's message.
- [ ] **Step 4: Check by hand** against an older host: the button is hidden.
- [ ] **Step 5: Run the checks** (iOS build, lint).
- [ ] **Step 6: Commit** as `feat(ios): send a review's comments to an agent from the phone`.

Ship PR 4.
