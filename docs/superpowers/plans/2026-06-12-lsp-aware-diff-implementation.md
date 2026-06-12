# LSP-Aware Diff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add hover/type information and Cmd-click go-to-definition to the current/new side of Alas diff panes.

**Architecture:** Add a read-only diff LSP layer that maps rendered new-side diff rows back to real worktree file positions, then routes hover and definition requests through `WorkspaceLSPManager`. Keep diff panes non-editable and do not add completion, diagnostics, or old-side intelligence.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit `NSTextView`, Swift Testing, Alas `WorkspaceLSPManager` and existing LSP message types.

---

## File Structure

- Create `Alas/Sources/Center/Diff/DiffPaneLSP.swift`
  - Owns `DiffPaneLSPContext`, `DiffPaneLSPLineMap`, `DiffPaneLSPController`, and the read-only document retain helper.
- Modify `Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift`
  - Add source-line metadata to `LineMetadata`.
- Modify `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`
  - Store line metadata in `DiffPaneCodeTextView`, add mouse/keyboard hooks, and attach/update the LSP controller.
- Modify `Alas/Sources/Center/Diff/DiffPaneView.swift`
  - Accept optional `lspContext` and pass it to hunk document views.
- Modify `Alas/Sources/Center/DiffTabView.swift`
  - Build `DiffPaneLSPContext` for single-file working tree/staged diff tabs.
- Modify `Alas/Sources/Center/CenterPaneView.swift`
  - Pass `worktree.id` into `DiffTabView`.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
  - Accept an optional LSP context factory and pass it to each file section.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
  - Pass per-file LSP context into `DiffPaneView`.
- Modify `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
  - Supply LSP contexts for the review changes surface.
- Modify `Alas/Sources/Center/Commit/CommitTabView.swift`
  - Supply LSP contexts for commit review, using the current worktree file where it still exists.
- Modify tests:
  - `AlasTests/DiffPaneViewTests.swift`
  - `AlasTests/DiffReviewSurfaceTests.swift`
  - Create `AlasTests/DiffPaneLSPTests.swift`
- Modify `docs/manual-test.md`
  - Update the diff pane LSP manual test.

---

### Task 1: Source Metadata And Pure Line Mapping

**Files:**
- Create: `AlasTests/DiffPaneLSPTests.swift`
- Create: `Alas/Sources/Center/Diff/DiffPaneLSP.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift`

- [ ] **Step 1: Write failing mapper tests**

Create `AlasTests/DiffPaneLSPTests.swift`:

```swift
import Foundation
import Testing

@Suite("DiffPaneLSPLineMap")
struct DiffPaneLSPLineMapTests {
    @Test func mapsNewLineCharacterToRealFilePosition() {
        let line = DiffDisplayLine(
            id: "file:new:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 42),
            text: "let value = service.fetch()",
            lineNumber: 42,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .add,
                range: NSRange(location: 0, length: 27),
                tone: .add,
                sourceLine: line
            )
        ]

        let result = DiffPaneLSPLineMap.position(
            at: 11,
            metadata: metadata,
            allowedSide: .new
        )

