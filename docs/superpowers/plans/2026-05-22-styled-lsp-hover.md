# Styled LSP Hover Content Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: See CLAUDE.md for execution guidelines. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain SwiftUI `AttributedString(markdown:)` hover renderer with the themed `MarkdownRenderer` (TreeSitter syntax highlighting, monospaced code, themed colors) and allow the popover to grow dynamically up to 500×400.

**Architecture:** Pass `Theme` + monospaced font params from `CodeEditorCoordinator` into `HoverFeature`. On hover, parse the LSP markdown response with `Document(parsing:)`, render it through `MarkdownRenderer`, and display the resulting `NSAttributedString` via an `NSViewRepresentable` wrapping a read-only `NSTextView`. Compute popover size from the layout manager's `usedRect`.

**Tech Stack:** Swift 5.9+, AppKit `NSTextView`, swift-markdown `Document`, existing `MarkdownRenderer` / `EditorTheme` / `CenterTypography`

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Alas/Sources/Code/LSP/Features/HoverFeature.swift` | Hover trigger logic, MarkdownRenderer integration, new `HoverContentView` NSViewRepresentable, dynamic popover sizing |
| `Alas/Sources/Code/Editor/CodeEditorCoordinator.swift` | Pass theme + font closures to HoverFeature init |

---

### Task 1: Add theme and font parameters to HoverFeature

**Files:**
- Modify: `Alas/Sources/Code/LSP/Features/HoverFeature.swift:4-19`

- [ ] **Step 1: Add stored properties and update init**

Replace the current `HoverFeature` class declaration and init:

```swift
@MainActor
final class HoverFeature {
    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?
    private let getTheme: () -> Theme
    private let getMonoFontFamily: () -> String
    private let getMonoFontSize: () -> Int
    private var debounce: Task<Void, Never>?
    private var popover: NSPopover?
    private var lastPosition: NSPoint?
    private var requestID: UInt64 = 0

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?,
        getTheme: @escaping () -> Theme,
        getMonoFontFamily: @escaping () -> String,
        getMonoFontSize: @escaping () -> Int
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        self.getTheme = getTheme
        self.getMonoFontFamily = getMonoFontFamily
        self.getMonoFontSize = getMonoFontSize
        textView.hoverHandler = { [weak self] p in self?.onMove(at: p) }
    }
```

- [ ] **Step 2: Update presentPopover to use MarkdownRenderer**

Replace the `presentPopover` method (lines 83-94):

```swift
    private func presentPopover(text: String, anchor: NSRect, in view: NSView) {
        let theme = getTheme()
        let family = getMonoFontFamily()
        let size = getMonoFontSize()

        let document = Document(parsing: text)
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: family,
            monospacedFontSize: size,
            baseDirectory: URL(fileURLWithPath: "/")
        )

        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(
            rootView: HoverContentView(result: result, theme: theme)
        )
        popover.contentViewController = host
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        self.popover = popover

        applyPopoverSize(for: result)
    }

    private func applyPopoverSize(for result: MarkdownRenderResult) {
        guard let popover else { return }
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage(attributedString: result.attributedString)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.glyphRange(for: textContainer)

        var usedRect = layoutManager.usedRect(for: textContainer)
        // Account for textContainerInset (8pt per side) + some padding for the scroll view chrome
        usedRect.size.width += 16 + 20
        usedRect.size.height += 16 + 20

        let minSize = NSSize(width: 360, height: 220)
        let maxSize = NSSize(width: 500, height: 400)
        let clamped = NSSize(
            width: max(minSize.width, min(usedRect.size.width, maxSize.width)),
            height: max(minSize.height, min(usedRect.size.height, maxSize.height))
        )
        popover.contentSize = clamped
    }
