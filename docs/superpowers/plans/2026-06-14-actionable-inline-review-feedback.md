# Actionable Inline Review Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make inline PR/MR feedback cards actionable and synchronized with the Feedback evidence list.

**Architecture:** Add small provider-agnostic focus/action models to the shared `DiffReview` layer, then wire those models from `ReviewEvidenceTabView`. Keep provider writes out of scope; actions are open URL, copy context, and send existing read-only context to the configured agent.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, AppKit clipboard/browser integration, existing `DiffReviewSurface` and `ReviewEvidenceModel`.

---

## File Map

- Create `Alas/Sources/Center/DiffReview/DiffReviewInlineFeedbackActions.swift`
  - Focus command, context formatter, and action availability models for inline feedback.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
  - Accept focused feedback state, feedback scroll command, and inline action closures.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
  - Render focused treatment and Open/Copy/Send buttons on inline cards.
- Modify `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`
  - Bridge Feedback list selection to Files scrolling, wire action closures, and synchronize selected feedback.
- Test `AlasTests/DiffReviewSurfaceTests.swift`
  - Shared surface/card behavior.
- Test `AlasTests/Integrations/ReviewEvidenceModelTests.swift`
  - Pure route/action helper behavior.

---

### Task 1: Inline Feedback Focus And Context Models

**Files:**
- Create: `Alas/Sources/Center/DiffReview/DiffReviewInlineFeedbackActions.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`
- Generated after `xcodegen`: `Alas.xcodeproj/project.pbxproj` when the new source file is added to the project

- [ ] **Step 1: Write failing tests for context formatting and scroll commands**

Add tests near the existing inline feedback tests in `AlasTests/DiffReviewSurfaceTests.swift`:

```swift
@Test func inlineFeedbackContextFormatterIncludesReviewMetadata() {
    let file = summary(path: "Sources/App.swift")
    let item = DiffReviewInlineFeedback(
        id: "thread-1",
        providerName: "GitHub",
        author: "reviewer",
        bodyPreview: "Please update `configId`.",
        status: .actionable,
        providerURL: URL(string: "https://github.com/org/repo/pull/1#discussion_r1"),
        anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 56, side: .new),
        evidenceItemID: "thread-1"
    )

    let context = DiffReviewInlineFeedbackContextFormatter.format(item: item, file: file)

    #expect(context.contains("GitHub feedback"))
    #expect(context.contains("Author: reviewer"))
    #expect(context.contains("File: Sources/App.swift"))
    #expect(context.contains("Line: 56"))
    #expect(context.contains("Side: new"))
    #expect(context.contains("URL: https://github.com/org/repo/pull/1#discussion_r1"))
    #expect(context.contains("Please update `configId`."))
}

@Test func inlineFeedbackScrollCommandAdvancesForRepeatedSelections() {
    let fileID = DiffReviewFileID(namespace: "github-pr", path: "Sources/App.swift")
    var controller = DiffReviewInlineFeedbackScrollController()

    let first = controller.command(feedbackID: "thread-1", fileID: fileID)
    let second = controller.command(feedbackID: "thread-1", fileID: fileID)

    #expect(first.feedbackID == "thread-1")
    #expect(first.fileID == fileID)
    #expect(second.generation == first.generation + 1)
    #expect(second.targetID == "diff-review-inline-feedback-target-\(fileID.rawValue)-thread-1")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: FAIL because `DiffReviewInlineFeedbackContextFormatter`, `DiffReviewInlineFeedbackScrollController`, and related command types do not exist.

- [ ] **Step 3: Add the shared models**

Create `Alas/Sources/Center/DiffReview/DiffReviewInlineFeedbackActions.swift`:

```swift
import Foundation

struct DiffReviewInlineFeedbackScrollCommand: Equatable {
    let feedbackID: String
    let fileID: DiffReviewFileID
    let generation: Int