        #expect(result == LSPPosition(line: 41, character: 11))
    }

    @Test func rejectsOldSideLine() {
        let line = DiffDisplayLine(
            id: "file:old:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .old, oldLine: 41, newLine: nil),
            text: "let old = value",
            lineNumber: 41,
            kind: .delete,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .delete,
                range: NSRange(location: 0, length: 15),
                tone: .delete,
                sourceLine: line
            )
        ]

        let result = DiffPaneLSPLineMap.position(
            at: 4,
            metadata: metadata,
            allowedSide: .new
        )

        #expect(result == nil)
    }

    @Test func rejectsCharacterOutsideSourceText() {
        let line = DiffDisplayLine(
            id: "file:new:0:0",
            anchor: DiffLineAnchor(filePath: "Sources/App.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 8),
            text: "abc",
            lineNumber: 8,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .add,
                range: NSRange(location: 10, length: 3),
                tone: .add,
                sourceLine: line
            )
        ]

        #expect(DiffPaneLSPLineMap.position(at: 9, metadata: metadata, allowedSide: .new) == nil)
        #expect(DiffPaneLSPLineMap.position(at: 13, metadata: metadata, allowedSide: .new) == nil)
    }

    @Test func rejectsCollapsedRows() {
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .collapsed,
                range: NSRange(location: 0, length: 20),
                tone: .collapsed,
                sourceLine: nil
            )
        ]

        #expect(DiffPaneLSPLineMap.position(at: 5, metadata: metadata, allowedSide: .new) == nil)
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneLSPLineMapTests test
```

Expected: build fails because `DiffPaneLSPLineMap` and `LineMetadata(sourceLine:)` do not exist.

- [ ] **Step 3: Implement source metadata and mapper**

In `Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift`, change `LineMetadata`:

```swift
struct LineMetadata: Equatable {
    let kind: DiffDisplayRow.Kind
    let range: NSRange
    var tone: DiffPaneLineTone? = nil
    var sourceLine: DiffDisplayLine? = nil
}
```

Update `ColumnAccumulator.append` to accept `sourceLine` and preserve it:

```swift
mutating func append(
    _ text: NSAttributedString,
    kind: DiffDisplayRow.Kind,
    tone: DiffPaneLineTone? = nil,
    sourceLine: DiffDisplayLine? = nil
) {
    if output.length > 0 {
        output.append(NSAttributedString(string: "\n", attributes: DiffPaneTextDocumentBuilder.baseAttributes(font: font, theme: theme)))
    }
    let start = output.length
    output.append(text)
    metadata.append(DiffPaneTextDocumentBuilder.LineMetadata(
        kind: kind,
        range: NSRange(location: start, length: output.length - start),
        tone: tone,
        sourceLine: sourceLine
    ))
}
```

Pass source lines from `buildSplit`:

```swift
oldColumn.append(
    code(row.old?.text ?? "", line: row.old, fileExtension: fileExtension, font: font, showWhitespace: showWhitespace, theme: theme),
    kind: row.kind,
    tone: tone(for: row.old, rowKind: row.kind),
    sourceLine: row.old
)
newColumn.append(
    code(row.new?.text ?? "", line: row.new, fileExtension: fileExtension, font: font, showWhitespace: showWhitespace, theme: theme),
    kind: row.kind,
    tone: tone(for: row.new, rowKind: row.kind),
    sourceLine: row.new
)
```

Pass source lines from `buildStacked`:

```swift
codeColumn.append(
    code(line.text, line: line, fileExtension: fileExtension, font: font, showWhitespace: showWhitespace, theme: theme),
    kind: row.kind,
    tone: tone(for: line, rowKind: row.kind),
    sourceLine: line
)
```

For collapsed rows and empty layout rows, pass `sourceLine: nil`.

Create `Alas/Sources/Center/Diff/DiffPaneLSP.swift` with the pure mapper:

```swift
import AppKit
import Foundation

struct DiffPaneLSPContext {
    let worktreeId: String
    let worktreeRoot: URL
    let relativePath: String
    let language: String
    let lsp: WorkspaceLSPManager
    let openTarget: @MainActor (URL, Int, Int) -> Void

    var fileURL: URL {
        worktreeRoot.appendingPathComponent(relativePath)
    }

    var uri: String {
        fileURL.lspURI
    }
}

enum DiffPaneLSPLineMap {
    static func position(
        at characterIndex: Int,
        metadata: [DiffPaneTextDocumentBuilder.LineMetadata],
        allowedSide: DiffLineSide
    ) -> LSPPosition? {
        guard let line = metadata.first(where: { NSLocationInRange(characterIndex, $0.range) }) else {
            return nil
        }
        guard let source = line.sourceLine,
              source.anchor.side == allowedSide,
              let newLine = source.anchor.newLine,
              newLine > 0
        else {
            return nil
        }

        let character = characterIndex - line.range.location
        guard character >= 0, character < source.text.utf16.count else {
            return nil
        }
        return LSPPosition(line: newLine - 1, character: character)
    }
}
```

- [ ] **Step 4: Run mapper tests and verify GREEN**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneLSPLineMapTests test
```

Expected: `DiffPaneLSPLineMapTests` passes.

- [ ] **Step 5: Commit**

```bash
rtk git add Alas/Sources/Center/Diff/DiffPaneLSP.swift Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift AlasTests/DiffPaneLSPTests.swift
rtk git commit -m "feat(diff): map diff rows to LSP positions"
```

---