```

- [ ] **Step 3: Replace HoverContentView with NSViewRepresentable**

Replace the old `HoverContentView` (lines 102-115) with:

```swift
private struct HoverContentView: NSViewRepresentable {
    let result: MarkdownRenderResult
    let theme: Theme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        context.coordinator.textView = textView
        textView.textStorage?.setAttributedString(result.attributedString)
        scrollView.backgroundColor = NSColor(theme.color("bg-1"))
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.textStorage?.setAttributedString(result.attributedString)
        nsView.backgroundColor = NSColor(theme.color("bg-1"))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView? {
            didSet { textView?.delegate = self }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            true
        }
    }
}
```

- [ ] **Step 4: Add imports at top of file**

Replace line 1 with:

```swift
import AppKit
import Markdown
import SwiftUI
```

- [ ] **Step 5: Verify the file compiles correctly**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Code/LSP/Features/HoverFeature.swift
git commit -m "feat: render LSP hover with MarkdownRenderer and dynamic sizing"
```

---

### Task 2: Wire theme + font into HoverFeature from CodeEditorCoordinator

**Files:**
- Modify: `Alas/Sources/Code/Editor/CodeEditorCoordinator.swift:94-114`

- [ ] **Step 1: Update HoverFeature construction to pass theme and font closures**

Replace the `hover = HoverFeature(...)` block on lines 94-114:

```swift
        hover = HoverFeature(
            textView: textView,
            getClient: { [weak self] in
                guard let self, let lang = self.currentLanguage else { return nil }
                if let abs = self.currentExternalAbsolutePath,
                   let originating = self.currentOriginatingWorktreeRoot {
                    let absURL = URL(fileURLWithPath: abs)
                    return self.appState.lsp.client(forFile: absURL, worktreeRoot: originating, language: lang)
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return self.appState.lsp.client(forFile: root.appendingPathComponent(rel), worktreeRoot: root, language: lang)
            },
            getURI: { [weak self] in
                guard let self else { return nil }
                if let abs = self.currentExternalAbsolutePath {
                    return URL(fileURLWithPath: abs).lspURI
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            },
            getTheme: { [weak self] in
                self?.currentTheme ?? self?.appState.config.themeStore.current ?? ThemeStore().current
            },
            getMonoFontFamily: { [weak self] in
                self?.currentFontFamily ?? self?.appState.config.code.fontFamily ?? "SF Mono"
            },
            getMonoFontSize: { [weak self] in
                self?.currentFontSize.map(Int.init) ?? self?.appState.config.code.fontSize ?? 13
            }
        )
```

- [ ] **Step 2: Verify the file compiles correctly**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/Code/Editor/CodeEditorCoordinator.swift
git commit -m "feat: pass theme and font settings to HoverFeature"
```

---

### Task 3: Write tests for LSP hover rendering

**Files:**
- Create: `AlasTests/HoverFeatureRenderingTests.swift`

- [ ] **Step 1: Write the test file**

```swift
import Testing
import AppKit
import Markdown
@testable import Alas

@MainActor
struct HoverFeatureRenderingTests {