    var targetID: String {
        DiffReviewInlineFeedbackTargetID.targetID(feedbackID: feedbackID, fileID: fileID)
    }
}

struct DiffReviewInlineFeedbackScrollController: Equatable {
    private(set) var generation = 0

    mutating func command(feedbackID: String, fileID: DiffReviewFileID) -> DiffReviewInlineFeedbackScrollCommand {
        generation += 1
        return DiffReviewInlineFeedbackScrollCommand(
            feedbackID: feedbackID,
            fileID: fileID,
            generation: generation
        )
    }
}

enum DiffReviewInlineFeedbackTargetID {
    static func targetID(feedbackID: String, fileID: DiffReviewFileID) -> String {
        "diff-review-inline-feedback-target-\(fileID.rawValue)-\(feedbackID)"
    }
}

struct DiffReviewInlineFeedbackActionAvailability: Equatable {
    var canOpenProvider: Bool
    var canCopyContext: Bool
    var canSendToAgent: Bool

    static let none = DiffReviewInlineFeedbackActionAvailability(
        canOpenProvider: false,
        canCopyContext: false,
        canSendToAgent: false
    )
}

struct DiffReviewInlineFeedbackActions {
    var availability: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> DiffReviewInlineFeedbackActionAvailability = { _, _ in .none }
    var openProvider: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> Void = { _, _ in }
    var copyContext: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> Void = { _, _ in }
    var sendToAgent: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> Void = { _, _ in }
}

enum DiffReviewInlineFeedbackContextFormatter {
    static func format(item: DiffReviewInlineFeedback, file: DiffReviewFileSummary) -> String {
        var lines: [String] = []
        lines.append("# \(item.providerName) feedback")
        if let author = item.author, !author.isEmpty {
            lines.append("Author: \(author)")
        }
        lines.append("File: \(file.path)")
        if let line = item.anchor.line {
            lines.append("Line: \(line)")
        }
        lines.append("Side: \(item.anchor.side.rawValue)")
        if let providerURL = item.providerURL {
            lines.append("URL: \(providerURL.absoluteString)")
        }
        lines.append("")
        lines.append(item.bodyPreview)
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Regenerate project and run tests**

Run:

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: PASS for the new tests. After `xcodegen`, run `git status --short Alas.xcodeproj/project.pbxproj`; when the project file is modified, include it in the Task 1 commit.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewInlineFeedbackActions.swift AlasTests/DiffReviewSurfaceTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(diff): add inline feedback action models"
```

---

### Task 2: Inline Card Focus And Action Buttons

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Write failing tests for focused card and action affordances**

Add tests in `AlasTests/DiffReviewSurfaceTests.swift`:

```swift
@Test func fileSectionHighlightsFocusedInlineFeedbackAndShowsActions() {
    let file = DiffReviewFileSectionModel(
        summary: summary(path: "Sources/App.swift"),
        parsedDiff: parsedDiff(),
        displayModel: displayModel(),
        placeholderMessage: nil,
        openFile: nil
    )
    let feedback = [
        DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please update this.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/thread")!,
            anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: 2, side: .new),
            evidenceItemID: "thread-1"
        ),
    ]
    var layout = DiffLayoutMode.split
    var wrap = false
    var whitespace = false
    let actions = DiffReviewInlineFeedbackActions(
        availability: { _, _ in .init(canOpenProvider: true, canCopyContext: true, canSendToAgent: true) },
        openProvider: { _, _ in },
        copyContext: { _, _ in },
        sendToAgent: { _, _ in }
    )

    let view = DiffReviewFileSection(
        file: file,
        inlineFeedback: feedback,
        focusedFeedbackID: "thread-1",
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "",
        codeFontSize: 13,
        showsSourceBadge: false,
        inlineFeedbackActions: actions,
        onSelectInlineFeedback: { _ in }
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 900, height: 500)

