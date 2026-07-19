# Wrapped Diff Scroll Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop stable-width wrapped diff scrolling from repeatedly reconfiguring TextKit, relaying out unchanged diff documents, and scanning offscreen rows during custom drawing.

**Architecture:** Keep the shared TextKit 1 renderer and its existing SwiftUI/AppKit boundaries. Add an effective-width configuration cache inside `DiffPaneTextScrollView`, make identical container updates skip layout, and reuse ordered row geometry to derive dirty row ranges in logarithmic time.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit TextKit 1 (`NSTextView`, `NSLayoutManager`, `NSTextContainer`), Swift Testing (`import Testing`), XcodeGen.

---

## Source Design

`docs/superpowers/specs/2026-07-19-wrapped-diff-scroll-performance-design.md`

## File Structure

- Modify `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`
  - Own the stable text-layout configuration and its application counter in
    `DiffPaneTextScrollView`.
  - Keep identical document-container updates from scheduling layout.
  - Add ordered-row dirty-range lookup and use it for custom backgrounds.
- Modify `AlasTests/DiffPaneViewTests.swift`
  - Add real AppKit regression tests beside the existing wrapping, split-row,
    and geometry-cache tests.

No new source file or `project.yml` entry is required. Do not modify host views:
all single-file, commit, and multi-file review surfaces already use this shared
renderer.

## Shared Rules

- Use test-driven development. Add one failing behavior test, run it and verify
  the expected failure, then add only the implementation required to pass it.
- Prefix shell commands with `rtk`.
- Preserve exact wrapping, selection, gutters, LSP behavior, context expansion,
  comments, highlights, and split-row alignment.
- Keep the split-height live-lock protections in `synchronizeRowHeights` intact.
- Counters are internal test accessors only; do not log or persist metrics.
- Do not add agent attribution to code, docs, commits, or PR text.
- Commit after each task.

### Task 1: Cache Effective TextKit Layout Configuration

**Files:**
- Modify: `AlasTests/DiffPaneViewTests.swift` near the existing
  `wrappedDiffTextScrollPaneDoesNotAllowHorizontalOffset` and
  `diffPaneCodeTextViewCachesMeasuredRowGeometry` tests
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift:603-992`

- [ ] **Step 1: Add a test helper for a wrapped text scroll view**

Add this private helper to `DiffPaneViewTests` near the other renderer helpers.
It avoids duplicating document construction in the new tests:

```swift
private func makeTextScrollView(
    width: CGFloat = 220,
    wraps: Bool = true
) throws -> DiffPaneTextScrollView {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let lines = [
        "let first = \"This line is intentionally long enough to wrap across several visual fragments.\"",
        "let second = \"This line is also long enough to exercise stable wrapped layout.\"",
    ]
    let text = lines.joined(separator: "\n")
    var location = 0
    let metadata = lines.map { line in
        defer { location += (line as NSString).length + 1 }
        return DiffPaneTextDocumentBuilder.LineMetadata(
            kind: .context,
            range: NSRange(location: location, length: (line as NSString).length)
        )
    }
    let document = DiffPaneTextDocumentBuilder.CodeDocument(
        attributedString: NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: CenterTypography.paragraphStyle(),
            ]
        ),
        lines: metadata
    )
    let scrollView = DiffPaneTextScrollView(
        frame: NSRect(x: 0, y: 0, width: width, height: 180)
    )
    scrollView.update(
        document: document,
        lineLabels: ["1", "2"],
        wraps: wraps,
        font: font,
        theme: theme(),
        lspContext: nil,
        allowedLSPSide: .new
    )
    return scrollView
}
```

- [ ] **Step 2: Add failing stable-layout and wrap-transition tests**

```swift
@Test func wrappedTextLayoutConfigurationIsNotReappliedAtStableWidth() throws {
    let scrollView = try makeTextScrollView()
    scrollView.layoutSubtreeIfNeeded()
    let initialApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
    let initialScrollerChanges = scrollView.horizontalScrollerVisibilityChangeCountForTesting
    #expect(initialApplications == 1)

    for _ in 0..<5 {
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
    }

    #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == initialApplications)
    #expect(scrollView.horizontalScrollerVisibilityChangeCountForTesting == initialScrollerChanges)
}

