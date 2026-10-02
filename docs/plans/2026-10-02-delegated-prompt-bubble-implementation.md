# Delegated Prompt Bubble Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render delegated prompts as a left-aligned neutral-slate chat bubble that folds long prompts and keeps markdown headings at body size.

**Architecture:** All changes stay in `DelegatedPromptRow`. A `nonisolated` static function makes the fold decision and gets one parameterized test. The row keeps its open/closed flag in local `@State`, the same way `ACPThoughtView` does. `ACPChatTypography` gains one flag that flattens heading sizes, and only this row sets it.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI on macOS, Swift Testing, XcodeGen.

Spec: `docs/plans/2026-10-02-delegated-prompt-bubble-design.md`.

## Global Constraints

- Code, comments, and UI strings in English.
- Tests use Swift Testing (`import Testing`), not XCTest. Don't add `@MainActor` or `.serialized` to the new suite.
- Adding a file under `AlasTests/` means running `xcodegen` and committing `Alas.xcodeproj/project.pbxproj` along with it.
- Commit titles follow Conventional Commits. No agent attribution trailers or footers.
- Fold thresholds: more than 12 lines or more than 900 characters, measured on the raw text with surrounding whitespace trimmed.
- Folded height is 8 lines of the paragraph font. Bubble width is at most `contentMaxWidth * 0.84`.
- Bubble fill is a `bg-3` → `bg-2` vertical gradient with a 0.5pt `bg-5` stroke. The corner radius is 12, except bottom-leading, which is 4.

---

### Task 1: Fold decision

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift` (`DelegatedPromptRow`, currently lines 179–216)
- Create: `AlasTests/ACP/UI/DelegatedPromptRowTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` (regenerated)

**Interfaces:**
- Produces: `nonisolated static func DelegatedPromptRow.foldedLineCount(for text: String) -> Int?`. It returns the raw line count when the prompt should fold and `nil` when it shouldn't.

- [ ] **Step 1: Write the failing test**

Create `AlasTests/ACP/UI/DelegatedPromptRowTests.swift`:

```swift
import Testing
@testable import Alas

@Suite("Delegated prompt folding")
struct DelegatedPromptRowTests {
    @Test("long prompts fold and report their raw line count", arguments: [
        ("Implement the linked issue.", nil),
        ("\n\n  short  \n\n", nil),
        (Array(repeating: "line", count: 12).joined(separator: "\n"), nil),
        (Array(repeating: "line", count: 13).joined(separator: "\n"), 13),
        (Array(repeating: "line", count: 13).joined(separator: "\r\n"), 13),
        (String(repeating: "a", count: 900), nil),
        (String(repeating: "a", count: 901), 1)
    ] as [(String, Int?)])
    func foldedLineCount(text: String, expected: Int?) {
        #expect(DelegatedPromptRow.foldedLineCount(for: text) == expected)
    }
}
```

- [ ] **Step 2: Regenerate the project and run the test to verify it fails**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/DelegatedPromptRowTests test
```

Expected: the build fails with `type 'DelegatedPromptRow' has no member 'foldedLineCount'`.

- [ ] **Step 3: Add the fold decision**

In `Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift`, add this inside `struct DelegatedPromptRow`, just below `@Environment(\.theme) private var theme`:

```swift
    nonisolated static let foldLineThreshold = 12
    nonisolated static let foldCharacterThreshold = 900

    /// The raw line count when `text` is long enough to fold, else nil.
    /// Decided from the text alone: measuring the rendered height would
    /// write state from a geometry callback, which live-locks the transcript.
    nonisolated static func foldedLineCount(for text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        guard lineCount > foldLineThreshold || trimmed.count > foldCharacterThreshold else { return nil }
        return lineCount
    }
```

`\.isNewline` treats `"\r\n"` (a single `Character`) as one separator. The `\r\n` test case covers that.

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/DelegatedPromptRowTests test
```

Expected: PASS. Check that the log says `Test run with 7 tests in 1 suite`. A wrong suite name skips everything silently.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift AlasTests/ACP/UI/DelegatedPromptRowTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): decide when a delegated prompt folds"
```

---

### Task 2: Incoming bubble, folding UI, flat headings

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPChatTypography.swift:4-32`
- Modify: `Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift` (`DelegatedPromptRow`)
- Modify: `Alas/Sources/ACP/UI/ACPTranscriptRowContent.swift:191-196` (call site)

**Interfaces:**
- Consumes: `DelegatedPromptRow.foldedLineCount(for:)` from Task 1.
- Produces: `ACPChatTypography.flatteningHeadings() -> ACPChatTypography`, and a new `contentMaxWidth: CGFloat` stored property on `DelegatedPromptRow`, which sits between `isFromChild` and `typography` in the memberwise init.

- [ ] **Step 1: Add the heading flag to `ACPChatTypography`**

In `Alas/Sources/ACP/UI/ACPChatTypography.swift`, add this after `let baseSize: CGFloat`:

```swift
    /// Renders every heading at paragraph size (still bold), for markdown
    /// inside a prompt bubble, where `##` should not outrank the body.
    private(set) var flattensHeadings = false
```

Add this after the `init`:

```swift
    func flatteningHeadings() -> ACPChatTypography {
        var copy = self
        copy.flattensHeadings = true
        return copy
    }
```

Change `headingSize(level:)` to:

```swift
    func headingSize(level: Int) -> CGFloat {
        if flattensHeadings { return paragraphSize }
        switch level {
        case 1: return baseSize + 6
        case 2: return baseSize + 4
        case 3: return baseSize + 2
        default: return baseSize + 1
        }
    }