    #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-focused-thread-1", in: controller.view) != nil)
    #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-open-thread-1", in: controller.view) != nil)
    #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-copy-thread-1", in: controller.view) != nil)
    #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-send-thread-1", in: controller.view) != nil)
}

@Test func inlineFeedbackActionsHideUnavailableButtons() {
    let availability = DiffReviewInlineFeedbackActionAvailability(
        canOpenProvider: false,
        canCopyContext: true,
        canSendToAgent: false
    )

    #expect(availability.canOpenProvider == false)
    #expect(availability.canCopyContext)
    #expect(availability.canSendToAgent == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: FAIL because `DiffReviewFileSection` does not accept focused feedback/action parameters and card action markers are absent.

- [ ] **Step 3: Update `DiffReviewFileSection` API and card rendering**

In `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`:

Add stored properties to `DiffReviewFileSection`:

```swift
var focusedFeedbackID: String? = nil
var inlineFeedbackActions = DiffReviewInlineFeedbackActions()
var onSelectInlineFeedback: (DiffReviewInlineFeedback) -> Void = { _ in }
```

Pass these into each inline stack:

```swift
inlineFeedbackStack(fileLevel, file: file.summary)
inlineFeedbackStack(groupFeedback, file: file.summary)
```

Update the stack signature:

```swift
private func inlineFeedbackStack(_ items: [DiffReviewInlineFeedback], file: DiffReviewFileSummary) -> some View
```

Render cards with the new parameters:

```swift
DiffReviewInlineFeedbackCard(
    item: item,
    file: file,
    isFocused: item.id == focusedFeedbackID,
    actions: inlineFeedbackActions,
    onSelect: { onSelectInlineFeedback(item) }
)
.id(DiffReviewInlineFeedbackTargetID.targetID(feedbackID: item.id, fileID: file.id))
```

Update `DiffReviewInlineFeedbackCard` to include:

```swift
let file: DiffReviewFileSummary
let isFocused: Bool
let actions: DiffReviewInlineFeedbackActions
let onSelect: () -> Void
```

Wrap the card in a plain `Button(action: onSelect)` or attach `.onTapGesture(perform: onSelect)` with a `contentShape(Rectangle())`. Add a focused marker:

```swift
.background(
    DiffReviewAccessibilityMarker(
        identifier: isFocused ? "diff-review-inline-feedback-focused-\(item.id)" : "diff-review-inline-feedback-\(item.id)",
        label: accessibilityLabel
    )
)
```

Add the action row at the trailing side or bottom of the card:

```swift
private var actionRow: some View {
    let availability = actions.availability(item, file)
    return HStack(spacing: 6) {
        if availability.canOpenProvider {
            inlineActionButton(id: "open", title: "Open") { actions.openProvider(item, file) }
        }
        if availability.canCopyContext {
            inlineActionButton(id: "copy", title: "Copy") { actions.copyContext(item, file) }
        }
        if availability.canSendToAgent {
            inlineActionButton(id: "send", title: "Send") { actions.sendToAgent(item, file) }
        }
    }
}
```

Use stable accessibility identifiers:

```swift
".accessibilityIdentifier(\"diff-review-inline-feedback-\(id)-\(item.id)\")"
```

Keep the existing markdown body rendering and dynamic height behavior unchanged.

- [ ] **Step 4: Update `DiffReviewSurface` to pass parameters**

In `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`, add:

```swift
var focusedFeedbackID: String? = nil
var inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand? = nil
var inlineFeedbackActions = DiffReviewInlineFeedbackActions()
var onSelectInlineFeedback: (DiffReviewInlineFeedback) -> Void = { _ in }
```

Pass `focusedFeedbackID`, `inlineFeedbackActions`, and `onSelectInlineFeedback` to `DiffReviewFileSection`.

Add scroll handling near the existing file scroll command:

```swift
.onChange(of: inlineFeedbackScrollCommand) { _, command in
    guard let command else { return }
    selectedFileID = command.fileID
    withAnimation(.easeInOut(duration: 0.18)) {
        scrollProxy.scrollTo(command.targetID, anchor: .center)
    }
}
```

Ensure `effectiveRenderedFileIDs` includes the command target file by treating `inlineFeedbackScrollCommand?.fileID` like `programmaticScroll.target`.

- [ ] **Step 5: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: PASS.

- [ ] **Step 6: Commit Task 2**

Run:

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewSurface.swift Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift AlasTests/DiffReviewSurfaceTests.swift
git commit -m "feat(diff): add actionable inline feedback cards"
```

---

### Task 3: Review Evidence Selection And Action Wiring

**Files:**
- Modify: `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`
- Test: `AlasTests/Integrations/ReviewEvidenceModelTests.swift`

- [ ] **Step 1: Write failing tests for pure navigation helpers**

Add tests in `AlasTests/Integrations/ReviewEvidenceModelTests.swift`:

```swift
@Test func inlineFeedbackLookupFindsFeedbackByEvidenceItemID() {
    let fileID = DiffReviewFileID(namespace: "github-pr", path: "Sources/App.swift")
    let feedback = DiffReviewInlineFeedback(
        id: "thread-inline",
        providerName: "GitHub",
        author: "reviewer",
        bodyPreview: "Please update this.",
        status: .actionable,
        providerURL: URL(string: "https://github.com/thread"),
        anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 12, side: .new),
        evidenceItemID: "evidence-thread"
    )

    let match = ReviewEvidenceInlineFeedbackNavigator.match(
        evidenceItemID: "evidence-thread",
        inlineFeedbackByFileID: [fileID: [feedback]]
    )

    #expect(match?.fileID == fileID)
    #expect(match?.feedback.id == "thread-inline")
}