@Test func togglingTextWrapAppliesConfigurationAndPreservesScrollerState() throws {
    let scrollView = try makeTextScrollView(wraps: true)
    scrollView.layoutSubtreeIfNeeded()
    let wrappedApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
    let wrappedScrollerChanges = scrollView.horizontalScrollerVisibilityChangeCountForTesting
    #expect(!scrollView.hasHorizontalScroller)

    let replacement = try makeTextScrollView(wraps: false)
    let replacementView = try #require(replacement.documentView as? DiffPaneCodeTextView)
    let storage = try #require(replacementView.textStorage)
    scrollView.update(
        document: .init(
            attributedString: storage,
            lines: replacementView.lineMetadata
        ),
        lineLabels: ["1", "2"],
        wraps: false,
        font: .monospacedSystemFont(ofSize: 13, weight: .regular),
        theme: theme(),
        lspContext: nil,
        allowedLSPSide: .new
    )
    scrollView.layoutSubtreeIfNeeded()

    #expect(scrollView.hasHorizontalScroller)
    #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == wrappedApplications + 1)
    #expect(scrollView.horizontalScrollerVisibilityChangeCountForTesting == wrappedScrollerChanges + 1)
}
```

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffPaneViewTests/wrappedTextLayoutConfigurationIsNotReappliedAtStableWidth \
  -only-testing:AlasTests/DiffPaneViewTests/togglingTextWrapAppliesConfigurationAndPreservesScrollerState test
```

Expected: FAIL to compile because
`textLayoutConfigurationApplicationCountForTesting` does not exist.

- [ ] **Step 4: Implement the minimal effective-configuration cache**

In `DiffPaneTextScrollView`, add a compact private configuration value with
exact equality for this first cycle, plus an internal read-only counter:

```swift
private struct TextLayoutConfiguration: Equatable {
    let wraps: Bool
    let contentWidth: CGFloat
}

private var appliedTextLayoutConfiguration: TextLayoutConfiguration?
private(set) var textLayoutConfigurationApplicationCountForTesting = 0
private(set) var horizontalScrollerVisibilityChangeCountForTesting = 0
```

Replace `configureTextContainer()` with an idempotent method. Use exact
configuration equality in this first implementation step; width tolerance is a
separate failing test and implementation below:

```swift
@discardableResult
private func applyTextLayoutConfigurationIfNeeded() -> Bool {
    let contentWidth = max(
        contentView.bounds.width - textView.textContainerInset.width * 2,
        1
    )
    let desired = TextLayoutConfiguration(wraps: wraps, contentWidth: contentWidth)
    if desired == appliedTextLayoutConfiguration {
        return false
    }

    appliedTextLayoutConfiguration = desired
    textLayoutConfigurationApplicationCountForTesting += 1
    let containerWidth = wraps ? contentWidth : Self.unwrappedTextContainerWidth

    textView.isHorizontallyResizable = !wraps
    textView.minSize = .zero
    textView.maxSize = NSSize(
        width: containerWidth,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = wraps
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
        width: containerWidth,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.invalidateDiffRowGeometry()
    return true
}
```

Call `applyTextLayoutConfigurationIfNeeded()` after tiling has established the
content width. Remove the wrapped-only configuration call from `tile()` so one
layout pass does not apply configuration from two call sites.

Replace direct horizontal-scroller assignments with an idempotent helper called
from `update(document:...)`:

```swift
private func applyHorizontalScrollerVisibilityIfNeeded() {
    let desired = !wraps
    guard hasHorizontalScroller != desired else { return }
    hasHorizontalScroller = desired
    horizontalScrollerVisibilityChangeCountForTesting += 1
}
```

Remove `hasHorizontalScroller = !wraps` from `layout()`. The stable-layout and
wrap-transition tests now prove that scroller state changes once per actual
transition and is not reassigned by layout.

Do not reset `appliedTextLayoutConfiguration` on every document update: setting
the attributed string already invalidates document layout, while the cached
value represents only width and wrapping. A wrap-mode or effective-width change
will fail the comparison naturally.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run the command from Step 3.

Expected: PASS with exactly one configuration application across repeated
stable-width layout passes and one additional application for the wrap-mode
transition.

- [ ] **Step 6: Add a failing width-tolerance test and geometry regressions**