### Task 2: Diff Text View Interaction Primitives

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`
- Modify: `AlasTests/DiffPaneViewTests.swift`

- [ ] **Step 1: Write failing AppKit tests for metadata and hooks**

Append to `AlasTests/DiffPaneViewTests.swift`:

```swift
@Test func diffPaneCodeTextViewStoresLineMetadata() throws {
    let document = DiffPaneTextDocumentBuilder.CodeDocument(
        attributedString: NSAttributedString(string: "let value = 1"),
        lines: [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .add,
                range: NSRange(location: 0, length: 13),
                tone: .add,
                sourceLine: DiffDisplayLine(
                    id: "a.swift:new:0:0",
                    anchor: DiffLineAnchor(filePath: "a.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 3),
                    text: "let value = 1",
                    lineNumber: 3,
                    kind: .add,
                    inlineSpans: [],
                    noTrailingNewline: false
                )
            )
        ]
    )
    let scrollView = DiffPaneTextScrollView()
    let theme = try Theme.loadBundled(id: "cool-slate")

    scrollView.update(
        document: document,
        lineLabels: ["+3"],
        wraps: false,
        font: .monospacedSystemFont(ofSize: 13, weight: .regular),
        theme: theme,
        lspContext: nil,
        allowedLSPSide: .new
    )

    let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
    #expect(codeView.lineMetadata.count == 1)
    #expect(codeView.lineMetadata.first?.sourceLine?.anchor.newLine == 3)
}

@Test func diffPaneCodeTextViewCanResolveSymbolRange() throws {
    let textView = DiffPaneCodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80), textContainer: NSTextContainer())
    textView.textStorage?.setAttributedString(NSAttributedString(string: "let value = service.fetch()"))
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)

    let range = (textView.string as NSString).rangeOfWord(at: 4)

    #expect(range == NSRange(location: 4, length: 5))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests test
```

Expected: build fails because `DiffPaneTextScrollView.update` has no LSP parameters and `DiffPaneCodeTextView.lineMetadata` is not exposed.

- [ ] **Step 3: Add diff text view hooks and metadata storage**

In `DiffPaneTextScrollView.update`, add parameters:

```swift
func update(
    document: DiffPaneTextDocumentBuilder.CodeDocument,
    lineLabels: [String],
    wraps: Bool,
    font: NSFont,
    theme: Theme,
    lspContext: DiffPaneLSPContext?,
    allowedLSPSide: DiffLineSide
)
```

Set the metadata:

```swift
textView.lineMetadata = document.lines
textView.updateLSP(context: lspContext, allowedSide: allowedLSPSide)
```

Update all existing callers in `DiffPaneTextDocumentContainerView` to pass `lspContext: nil` temporarily; Task 4 wires real contexts.

In `DiffPaneCodeTextView`, add:

```swift
var lineMetadata: [DiffPaneTextDocumentBuilder.LineMetadata] = []
var hoverHandler: ((NSPoint) -> Void)?
var commandClickHandler: ((NSPoint) -> Void)?
var flagsChangedHandler: ((NSEvent) -> Void)?
var mouseExitedHandler: (() -> Void)?
private var lspController: DiffPaneLSPController?

func updateLSP(context: DiffPaneLSPContext?, allowedSide: DiffLineSide) {
    if let context {
        if lspController == nil {
            lspController = DiffPaneLSPController(textView: self)
        }
        lspController?.update(context: context, allowedSide: allowedSide)
    } else {
        lspController?.tearDown()
        lspController = nil
    }
}

override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    hoverHandler?(convert(event.locationInWindow, from: nil))
}

override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command) {
        commandClickHandler?(convert(event.locationInWindow, from: nil))
        return
    }
    super.mouseDown(with: event)
}

override func flagsChanged(with event: NSEvent) {
    super.flagsChanged(with: event)
    flagsChangedHandler?(event)
}

override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    mouseExitedHandler?()
}

override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(NSTrackingArea(
        rect: bounds,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
        owner: self,
        userInfo: nil
    ))
}
```

Add helper methods to `DiffPaneCodeTextView`:

```swift
func characterIndex(at point: NSPoint) -> Int? {
    guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
    let containerPoint = NSPoint(
        x: point.x - textContainerInset.width,
        y: point.y - textContainerInset.height
    )
    let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
    let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
    return charIndex < (storage.string as NSString).length ? charIndex : nil
}

func symbolRange(at point: NSPoint) -> NSRange? {
    guard let index = characterIndex(at: point) else { return nil }
    let range = (string as NSString).rangeOfWord(at: index)
    return range.length == 0 ? nil : range
}

func symbolAnchorRect(for range: NSRange) -> NSRect? {
    guard range.length > 0, let layoutManager, let textContainer else { return nil }
    let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
    let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
    return rect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
}
```

In `DiffPaneCodeTextView.deinit`, call `lspController?.tearDown()`.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests test
```