    @Test func rendersMarkdownProseWithThemeForeground() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let document = Document(parsing: "Hello, world.")
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let s = result.attributedString
        let color = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let expected = NSColor(theme.color("fg"))
        #expect(color == expected)
    }

    @Test func rendersCodeBlockMonospaced() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let document = Document(parsing: "```swift\nlet x = 1\n```")
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let s = result.attributedString
        let range = (s.string as NSString).range(of: "let x = 1")
        let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func highlightsSwiftCodeBlockKeyword() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let document = Document(parsing: "```swift\nfunc f() {}\n```")
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let s = result.attributedString
        let range = (s.string as NSString).range(of: "func")
        let color = s.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        let defaultFG = NSColor(theme.color("fg"))
        #expect(color != defaultFG)
    }

    @Test func rendersPlainContentAsMonospaced() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        // Plain (non-markdown) text: wrap as inline code so it renders monospaced.
        // This simulates what HoverFeature does for .plain LSP responses.
        let wrappedInBackticks = "`let x: Int`"
        let document = Document(parsing: wrappedInBackticks)
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let s = result.attributedString
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func hoverContentViewUsesThemeBackground() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let document = Document(parsing: "Hello")
        let result = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let view = HoverFeatureTesting.makeHoverContainer(
            result: result,
            theme: theme
        )
        let bgColor = view.backgroundColor
        let expected = NSColor(theme.color("bg-1"))
        #expect(bgColor == expected)
    }

    @Test func popoverSizeClampsToMinAndMax() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        // Tiny content should clamp to min 360×220
        let tiny = Document(parsing: "x")
        let tinyResult = MarkdownRenderer().render(
            document: tiny, theme: theme,
            monospacedFontFamily: "SF Mono", monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let tinySize = HoverFeatureTesting.computePreferredSize(for: tinyResult)
        #expect(tinySize.width >= 360)
        #expect(tinySize.height >= 220)

        // Large content should clamp to max 500×400
        let huge = Document(parsing: String(repeating: "very long line of text that just keeps going on and on and on forever ", count: 30))
        let hugeResult = MarkdownRenderer().render(
            document: huge, theme: theme,
            monospacedFontFamily: "SF Mono", monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/tmp")
        )
        let hugeSize = HoverFeatureTesting.computePreferredSize(for: hugeResult)
        #expect(hugeSize.width <= 500)
        #expect(hugeSize.height <= 400)
    }
}
```

- [ ] **Step 2: Add test helper extension to HoverFeature.swift**

Add at the bottom of `HoverFeature.swift`, before the `CodeTextView` extension:

```swift
enum HoverFeatureTesting {
    static func makeHoverContainer(result: MarkdownRenderResult, theme: Theme) -> NSScrollView {
        let view = HoverContentView(result: result, theme: theme)
        return view.makeNSView(context: view.makeCoordinator())
    }

    static func computePreferredSize(for result: MarkdownRenderResult) -> NSSize {
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage(attributedString: result.attributedString)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.glyphRange(for: textContainer)

        var usedRect = layoutManager.usedRect(for: textContainer)
        usedRect.size.width += 16 + 20
        usedRect.size.height += 16 + 20

        let minSize = NSSize(width: 360, height: 220)
        let maxSize = NSSize(width: 500, height: 400)
        return NSSize(
            width: max(minSize.width, min(usedRect.size.width, maxSize.width)),
            height: max(minSize.height, min(usedRect.size.height, maxSize.height))
        )
    }
}
```

- [ ] **Step 3: Run the tests**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/HoverFeatureRenderingTests 2>&1 | tail -20
```

Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add AlasTests/HoverFeatureRenderingTests.swift Alas/Sources/Code/LSP/Features/HoverFeature.swift
git commit -m "test: add rendering tests for LSP hover content"
```

---

### Task 4: Handle plain-text (non-markdown) LSP hover responses

**Files:**
- Modify: `Alas/Sources/Code/LSP/Features/HoverFeature.swift:58-72`

- [ ] **Step 1: Wrap plain text in backticks for monospaced rendering**

In the `show` method, after extracting `body` (lines 58-66), add logic to handle the `.plain` case:

Replace lines 58-72:

```swift
        let body: String
        let isPlain: Bool
        switch result.contents {
        case .markupContent(_, let value):
            body = value
            isPlain = false
        case .plain(let s):
            body = s
            isPlain = true
        }
        guard !body.isEmpty else {
            closePopover()
            return
        }
        // Wrap plain text so it renders in monospaced font via MarkdownRenderer's
        // inline code treatment. Wrap only if it doesn't already contain backticks.
        let markdown = isPlain && !body.contains("`") ? "`\(body)`" : body
        let textRect = textView.firstRect(for: position) ?? CGRect(origin: point, size: .zero)
        await MainActor.run {
            guard self.isCurrentRequest(currentRequestID, uri: uri, position: position, point: point) else { return }
            self.presentPopover(text: markdown, anchor: textRect, in: textView)
        }
```

- [ ] **Step 2: Verify the file compiles correctly**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/Code/LSP/Features/HoverFeature.swift
git commit -m "feat: render plain-text LSP hover in monospaced font"
```

---

### Task 5: Full build and test

- [ ] **Step 1: Full clean build**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run all tests**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: All tests pass, 0 failures

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: verify full build and test suite passes"
```