```swift
@Test func wrappedTextLayoutConfigurationTracksLastAppliedWidth() throws {
    let scrollView = try makeTextScrollView(width: 220)
    scrollView.layoutSubtreeIfNeeded()
    let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
    _ = codeView.diffRowRects()
    let initialApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
    let initialGeometryComputations = codeView.rowGeometryComputationCountForTesting

    scrollView.setFrameSize(NSSize(width: 220.3, height: 180))
    scrollView.layoutSubtreeIfNeeded()
    #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == initialApplications)
    _ = codeView.diffRowRects()
    #expect(codeView.rowGeometryComputationCountForTesting == initialGeometryComputations)

    scrollView.setFrameSize(NSSize(width: 220.6, height: 180))
    scrollView.layoutSubtreeIfNeeded()
    #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == initialApplications + 1)
    _ = codeView.diffRowRects()
    #expect(codeView.rowGeometryComputationCountForTesting == initialGeometryComputations + 1)
}

@Test func wrappedTextHeightOnlyResizeKeepsWidthDependentGeometry() throws {
    let scrollView = try makeTextScrollView(width: 220)
    scrollView.layoutSubtreeIfNeeded()
    let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
    _ = codeView.diffRowRects()
    let initialApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
    let initialGeometryComputations = codeView.rowGeometryComputationCountForTesting

    scrollView.setFrameSize(NSSize(width: 220, height: 260))
    scrollView.layoutSubtreeIfNeeded()
    _ = codeView.diffRowRects()

    #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == initialApplications)
    #expect(codeView.rowGeometryComputationCountForTesting == initialGeometryComputations)
}
```

- [ ] **Step 7: Run the new tests and verify RED, then make the minimal fixes**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffPaneViewTests/wrappedTextLayoutConfigurationTracksLastAppliedWidth \
  -only-testing:AlasTests/DiffPaneViewTests/wrappedTextHeightOnlyResizeKeepsWidthDependentGeometry test
```

Expected before the minimal fixes: the width-tolerance test FAILS because the
exact-equality implementation applies the 0.3-point width change.

Replace exact equality with a `matches` method using the 0.5-point tolerance
from the design. Compare against `appliedTextLayoutConfiguration`, which stores
the last width actually applied, so the cumulative move from 220 to 220.6
eventually reconfigures.

Remove `.width` from `textView.autoresizingMask`; `DiffPaneTextScrollView.layout`
must be the sole owner of document-view width. Use this explicit order in the
layout pass:

1. Call `super.layout()` and tile the ruler/content view.
2. Derive the desired `TextLayoutConfiguration` without mutating TextKit.
3. If the configuration meaningfully changed and wrapping is enabled, update
   the text view to the desired content-view width while retaining its current
   height. This invalidates row geometry before it is read.
4. Apply the text-container configuration if needed. A second cache
   invalidation here is harmless because geometry has not yet been computed.
5. Read `documentHeight`, which computes exact row geometry once for the new
   width/container configuration.
6. Set the final text-view frame. In wrapped mode its width already matches, so
   this is a height-only change and `DiffPaneCodeTextView.setFrameSize` does not
   invalidate width-dependent geometry. In unwrapped mode, preserve the
   existing measured-text-width behavior; the fixed million-point container
   width means document-view frame width does not change line fragmentation.

Factor configuration derivation out of the applying method so Steps 2 and 3 do
not require mutating `appliedTextLayoutConfiguration` early:

```swift
let desiredConfiguration = textLayoutConfiguration()
let configurationChanged = !desiredConfiguration.matches(appliedTextLayoutConfiguration)
if configurationChanged, desiredConfiguration.wraps {
    setTextViewWidthIfNeeded(max(contentView.bounds.width, 1))
}
applyTextLayoutConfigurationIfNeeded(desiredConfiguration)
let desiredFrame = NSRect(
    x: 0,
    y: 0,
    width: textViewWidth(),
    height: documentHeight
)
setTextViewFrameIfNeeded(desiredFrame)
```

The optional-aware `matches` helper should return false when there is no applied
configuration. Frame helpers use the same 0.5-point tolerance. Do not invalidate
row geometry after `documentHeight` for the same meaningful wrapped-width
transition. Re-run both tests until PASS; the `+1` geometry assertion verifies
this ordering.

- [ ] **Step 8: Run the renderer test suite**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffPaneViewTests test
```