```

The synthesized `Equatable` picks up the new stored property, so row equality and markdown caches still notice when typography changes. `headingSize` has one caller, `ACPMarkdownInlineRenderer.fontSize(typography:role:)`.

- [ ] **Step 2: Replace the `DelegatedPromptRow` view**

In `Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift`, replace the doc comment, the stored properties, and `body` of `DelegatedPromptRow`. Keep the Task 1 statics exactly as they are. The struct becomes:

```swift
/// A prompt Alas delivered on another session's behalf: a child's report to
/// its parent, or a parent's (or mission's) prompt to a child. Nobody typed
/// it here, so it renders as an incoming bubble (the user bubble mirrored to
/// the left, in neutral slate) with the sender captioned above it. Long
/// prompts fold to a few lines until expanded.
struct DelegatedPromptRow: View {
    let text: String
    let label: String
    let isFromChild: Bool
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    /// Local like `ACPThoughtView.expanded`: a rebuilt row folds again.
    @State private var isExpanded = false
    @Environment(\.theme) private var theme

    nonisolated static let foldLineThreshold = 12
    nonisolated static let foldCharacterThreshold = 900
    private static let foldedVisibleLines: CGFloat = 8

    /// The raw line count when `text` is long enough to fold, else nil.
    /// Decided from the text alone: measuring the rendered height would
    /// write state from a geometry callback, which live-locks the transcript.
    nonisolated static func foldedLineCount(for text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        guard lineCount > foldLineThreshold || trimmed.count > foldCharacterThreshold else { return nil }
        return lineCount
    }

    var body: some View {
        let foldedLineCount = Self.foldedLineCount(for: text)
        let isFolded = foldedLineCount != nil && !isExpanded
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: isFromChild ? "arrow.turn.down.left" : "arrow.turn.down.right")
                        .font(.system(size: 11))
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.color("fg-faint"))
                .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 6) {
                    ACPMarkdownText(raw: text, typography: typography.flatteningHeadings())
                        .frame(maxHeight: isFolded ? foldedHeight : nil, alignment: .top)
                        .clipped()
                        .contentShape(Rectangle())
                        .mask(foldMask(isFolded: isFolded))
                    if let foldedLineCount {
                        foldToggle(lineCount: foldedLineCount)
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
                .background(
                    LinearGradient(
                        colors: [theme.color("bg-3"), theme.color("bg-2")],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(bubbleShape)
                .overlay(bubbleShape.strokeBorder(theme.color("bg-5"), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            }
            .frame(maxWidth: contentMaxWidth * 0.84, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The user bubble's shape mirrored: the tail corner is bottom-leading.
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 12, bottomLeading: 4, bottomTrailing: 12, topTrailing: 12)
        )
    }

    private var foldedHeight: CGFloat {
        let font = typography.appKitFont(size: typography.paragraphSize)
        return ceil((font.ascender - font.descender + font.leading) * Self.foldedVisibleLines)
    }

    /// Fades the last lines of a folded prompt; fully opaque otherwise.
    private func foldMask(isFolded: Bool) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: isFolded ? 0.6 : 1),
                .init(color: isFolded ? .clear : .black, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    private func foldToggle(lineCount: Int) -> some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(isExpanded ? "Collapse" : "Show full prompt · \(lineCount) lines")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(theme.color("fg-dim"))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

`.contentShape(Rectangle())` on the clipped markdown keeps the hidden overflow from taking clicks meant for the toggle below it. `ACPSideQuestionCard` folds its content with the same frame-and-`.clipped()` pattern.

- [ ] **Step 3: Pass `contentMaxWidth` at the call site**

In `Alas/Sources/ACP/UI/ACPTranscriptRowContent.swift`, change the `DelegatedPromptRow(` call (around line 191) to:

```swift
                    DelegatedPromptRow(
                        text: text,
                        label: delegatedLabel
                            ?? ACPDelegatedPromptSource.transcriptLabel(for: delegatedSource, agentDisplayName: { $0 }),
                        isFromChild: delegatedSource.isFromChild,
                        contentMaxWidth: contentMaxWidth,
                        typography: typography
                    )
```

- [ ] **Step 4: Check for other callers, then build**

```bash
grep -rn "DelegatedPromptRow(" Alas AlasTests
```

Expected: only the call site from Step 3. If there are others, pass `contentMaxWidth` there too.

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation -quiet build
```

Expected: the build succeeds with no new warnings in the three touched files.

- [ ] **Step 5: Re-run the fold test**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/DelegatedPromptRowTests test
```

Expected: PASS, `Test run with 7 tests in 1 suite`.

- [ ] **Step 6: Check it in the running app**

Launch the built app. Open a child session whose first prompt was delegated (one started with `alas session new` or the `session_new` MCP tool, with an issue-sized prompt). Check that:
- the prompt is a left-aligned slate bubble with its small corner at the bottom-left, and the caption sits above it;
- it is folded to about 8 lines with a fade, and the toggle reads "Show full prompt · N lines";
- clicking the toggle expands it in place, the transcript re-tiles without jumping or beachballing, and "Collapse" folds it again;
- `## Issue context` renders bold at body size;
- a short child report (in the parent session) shows no toggle;
- after switching to the Light theme, the bubble is still readable.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPChatTypography.swift Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift Alas/Sources/ACP/UI/ACPTranscriptRowContent.swift
git commit -m "feat(acp): render delegated prompts as a folding incoming bubble"
```