@Test func inlineFeedbackLookupReturnsNilForUnmappedFeedback() {
    let match = ReviewEvidenceInlineFeedbackNavigator.match(
        evidenceItemID: "missing",
        inlineFeedbackByFileID: [:]
    )

    #expect(match == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ReviewEvidenceModelTests
```

Expected: FAIL because `ReviewEvidenceInlineFeedbackNavigator` does not exist.

- [ ] **Step 3: Add navigation helper to `ReviewEvidenceTabView.swift`**

At file scope in `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`, add:

```swift
enum ReviewEvidenceInlineFeedbackNavigator {
    struct Match: Equatable {
        let fileID: DiffReviewFileID
        let feedback: DiffReviewInlineFeedback
    }

    static func match(
        evidenceItemID: String,
        inlineFeedbackByFileID: [DiffReviewFileID: [DiffReviewInlineFeedback]]
    ) -> Match? {
        for (fileID, items) in inlineFeedbackByFileID {
            if let feedback = items.first(where: { $0.evidenceItemID == evidenceItemID }) {
                return Match(fileID: fileID, feedback: feedback)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Wire state in `ReviewEvidenceTabView`**

Add state:

```swift
@State private var focusedFeedbackID: String?
@State private var inlineFeedbackScrollController = DiffReviewInlineFeedbackScrollController()
@State private var inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand?
```

In `filesPane`, pass to `DiffReviewSurface`:

```swift
focusedFeedbackID: focusedFeedbackID,
inlineFeedbackScrollCommand: inlineFeedbackScrollCommand,
inlineFeedbackActions: inlineFeedbackActions(snapshot: model.snapshot),
onSelectInlineFeedback: { feedback in
    focusInlineFeedback(feedback, fileSession: model.fileSession)
}
```

Add helpers:

```swift
private func focusInlineFeedback(_ feedback: DiffReviewInlineFeedback, fileSession: DiffReviewLoadedSession?) {
    focusedFeedbackID = feedback.id
    if let itemID = Optional(feedback.evidenceItemID) {
        model?.select(itemID: itemID, section: .feedback)
        persistSelection(section: .feedback, itemID: itemID)
    }
}

private func navigateToInlineFeedback(for item: ReviewEvidenceItem, in model: ReviewEvidenceModel) -> Bool {
    guard let match = ReviewEvidenceInlineFeedbackNavigator.match(
        evidenceItemID: item.id,
        inlineFeedbackByFileID: model.inlineFeedbackByFileID
    ) else { return false }

    selectedSection = .files
    selectedFileID = match.fileID
    focusedFeedbackID = match.feedback.id
    inlineFeedbackScrollCommand = inlineFeedbackScrollController.command(
        feedbackID: match.feedback.id,
        fileID: match.fileID
    )
    model.select(itemID: item.id, section: .feedback)
    persistSelection(section: .files, itemID: item.id)
    return true
}
```

Update `selectItem`:

```swift
if item.section == .feedback, navigateToInlineFeedback(for: item, in: model) {
    if loadDetail {
        Task { await model.loadSelectedDetail() }
    }
    return
}
```

Keep the existing path for CI and unmapped Feedback items.

- [ ] **Step 5: Add inline action closures**

In `ReviewEvidenceTabView`, add:

```swift
private func inlineFeedbackActions(snapshot: ReviewLoopSnapshot) -> DiffReviewInlineFeedbackActions {
    DiffReviewInlineFeedbackActions(
        availability: { item, _ in
            DiffReviewInlineFeedbackActionAvailability(
                canOpenProvider: item.providerURL != nil,
                canCopyContext: true,
                canSendToAgent: canSendToAgent
            )
        },
        openProvider: { item, _ in
            if let url = item.providerURL {
                NSWorkspace.shared.open(url)
            }
        },
        copyContext: { item, file in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(DiffReviewInlineFeedbackContextFormatter.format(item: item, file: file), forType: .string)
        },
        sendToAgent: { item, file in
            let detail = ReviewEvidenceDetail(
                item: ReviewEvidenceItem(
                    id: item.evidenceItemID,
                    section: .feedback,
                    title: item.author.map { "\($0) feedback" } ?? "Review feedback",
                    subtitle: "\(file.path)\(item.anchor.line.map { ":\($0)" } ?? "")",
                    status: item.status,
                    providerURL: item.providerURL
                ),
                body: DiffReviewInlineFeedbackContextFormatter.format(item: item, file: file),
                filePath: file.path,
                line: item.anchor.line,
                isTruncated: false
            )
            appState.openReviewEvidenceHandoff(snapshot: snapshot, detail: detail)
        }
    )
}
```

Keep this helper as an instance method on `ReviewEvidenceTabView`; it runs on the main actor as part of the SwiftUI view. Do not introduce provider write actions.

- [ ] **Step 6: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ReviewEvidenceModelTests
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: PASS.

- [ ] **Step 7: Commit Task 3**

Run:

```bash
git add Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift AlasTests/Integrations/ReviewEvidenceModelTests.swift
git commit -m "feat(review): sync feedback selection with files"
```

---

### Task 4: Final Verification

**Files:**
- No intended source changes unless verification finds a bug.

- [ ] **Step 1: Run required project generation**

Run:

```bash
xcodegen
```

Expected: exits 0. If it changes `Alas.xcodeproj/project.pbxproj`, inspect and include only if the source file set changed.

- [ ] **Step 2: Run quiet build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exits 0.

- [ ] **Step 3: Run full tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exits 0. If a known unrelated LSP/zmx timing failure appears, rerun the exact failing suite once and report the result clearly.

- [ ] **Step 4: Launch for manual verification**

Run:

```bash
rtk open -n "$(find ~/Library/Developer/Xcode/DerivedData -path '*/Build/Products/Debug/Alas.app' -type d -print0 | xargs -0 stat -f '%m %N' | sort -nr | head -1 | cut -d' ' -f2-)"
```

Expected: the debug app launches. In a PR/MR details tab, selecting an inline Feedback row switches to Files and scrolls to the card; inline cards show Open/Copy/Send actions based on availability.