Expected: PASS, including existing wrapped continuation, gutter, horizontal
origin, and split synchronization regressions.

- [ ] **Step 9: Commit Task 1**

```bash
rtk git add Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift AlasTests/DiffPaneViewTests.swift
rtk git commit -m "perf(diff): cache wrapped text layout configuration"
```

### Task 2: Make Identical Container Updates True Layout No-Ops

**Files:**
- Modify: `AlasTests/DiffPaneViewTests.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift:240-395`
  and `:450-565`

- [ ] **Step 1: Add a failing identical-update regression test**

Use the direct container API so the test isolates AppKit invalidation from
SwiftUI scheduling:

```swift
@Test func identicalDiffDocumentContainerUpdateDoesNotRequestLayout() throws {
    let group = try #require(model().groups.first)
    let container = DiffPaneTextDocumentContainerView(
        frame: NSRect(x: 0, y: 0, width: 700, height: 300)
    )

    func update() {
        container.update(
            group: group,
            expandedCollapsedRowIDs: [],
            layoutMode: .stacked,
            wrapLines: true,
            showWhitespace: false,
            fileExtension: "swift",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            theme: theme(),
            lspContext: nil
        )
    }

    update()
    container.layoutSubtreeIfNeeded()
    #expect(!container.needsLayout)

    let codeView = try #require(allSubviews(of: container)
        .compactMap { $0 as? DiffPaneCodeTextView }
        .first(where: isEffectivelyVisible))
    _ = codeView.diffRowRects()
    let geometryComputations = codeView.rowGeometryComputationCountForTesting

    update()

    #expect(!container.needsLayout)
    container.layoutSubtreeIfNeeded()
    #expect(codeView.rowGeometryComputationCountForTesting == geometryComputations)
}
```

- [ ] **Step 2: Run the test and verify RED**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffPaneViewTests/identicalDiffDocumentContainerUpdateDoesNotRequestLayout test
```

Expected: FAIL at `#expect(!container.needsLayout)` after the second update,
because the identical-signature branch currently sets `needsLayout = true`.

- [ ] **Step 3: Remove redundant layout requests from both update paths**

In both `update(group:...)` and `update(rows:...)`, retain callback,
selection-availability, context-expansion, and active-highlight assignments
before signature comparison. Replace:

```swift
guard signature != lastUpdateSignature else {
    needsLayout = true
    return
}
```

with:

```swift
guard signature != lastUpdateSignature else { return }
```

Apply the same change to `lastRowsUpdateSignature`. Do not move live callback or
highlight assignments behind the guard. Those properties already invalidate
display where needed and must remain current without rebuilding the document.

- [ ] **Step 4: Run the focused test and renderer suite**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffPaneViewTests/identicalDiffDocumentContainerUpdateDoesNotRequestLayout test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffPaneViewTests test
```

Expected: PASS.

- [ ] **Step 5: Commit Task 2**

```bash
rtk git add Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift AlasTests/DiffPaneViewTests.swift
rtk git commit -m "perf(diff): skip unchanged document layout"
```

### Task 3: Bound Custom Drawing To Dirty Rows

**Files:**
- Modify: `AlasTests/DiffPaneViewTests.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift:1600-1650`
  and the ordered `Array<NSRect>` helpers near the end of the file

- [ ] **Step 1: Add failing row-range lookup tests**

```swift
@Test func diffRowRectsReturnOnlyIndicesIntersectingDirtyVerticalRange() {
    let rows = [
        NSRect(x: 0, y: 0, width: 100, height: 10),
        NSRect(x: 0, y: 10, width: 100, height: 10),
        NSRect(x: 0, y: 20, width: 100, height: 10),
        NSRect(x: 0, y: 30, width: 100, height: 10),
    ]

    #expect(rows.indicesIntersecting(NSRect(x: 0, y: 10, width: 100, height: 10)) == 1..<2)
    #expect(rows.indicesIntersecting(NSRect(x: 0, y: 9, width: 100, height: 12)) == 0..<3)
    #expect(rows.indicesIntersecting(NSRect(x: 0, y: 40, width: 100, height: 10)).isEmpty)
    #expect([NSRect]().indicesIntersecting(.zero).isEmpty)
}
```

The first assertion locks the current `NSRect.intersects` boundary semantics:
rows that merely touch the dirty rectangle at an edge are excluded.

- [ ] **Step 2: Run the test and verify RED**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffPaneViewTests/diffRowRectsReturnOnlyIndicesIntersectingDirtyVerticalRange test
```

