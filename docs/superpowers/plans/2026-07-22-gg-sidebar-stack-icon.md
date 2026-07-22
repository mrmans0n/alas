# GG Sidebar Stack Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the accent-colored GG triangle badge in the left sidebar with a quieter three-stroke stack icon plus merged/total progress.

**Architecture:** Keep the marker owned by `WorktreeRowView`, preserving the existing `GGStackSummaryStore` lookup and metadata-row placement. Add a small colocated SwiftUI `Shape` for the decorative stack glyph, and expose the same stack summary string through help and accessibility label.

**Tech Stack:** Swift 5.9+, SwiftUI for macOS 15, Swift Testing, AppKit-hosted SwiftUI sizing tests.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Prefix shell commands with `rtk`.
- Do not add agent attribution to commits, PR bodies, docs, comments, or code.
- The glyph draws three equal, short horizontal strokes in a fixed 9-by-9-point frame.
- The glyph and count use the existing `fg-faint` theme token.
- The count retains the row's current 10.5-point monospaced text style.
- The glyph and count use 3 points of spacing.
- The marker has no background, border, capsule, hover treatment, command, or mutable state.
- The marker appears only when `GGStackSummaryStore` contains a summary for the worktree path.
- The combined marker exposes `gg stack · <merged> of <total> commit(s) merged` as both help text and accessibility label.
- Run `xcodegen`, `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`, and `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test` before completion.

---

## File Structure

- Modify `Alas/Sources/Sidebar/WorktreeRowView.swift`
  - Replace the current `Text("▲ merged/total")` marker with a compact `HStack(spacing: 3)`.
  - Add `GGSidebarStackShape`, a private SwiftUI `Shape` colocated with `WorktreeRowView`.
  - Add `static func stackSummaryAccessibilityLabel(merged:total:) -> String` and use it for `.accessibilityLabel(...)`.
- Modify `AlasTests/WorktreeRowHeightTests.swift`
  - Keep the existing tooltip terminology tests.
  - Add a test for the new accessibility-label helper.
  - Extend the hosted row-height helper so it can render rows with a real `GGStackSummary`.

### Task 1: Sidebar Stack Marker

**Files:**
- Modify: `Alas/Sources/Sidebar/WorktreeRowView.swift:4-6`
- Modify: `Alas/Sources/Sidebar/WorktreeRowView.swift:90-123`
- Modify: `Alas/Sources/Sidebar/WorktreeRowView.swift:191-197`
- Test: `AlasTests/WorktreeRowHeightTests.swift:9-90`

**Interfaces:**
- Consumes: `GGStackSummaryStore.shared.summaries[worktree.path.path] -> GGStackSummary?`, `GGStackSummary(merged: Int, total: Int)`, `theme.color("fg-faint")`, and the existing `WorktreeRowView.stackSummaryTooltip(merged:total:)`.
- Produces: `WorktreeRowView.stackSummaryAccessibilityLabel(merged: Int, total: Int) -> String`, `private struct GGSidebarStackShape: Shape`, and a marker `HStack(spacing: 3)` using `GGSidebarStackShape().frame(width: 9, height: 9)` plus `Text("\(stack.merged)/\(stack.total)")`.

- [ ] **Step 1: Write the failing accessibility-label test**

Append this test after `ggStackTooltipUsesCommitTerminology()` in `AlasTests/WorktreeRowHeightTests.swift`:

```swift
@Test func ggStackAccessibilityLabelMatchesTooltipTerminology() {
    #expect(WorktreeRowView.stackSummaryAccessibilityLabel(merged: 1, total: 1)
        == "gg stack · 1 of 1 commit merged")
    #expect(WorktreeRowView.stackSummaryAccessibilityLabel(merged: 2, total: 3)
        == "gg stack · 2 of 3 commits merged")
}
```

- [ ] **Step 2: Run the focused test and verify it fails for the missing API**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing AlasTests/WorktreeRowHeightTests test
```

Expected: FAIL at compile time because `WorktreeRowView.stackSummaryAccessibilityLabel(merged:total:)` does not exist.

- [ ] **Step 3: Add the hosted row-height regression for real GG stack summaries**

Change the two existing row-height tests and `renderHeight` helper in `AlasTests/WorktreeRowHeightTests.swift` to this complete block, preserving the existing imports, suite attributes, and callback closures:

```swift
@Test func rowHeightIsStableWithAndWithoutBadge() throws {
    let withoutBadge = try renderHeight(harnessSummary: nil)
    let withBadge = try renderHeight(harnessSummary: .init(
        state: .running,
        agent: .claude,
        primarySessionId: "s1",
        runningSessionCount: 1,
        awaitingSessionCount: 0
    ))

    #expect(withoutBadge == withBadge)
}