Expected: `DiffPaneViewTests` passes.

- [ ] **Step 5: Commit**

```bash
rtk git add Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift AlasTests/DiffPaneViewTests.swift
rtk git commit -m "feat(diff): add LSP-ready text view hooks"
```

---

### Task 3: LSP Controller, Hover, Definition, And Balanced Retain

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneLSP.swift`
- Modify: `AlasTests/DiffPaneLSPTests.swift`

- [ ] **Step 1: Write failing retain/controller tests**

Append to `AlasTests/DiffPaneLSPTests.swift`:

```swift
@MainActor
@Test func readOnlyRetainLoadsExistingFileTextAndBalancesClose() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root.appendingPathComponent("File.swift")
    try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let recorder = DiffPaneLSPRetainRecorder()

    let retain = try await DiffPaneLSPDocumentRetain.open(
        worktreeRoot: root,
        fileURL: fileURL,
        language: "swift",
        open: recorder.open,
        close: recorder.close
    )

    #expect(recorder.openedText == "let value = 1\n")
    await retain.close()
    #expect(recorder.closed == true)
}

@MainActor
@Test func linePositionRejectsOldSideThroughControllerHelper() {
    let oldLine = DiffDisplayLine(
        id: "file:old:0:0",
        anchor: DiffLineAnchor(filePath: "File.swift", hunkIndex: 0, rowIndex: 0, side: .old, oldLine: 1, newLine: nil),
        text: "let value = 0",
        lineNumber: 1,
        kind: .delete,
        inlineSpans: [],
        noTrailingNewline: false
    )
    let metadata = [
        DiffPaneTextDocumentBuilder.LineMetadata(kind: .delete, range: NSRange(location: 0, length: 13), tone: .delete, sourceLine: oldLine)
    ]

    #expect(DiffPaneLSPLineMap.position(at: 4, metadata: metadata, allowedSide: .new) == nil)
}

@MainActor
private final class DiffPaneLSPRetainRecorder {
    var openedText: String?
    var closed = false

    func open(worktreeRoot: URL, fileURL: URL, language: String, text: String) async -> LSPClient? {
        openedText = text
        return nil
    }