Expected: FAIL to compile because `indicesIntersecting` does not exist.

- [ ] **Step 3: Implement ordered dirty-range lookup**

Add an internal helper alongside `binarySearchRow(containing:)`:

```swift
func indicesIntersecting(_ rect: NSRect) -> Range<Int> {
    guard !isEmpty, rect.height > 0 else { return 0..<0 }

    let start = lowerBound { $0.maxY > rect.minY }
    let end = lowerBound { $0.minY >= rect.maxY }
    guard start < end else { return 0..<0 }
    return start..<end
}

private func lowerBound(where predicate: (NSRect) -> Bool) -> Int {
    var low = 0
    var high = count
    while low < high {
        let mid = low + (high - low) / 2
        if predicate(self[mid]) {
            high = mid
        } else {
            low = mid + 1
        }
    }
    return low
}
```

The helper assumes the existing invariant that row rectangles are ordered and
non-overlapping vertically.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the command from Step 2. Expected: PASS.

- [ ] **Step 5: Use the range in text background drawing**

Change `DiffPaneCodeTextView.drawLineBackgrounds(in:)` from enumerating every
row and checking `rowRect.intersects(dirtyRect)` to:

```swift
let rowRects = diffRowRects()
for index in rowRects.indicesIntersecting(dirtyRect) {
    guard lineTones.indices.contains(index) else { continue }
    let rowRect = rowRects[index]
    let tone = lineTones[index]
    guard tone != .context else { continue }
    // Keep the existing fill, hatch, and expansion-pill drawing unchanged.
}
```

Keep active-comment-highlight drawing after the loop. Do not add a second
geometry cache or outer SwiftUI scroll observer.

- [ ] **Step 6: Run focused and full diff renderer tests**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffPaneViewTests test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/DiffReviewSurfaceTests \
  -only-testing:AlasTests/DiffSelectableTextTests \
  -only-testing:AlasTests/CommitTabViewTests \
  -only-testing:AlasTests/ReviewChangesTabViewTests test
```

Expected: PASS.

- [ ] **Step 7: Commit Task 3**

```bash
rtk git add Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift AlasTests/DiffPaneViewTests.swift
rtk git commit -m "perf(diff): bound custom drawing to dirty rows"
```

### Task 4: Required Verification And Manual Profiling

**Files:**
- No planned source changes
- Modify tests or production only if verification exposes a regression, using a
  new failing test before the fix

- [ ] **Step 1: Regenerate the Xcode project**

```bash
rtk xcodegen
```

Expected: success. Because `project.yml` is unchanged, `Alas.xcodeproj` should
not acquire a semantic diff. Inspect and do not commit unrelated generated
churn.

- [ ] **Step 2: Build the macOS app**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0 with no new warnings from the modified files.

- [ ] **Step 3: Run the complete test suite**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: all tests PASS.

- [ ] **Step 4: Inspect the final diff**

```bash
rtk git status --short
rtk git diff --check
rtk git diff --stat HEAD~3..HEAD
```

Expected: clean whitespace check; only the shared renderer and its tests changed
across implementation commits. Preserve the already-committed spec and plan.

- [ ] **Step 5: Manually profile representative wrapped panes**

Open a large single-file diff, commit diff, and multi-file review diff. For each,
scroll in both split and stacked layouts with wrapping enabled. Confirm:

- stable-width scrolling does not increase the configuration-application or
  row-geometry counters after initial layout/materialization
- wrapped continuation text remains visible and gutters align
- split old/new logical rows remain aligned
- selection, comments, highlights, expansion controls, and LSP hover/click
  behavior remain intact
- toggling wrapping and resizing recompute exact heights without scroll jumps

If Instruments is available, compare main-thread layout samples before and
after. The acceptance criterion is elimination of repeated stable-width TextKit
configuration/layout work, not a specific machine-dependent frame-time number.

- [ ] **Step 6: Commit any verification-only test adjustment**

Only if Step 3 or Step 5 required a test-first correction:

```bash
rtk git add Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift AlasTests/DiffPaneViewTests.swift
rtk git commit -m "test(diff): cover wrapped layout regression"
```