@Test func rowHeightIsStableAcrossBadgeStates() throws {
    let running = try renderHeight(harnessSummary: .init(
        state: .running,
        agent: .claude,
        primarySessionId: "s1",
        runningSessionCount: 1,
        awaitingSessionCount: 0
    ))
    let awaiting = try renderHeight(harnessSummary: .init(
        state: .awaiting,
        agent: .claude,
        primarySessionId: "s1",
        runningSessionCount: 0,
        awaitingSessionCount: 1
    ))

    #expect(running == awaiting)
}

@Test func rowHeightIsStableWithAndWithoutGGStackMarker() throws {
    let withoutStack = try renderHeight(harnessSummary: nil, stackSummary: nil)
    let withStack = try renderHeight(harnessSummary: nil, stackSummary: GGStackSummary(merged: 2, total: 3))

    #expect(withoutStack == withStack)
}

private func renderHeight(
    harnessSummary: HarnessService.WorktreeHarnessSummary?,
    stackSummary: GGStackSummary? = nil
) throws -> Int {
    let worktree = Worktree(
        id: "wt-1",
        projectId: "p1",
        name: "feature",
        branch: "feature/test",
        path: URL(fileURLWithPath: "/tmp/wt"),
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 0)
    )

    GGStackSummaryStore.shared.summaries.removeAll()
    if let stackSummary {
        GGStackSummaryStore.shared.summaries[worktree.path.path] = stackSummary
    }
    defer {
        GGStackSummaryStore.shared.summaries.removeAll()
    }

    let view = WorktreeRowView(
        worktree: worktree,
        isSelected: false,
        isMain: false,
        operationState: nil,
        harnessSummary: harnessSummary,
        onTap: {},
        onOpenTerminal: {},
        onCopyPath: {},
        onCopyBranch: {},
        onRevealInFinder: {},
        onArchive: {},
        onDelete: {},
        onDeleteKeepBranch: {},
        showKeepBranchOption: false,
        onActivateHarness: {},
        onCopyError: { _ in },
        onRemoveFailed: {},
        onRetryCreate: {},
        onRetryDelete: {}
    )
    .environment(\.theme, try ThemeStore().current)

    let controller = NSHostingController(rootView: view)
    controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
    controller.view.layoutSubtreeIfNeeded()

    let fittingSize = controller.sizeThatFits(in: NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude))
    return Int(fittingSize.height)
}
```

- [ ] **Step 4: Implement the minimal production change**

In `Alas/Sources/Sidebar/WorktreeRowView.swift`, change the top static helpers to:

```swift
static func stackSummaryTooltip(merged: Int, total: Int) -> String {
    stackSummaryText(merged: merged, total: total)
}

static func stackSummaryAccessibilityLabel(merged: Int, total: Int) -> String {
    stackSummaryText(merged: merged, total: total)
}

private static func stackSummaryText(merged: Int, total: Int) -> String {
    "gg stack · \(merged) of \(total) commit\(total == 1 ? "" : "s") merged"
}
```

Replace the current stack marker block:

```swift
if let stack = stackSummary {
    Text("▲ \(stack.merged)/\(stack.total)")
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundColor(theme.color("accent"))
        .help(Self.stackSummaryTooltip(merged: stack.merged, total: stack.total))
}
```

with:

```swift
if let stack = stackSummary {
    let summaryText = Self.stackSummaryTooltip(merged: stack.merged, total: stack.total)
    HStack(spacing: 3) {
        GGSidebarStackShape()
            .fill(theme.color("fg-faint"))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
        Text("\(stack.merged)/\(stack.total)")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(theme.color("fg-faint"))
    }
    .help(summaryText)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.stackSummaryAccessibilityLabel(merged: stack.merged, total: stack.total))
}
```

Add this private shape below `WorktreeRowView` and above the `String` extension:

```swift
private struct GGSidebarStackShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let strokeHeight = min(rect.height / 9, 1)
        let strokeWidth = min(rect.width, 7)
        let x = rect.midX - strokeWidth / 2
        let yPositions = [
            rect.minY + 1,
            rect.midY - strokeHeight / 2,
            rect.maxY - strokeHeight - 1
        ]

        for y in yPositions {
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: strokeWidth, height: strokeHeight),
                cornerSize: CGSize(width: strokeHeight / 2, height: strokeHeight / 2)
            )
        }

        return path
    }
}
```

- [ ] **Step 5: Run focused verification and verify green**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing AlasTests/WorktreeRowHeightTests test
```

Expected: PASS for `WorktreeRowHeightTests`.

- [ ] **Step 6: Run required repository verification**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: all commands exit 0.

- [ ] **Step 7: Commit the implementation**

Run:

```bash
rtk git status --short
rtk git add Alas/Sources/Sidebar/WorktreeRowView.swift AlasTests/WorktreeRowHeightTests.swift
rtk git commit -m "refactor: quiet GG sidebar stack marker"
```

Expected: commit contains only the sidebar view and its focused tests.