    func close(worktreeRoot: URL, fileURL: URL, language: String) async {
        closed = true
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneLSPLineMapTests test
```

Expected: build fails because `DiffPaneLSPDocumentRetain` does not exist.

- [ ] **Step 3: Implement retain and controller**

In `DiffPaneLSP.swift`, add:

```swift
@MainActor
final class DiffPaneLSPDocumentRetain {
    typealias Open = (_ worktreeRoot: URL, _ fileURL: URL, _ language: String, _ text: String) async -> LSPClient?
    typealias Close = (_ worktreeRoot: URL, _ fileURL: URL, _ language: String) async -> Void

    private let worktreeRoot: URL
    private let fileURL: URL
    private let language: String
    private let closeDocument: Close
    private var isClosed = false

    private init(worktreeRoot: URL, fileURL: URL, language: String, close: @escaping Close) {
        self.worktreeRoot = worktreeRoot
        self.fileURL = fileURL
        self.language = language
        self.closeDocument = close
    }

    static func open(
        worktreeRoot: URL,
        fileURL: URL,
        language: String,
        open: @escaping Open,
        close: @escaping Close
    ) async throws -> DiffPaneLSPDocumentRetain {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        _ = await open(worktreeRoot, fileURL, language, text)
        return DiffPaneLSPDocumentRetain(worktreeRoot: worktreeRoot, fileURL: fileURL, language: language, close: close)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await closeDocument(worktreeRoot, fileURL, language)
    }

    deinit {
        if !isClosed {
            let worktreeRoot = worktreeRoot
            let fileURL = fileURL
            let language = language
            let closeDocument = closeDocument
            Task { @MainActor in
                await closeDocument(worktreeRoot, fileURL, language)
            }
        }
    }
}
```

Add `DiffPaneLSPController` in the same file. It should:

- Hold weak `DiffPaneCodeTextView`.
- Store current `DiffPaneLSPContext`, `allowedSide`, hover request id, definition request id, in-flight tasks, optional `DiffPaneLSPDocumentRetain`, and optional `HoverWindowController` / `NSPopover`.
- Install handlers on `DiffPaneCodeTextView` in `init`.
- On hover:
  - Get `symbolRange(at:)`.
  - Get character index at the symbol range location or mouse point.
  - Map to `LSPPosition` through `DiffPaneLSPLineMap`.
  - Get `context.lsp.openedClient(...)`; if nil, open a retain using `context.lsp.openDocument`.
  - Request `client.hover(uri: context.uri, position: position)`.
  - Render non-empty hover content using the same `MarkdownRenderer` and `HoverWindowController` path as `HoverFeature`.
- On Cmd-click:
  - Map to a position the same way.
  - Get or retain a client.
  - Request `client.definition(uri: context.uri, position: position)`.
  - Open the first result through `context.openTarget`.
  - If there are multiple results, present `DefinitionPicker` like `DefinitionFeature`.
- On `tearDown`:
  - Cancel tasks.
  - Clear text view handlers.
  - Hide hover and definition UI.
  - Close and nil out the retain.

Use this request helper shape so tests can reason about mapping independently:

```swift
func lspPosition(at point: NSPoint) -> LSPPosition? {
    guard let textView,
          let index = textView.characterIndex(at: point)
    else { return nil }
    return DiffPaneLSPLineMap.position(
        at: index,
        metadata: textView.lineMetadata,
        allowedSide: allowedSide
    )
}
```

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneLSPLineMapTests test
```

Expected: `DiffPaneLSPLineMapTests` passes.

- [ ] **Step 5: Commit**

```bash
rtk git add Alas/Sources/Center/Diff/DiffPaneLSP.swift AlasTests/DiffPaneLSPTests.swift
rtk git commit -m "feat(diff): add read-only LSP controller"
```

---

### Task 4: Thread LSP Context Through Diff Surfaces

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneView.swift`
- Modify: `Alas/Sources/Center/DiffTabView.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
- Modify: `Alas/Sources/Center/Commit/CommitTabView.swift`
- Modify: `Alas/Sources/Center/Commit/CommitDiffView.swift`
- Modify: `Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift`
- Modify tests that construct these views.

- [ ] **Step 1: Write failing propagation test**

In `AlasTests/DiffReviewSurfaceTests.swift`, update `fileSectionEmbedsDiffPaneWithoutToolbarAndShowsOpenFile` to assert a no-context render still works after the initializer changes:

```swift
#expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
```

Add a new test:

```swift
@Test func fileSectionAcceptsLSPContextFactoryWithoutChangingLayout() {
    let file = DiffReviewFileSectionModel(
        summary: summary(path: "Sources/App/AlphaView.swift"),
        parsedDiff: parsedDiff(),
        displayModel: displayModel(),
        placeholderMessage: nil,
        openFile: nil
    )
    var layout = DiffLayoutMode.split
    var wrap = false
    var whitespace = false
    let view = DiffReviewFileSection(
        file: file,
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "SF Mono",
        codeFontSize: 13,
        showsSourceBadge: false,
        lspContext: nil
    )

    let controller = NSHostingController(rootView: view)
    controller.view.layoutSubtreeIfNeeded()

    #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: build fails until initializers accept `lspContext`.

- [ ] **Step 3: Add optional context parameters**

In `DiffPaneTextDocumentView`, add:

```swift
let lspContext: DiffPaneLSPContext?
```

Pass it through `updateNSView` and `DiffPaneTextDocumentContainerView.update`.

In split mode:

```swift
oldPane.update(..., lspContext: nil, allowedLSPSide: .new)
newPane.update(..., lspContext: lspContext, allowedLSPSide: .new)
```

In stacked mode:

```swift
stackedPane.update(..., lspContext: lspContext, allowedLSPSide: .new)
```

In `DiffPaneView`, add:

```swift
let lspContext: DiffPaneLSPContext?
```

Give existing tests/callers `lspContext: nil` where no real context exists.

In `DiffReviewFileSection`, add:

```swift
let lspContext: DiffPaneLSPContext?
```

Pass it into `DiffPaneView`.

In `DiffReviewSurface`, add:

```swift
var lspContextForFile: (DiffReviewFileSectionModel) -> DiffPaneLSPContext? = { _ in nil }
```

Pass `lspContext: lspContextForFile(file)` to each `DiffReviewFileSection`.

- [ ] **Step 4: Build real contexts in tab views**

In `DiffTabView`, add a stored property:

```swift
let worktreeId: String
```

Update the `DiffTabView` call in `CenterPaneView`:

```swift
DiffTabView(
    worktreePath: worktree.path,
    relativePath: s.relativePath,
    staged: s.staged,
    worktreeId: worktree.id,
    appState: state,
    codeFontFamily: state.config.code.fontFamily,
    codeFontSize: CGFloat(state.config.code.fontSize),
    onOpenFile: openAvailable
        ? { state.openFile(relativePath: s.relativePath, worktreeId: worktree.id) }
        : nil,
    onRequestDiscardFile: {
        rps.requestDiscardFile(path: s.relativePath)
    }
)
```

Then add a computed context in `DiffTabView`:

```swift
private var lspContext: DiffPaneLSPContext? {
    guard !isFileDeleted else { return nil }
    guard let language = appState.lsp.language(forFileExtension: (relativePath as NSString).pathExtension) else {
        return nil
    }
    return DiffPaneLSPContext(
        worktreeId: worktreeId,
        worktreeRoot: worktreePath,
        relativePath: relativePath,
        language: language,
        lsp: appState.lsp,
        openTarget: { url, line, character in
            let prefix = worktreePath.path + "/"
            if url.path.hasPrefix(prefix) {
                let rel = String(url.path.dropFirst(prefix.count))
                appState.tabs.openEditor(worktreeId: worktreeId, relativePath: rel, revealLine: line, revealCharacter: character)
            } else {
                appState.tabs.openExternalEditor(worktreeId: worktreeId, absoluteURL: url, revealLine: line, revealCharacter: character, originatingRelativePath: relativePath, originatingWorktreeRoot: worktreePath, language: language)
            }
        }
    )
}
```

In `ReviewChangesTabView.reviewSurface`, pass a factory:

```swift
lspContextForFile: { file in
    makeLSPContext(relativePath: file.summary.path)
}
```

Add:

```swift
private func makeLSPContext(relativePath: String) -> DiffPaneLSPContext? {
    let fileURL = worktree.path.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: fileURL.path),
          let language = appState.lsp.language(forFileExtension: (relativePath as NSString).pathExtension)
    else { return nil }
    return DiffPaneLSPContext(
        worktreeId: worktree.id,
        worktreeRoot: worktree.path,
        relativePath: relativePath,
        language: language,
        lsp: appState.lsp,
        openTarget: { url, line, character in
            openLSPTarget(url: url, originatingRelativePath: relativePath, language: language, line: line, character: character)
        }
    )
}
```

Add the matching `openLSPTarget` helper in `ReviewChangesTabView`.

In `CommitTabView`, pass `worktreeId`, `worktreePath`, and `appState` into `CommitReviewBody`, then use the same context factory. Keep the file-exists guard so historical/deleted commit entries quietly disable LSP.

Update `CommitDiffView` and `DraftReviewRequestTabView` to pass `lspContext: nil`.

- [ ] **Step 5: Run propagation tests and verify GREEN**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: `DiffReviewSurfaceTests` passes.

- [ ] **Step 6: Commit**

```bash
rtk git add Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift Alas/Sources/Center/Diff/DiffPaneView.swift Alas/Sources/Center/DiffTabView.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/Center/DiffReview/DiffReviewSurface.swift Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift Alas/Sources/Center/Commit/CommitTabView.swift Alas/Sources/Center/Commit/CommitDiffView.swift Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift AlasTests/DiffReviewSurfaceTests.swift AlasTests/DiffPaneViewTests.swift
rtk git commit -m "feat(diff): enable LSP context in review surfaces"
```

---

### Task 5: Manual Tests, Full Verification, And Cleanup

**Files:**
- Modify: `docs/manual-test.md`

- [ ] **Step 1: Update manual test docs**

In `docs/manual-test.md`, replace the diff pane LSP expectation:

```markdown
3. Hover over a symbol on the new/current side and confirm a popover appears with type info / docs after the language server is ready.
4. Cmd-click a symbol on the new/current side and confirm Alas opens the definition in an editor tab.
5. Confirm hover still does nothing on old/deleted-side lines.
```

- [ ] **Step 2: Run targeted test suites**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneLSPLineMapTests -only-testing:AlasTests/DiffPaneViewTests -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: all targeted tests pass.

- [ ] **Step 3: Regenerate the Xcode project**

```bash
rtk xcodegen
```

Expected: `Alas.xcodeproj` includes the new source and test files. If `project.yml` changes are required, commit both `project.yml` and `Alas.xcodeproj`.

- [ ] **Step 4: Run required project verification**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: build and full test suite pass.

- [ ] **Step 5: Commit docs and cleanup fixes**

```bash
rtk git add docs/manual-test.md Alas.xcodeproj project.yml
rtk git add Alas/Sources AlasTests
rtk git commit -m "test(diff): verify LSP-aware diff review"
```

If there are no changes after verification, do not create an empty commit.
