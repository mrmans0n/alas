import AppKit
import Testing
@testable import Alas

@MainActor
@Suite struct ACPTranscriptCoreTextRowViewTests {
    private var theme: Theme { try! Theme.loadBundled(id: "cool-slate") }

    private func row(
        _ content: ACPTranscriptCoreTextRowView.Content,
        actions: ACPTranscriptNativeRows.Actions = .inert
    ) -> ACPTranscriptCoreTextRowView {
        let view = ACPTranscriptCoreTextRowView(frame: .zero)
        view.configure(
            content: content, contentMaxWidth: 720, inToolCallGroup: false, theme: theme, typography: .default, actions: actions
        )
        return view
    }

    @Test func remeasuresAtANewWidth() {
        let view = row(.agent(markdown: String(repeating: "Words that wrap. ", count: 60), commentary: false))
        let wide = view.measuredHeight(forWidth: 1_000)
        let narrow = view.measuredHeight(forWidth: 400)
        #expect(narrow > wide)
        #expect(view.lastMeasuredWidth == 400)
        #expect(view.measuredHeight(forWidth: 0) == 0 && view.lastMeasuredWidth == 400)
    }

    @Test func theColumnIsCenteredAndCapped() {
        let view = row(.agent(markdown: "Hi", commentary: false))
        _ = view.measuredHeight(forWidth: 1_400)
        #expect(view.columnRect.width == 720)
        #expect(abs(view.columnRect.midX - 700) < 0.5)
    }

    @Test func reconfiguringWithNewContentInvalidatesTheHeight() {
        let view = row(.agent(markdown: "Short", commentary: false))
        let short = view.measuredHeight(forWidth: 800)
        var invalidated = false
        view.onIntrinsicSizeInvalidated = { invalidated = true }
        view.configure(content: .agent(markdown: String(repeating: "Longer text. ", count: 80), commentary: false),
                       contentMaxWidth: 720, inToolCallGroup: false, theme: theme, typography: .default)
        #expect(invalidated)
        #expect(view.measuredHeight(forWidth: 800) > short)
    }

    /// An agent row drawn natively while its message still receives chunks
    /// (steering routes them to an earlier row) must grow with the text.
    private func followingRow(_ text: StreamingText, respec: @escaping @MainActor () -> Void = {}) -> ACPTranscriptCoreTextRowView {
        var actions = ACPTranscriptNativeRows.Actions.inert
        actions.requestRespec = respec
        let view = ACPTranscriptCoreTextRowView(frame: .zero)
        view.configure(
            content: .agent(markdown: text.value, commentary: true), contentMaxWidth: 720, inToolCallGroup: false,
            theme: theme, typography: .default, actions: actions, source: (text, text.revision)
        )
        return view
    }

    private static let longerText = "Short" + String(repeating: " and more text.", count: 80)

    @Test func aMountedAgentRowFollowsItsStreamingText() {
        let text = StreamingText("Short")
        let view = followingRow(text)
        let container = NSView()
        container.addSubview(view)
        withExtendedLifetime(container) {
            let short = view.measuredHeight(forWidth: 800)
            var invalidated = false
            view.onIntrinsicSizeInvalidated = { invalidated = true }
            text.replace(with: Self.longerText)
            #expect(invalidated)
            #expect(view.content == .agent(markdown: Self.longerText, commentary: true))
            #expect(view.measuredHeight(forWidth: 800) > short)
        }
    }

    @Test func aMountedThoughtRowFollowsItsStreamingText() throws {
        let text = StreamingText("Reading the files")
        let spec = ACPTranscriptNativeRows.row(
            .thought(label: ACPThoughtView.inlineLabel(for: text.value) ?? "Thinking…"), contentMaxWidth: 720,
            inToolCallGroup: false, theme: theme, typography: .default, actions: .inert, source: text
        )
        let view = try #require(spec.make() as? ACPTranscriptCoreTextRowView)
        spec.configure(view)
        let container = NSView()
        container.addSubview(view)
        withExtendedLifetime(container) {
            text.replace(with: "Planning the change")
            #expect(view.content == .thought(label: ACPThoughtView.inlineLabel(for: "Planning the change") ?? "Thinking…"))
        }
    }

    /// A spec can be mounted after its buffer moved on, and a parked row
    /// misses publishes; either catches up only once it is in a superview.
    @Test func aRowMountedFromAStaleSpecCatchesUpOnlyWhenAttached() throws {
        let text = StreamingText("Short")
        let spec = ACPTranscriptNativeRows.row(
            .agent(markdown: text.value, commentary: true), contentMaxWidth: 720, inToolCallGroup: false,
            theme: theme, typography: .default, actions: .inert, source: text
        )
        text.replace(with: Self.longerText)
        let view = try #require(spec.make() as? ACPTranscriptCoreTextRowView)
        spec.configure(view)
        #expect(view.content == .agent(markdown: "Short", commentary: true))
        let container = NSView()
        container.addSubview(view)
        withExtendedLifetime(container) {
            #expect(view.content == .agent(markdown: Self.longerText, commentary: true))
        }
    }

    @Test func textANativeRowCannotDrawAsksForANewRowSpec() {
        let text = StreamingText("Short")
        var respecs = 0
        let view = followingRow(text) { respecs += 1 }
        let container = NSView()
        container.addSubview(view)
        withExtendedLifetime(container) {
            text.replace(with: "Short\n\n| a | b |\n|---|---|\n| 1 | 2 |")
            #expect(respecs == 1)
            #expect(view.content == .agent(markdown: "Short", commentary: true))
        }
    }

    @Test func actionsButtonAppearsOnHoverAndStaysWhileTheMenuIsOpen() throws {
        let view = row(.agent(markdown: "Hi", commentary: false), actions: .testing(menu: true))
        _ = view.measuredHeight(forWidth: 1_000)
        #expect(view.actionsButtonForTesting == nil)
        view.hoverForTesting(true)
        let button = try #require(view.actionsButtonForTesting)
        #expect(button.alphaValue == 1)
        view.isMenuOpenForTesting = true
        view.hoverForTesting(false)
        view.flushHoverForTesting()
        #expect(button.alphaValue == 1)
        view.isMenuOpenForTesting = false
        #expect(button.alphaValue == 0)
    }

    @Test func aPermanentActionsButtonIsAlwaysVisibleForAssistiveTech() throws {
        var actions = ACPTranscriptNativeRows.Actions.testing(menu: true)
        actions.showsActionsPermanently = true
        let view = row(.agent(markdown: "Hi", commentary: false), actions: actions)
        _ = view.measuredHeight(forWidth: 1_400)
        let button = try #require(view.actionsButtonForTesting)
        #expect(button.alphaValue == 1)
    }

    @Test func reconfiguringAMountedRowWhenAssistiveTechTurnsOnShowsTheButtonWithoutHover() throws {
        let view = row(.agent(markdown: "Hi", commentary: false), actions: .testing(menu: true))
        _ = view.measuredHeight(forWidth: 1_400)
        #expect(view.actionsButtonForTesting == nil)
        var on = ACPTranscriptNativeRows.Actions.testing(menu: true)
        on.showsActionsPermanently = true
        view.configure(
            content: .agent(markdown: "Hi", commentary: false), contentMaxWidth: 720, inToolCallGroup: false,
            theme: theme, typography: .default, actions: on
        )
        let button = try #require(view.actionsButtonForTesting)
        #expect(button.alphaValue == 1)
        view.configure(
            content: .agent(markdown: "Hi", commentary: false), contentMaxWidth: 720, inToolCallGroup: false,
            theme: theme, typography: .default, actions: .testing(menu: true)
        )
        #expect(button.alphaValue == 0)
    }

    @Test(arguments: [
        (ACPTranscriptCoreTextRowView.Content.thought(label: "Planning"), true),
        (.toolCall(
            presentation: ACPToolCallPresentation.resolve(.init(toolCallId: "t", title: "Read a", kind: "read", status: "completed")),
            target: "a.swift", duration: nil, failed: false
        ), true),
        (.toolGroupHeader(label: "Ran 3 commands", iconSystemName: "terminal", expanded: true), false),
    ])
    func aClickReleasedOverTheHeaderTogglesExpansion(content: ACPTranscriptCoreTextRowView.Content, expected: Bool) {
        var toggles: [Bool] = []
        var actions = ACPTranscriptNativeRows.Actions.inert
        actions.toggleExpanded = { toggles.append($0) }
        let view = row(content, actions: actions)
        let height = view.measuredHeight(forWidth: 1_000)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 200), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: height)
        let header = view.convert(NSPoint(x: view.columnRect.midX, y: height / 2), to: nil)
        let outside = view.convert(NSPoint(x: view.columnRect.midX, y: height + 50), to: nil)
        func send(_ type: NSEvent.EventType, at point: NSPoint) {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
        }

        send(.leftMouseDown, at: header)
        send(.leftMouseUp, at: outside)
        #expect(toggles.isEmpty)

        send(.leftMouseDown, at: header)
        send(.leftMouseUp, at: header)
        #expect(toggles == [expected])
    }

    @Test func aTallRowDropsTilesScrolledFarAway() throws {
        let view = row(.agent(markdown: String(repeating: "A line of a long message.\n\n", count: 800), commentary: false))
        let height = view.measuredHeight(forWidth: 800)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: height)
        scrollView.documentView = view
        window.contentView = scrollView
        let tileCount = Int(ceil(height / ACPTranscriptCoreTextRowView.tileHeight))
        try #require(tileCount > 10)

        view.updateLayer()
        #expect(view.tiles.keys.contains(0))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: height - 400))
        view.updateLayer()
        #expect(view.tiles.keys.contains(tileCount - 1))
        #expect(!view.tiles.keys.contains(0))
    }

    @Test func aShortUserBubbleKeepsItsTextInsideTheBubble() throws {
        let view = row(.user(markdown: "Can you fix the bug?"))
        _ = view.measuredHeight(forWidth: 1_000)
        let text = try #require(view.accessibilityChildren()?.compactMap { $0 as? ACPTranscriptTextAccessibilityElement }.first)
        let frame = text.accessibilityFrameInParentSpace()
        // The bubble hugs the text and sits at the column's trailing edge.
        #expect(frame.width < 200)
        #expect(frame.maxX <= view.columnRect.maxX)
    }

    @Test func aWrappedLinkHitTestsOnlyItsOwnText() throws {
        let view = row(.agent(markdown: "Plain words before [the full migration guide for this release](https://example.com) and after.", commentary: false))
        _ = view.measuredHeight(forWidth: 420)
        let link = try #require(view.linkAccessibilityElements().first)
        #expect(link.fragments.count > 1)
        let first = try #require(link.fragments.first)
        // Left of where the link starts on its first line: plain text, inside the union.
        let beside = NSPoint(x: first.minX - 4, y: first.midY)
        #expect(link.accessibilityFrameInParentSpace().contains(beside))
        #expect(view.linkAccessibilityElement(at: beside) == nil)
        #expect(view.linkAccessibilityElement(at: NSPoint(x: first.midX, y: first.midY)) === link)
    }

    @Test func linksAreAccessibleAndOpenWhenPressed() throws {
        var opened: [URL] = []
        var actions = ACPTranscriptNativeRows.Actions.inert
        actions.openURL = { opened.append($0) }
        let view = row(.agent(markdown: "See [the docs](https://example.com) now.", commentary: false), actions: actions)
        _ = view.measuredHeight(forWidth: 800)
        let link = try #require(view.accessibilityChildren()?.compactMap { $0 as? ACPTranscriptLinkAccessibilityElement }.first)
        #expect(link.accessibilityRole() == .link)
        #expect(link.accessibilityLabel() == "the docs")
        #expect(!link.accessibilityFrameInParentSpace().isEmpty)
        #expect(link.accessibilityPerformPress())
        #expect(opened == [URL(string: "https://example.com")!])
    }

    @Test(arguments: [(0.0, true), (2.0, true), (6.0, false)])
    func aLinkOpensOnClickButNotAfterADrag(dragDistance: Double, opens: Bool) {
        for content in [
            ACPTranscriptCoreTextRowView.Content.agent(markdown: "[docs](https://example.com)", commentary: false),
            .user(markdown: "[docs](https://example.com)"),
        ] {
            var opened: [URL] = []
            var actions = ACPTranscriptNativeRows.Actions.inert
            actions.openURL = { opened.append($0) }
            let view = row(content, actions: actions)
            let height = view.measuredHeight(forWidth: 1_000)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 200), styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView?.addSubview(view)
            view.frame = NSRect(x: 0, y: 0, width: 1_000, height: height)
            // Agent text starts at the column's left edge; the bubble hugs the right edge.
            let x: CGFloat
            if case .user = content { x = view.columnRect.maxX - 30 } else { x = view.columnRect.minX + 8 }
            let start = view.convert(NSPoint(x: x, y: 10), to: nil)
            func send(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
                )!
                switch type {
                case .leftMouseDown: view.mouseDown(with: event)
                case .leftMouseDragged: view.mouseDragged(with: event)
                default: view.mouseUp(with: event)
                }
            }
            // A drag that wanders and returns still counts as a drag.
            let end = NSPoint(x: start.x + dragDistance, y: start.y)
            send(.leftMouseDown, at: start)
            if dragDistance > 0 { send(.leftMouseDragged, at: end) }
            send(.leftMouseUp, at: start)
            #expect(opened == (opens ? [URL(string: "https://example.com")!] : []))
            // A drag that starts on a link selects text instead.
            #expect(view.selectedText().isEmpty == opens)
            // The second press of a double-click does not open it again.
            let openedBefore = opened
            send(.leftMouseDown, at: start, clickCount: 2)
            send(.leftMouseUp, at: start, clickCount: 2)
            #expect(opened == openedBefore)
        }
    }

    @Test func escapeAfterAPlainClickReachesTheNextResponder() {
        let view = row(.agent(markdown: "Plain text to click", commentary: false))
        let height = view.measuredHeight(forWidth: 1_000)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 200), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: height)
        let point = view.convert(NSPoint(x: view.columnRect.minX + 20, y: 10), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
        }
        let probe = CancelProbe()
        view.nextResponder = probe
        view.cancelOperation(nil)
        #expect(probe.cancelled)
    }

    @Test func draggingAcrossBlocksCopiesTheSourceText() throws {
        let view = row(.agent(markdown: "First paragraph.\n\nSecond `code` here.\n\n```swift\nlet x = 1\n```", commentary: false))
        _ = view.measuredHeight(forWidth: 800)
        view.selectAllForTesting()
        // Rendered text, as SwiftUI's selection copies it: no backticks, no
        // code-block language label or "Copy".
        #expect(view.selectedText() == "First paragraph.\nSecond code here.\nlet x = 1")
    }

    @Test func codeBlockCopyIsAnAccessibleButton() throws {
        let view = row(.agent(markdown: "Intro.\n\n```swift\nlet x = 1\n```", commentary: false))
        _ = view.measuredHeight(forWidth: 800)
        let pasteboard = NSPasteboard(name: .init("acp-native-ax-copy-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.codeCopyPasteboard = pasteboard
        let copy = try #require(view.accessibilityChildren()?.compactMap { $0 as? ACPTranscriptCodeCopyAccessibilityElement }.first)
        #expect(copy.accessibilityRole() == .button)
        #expect(copy.accessibilityLabel() == "Copy code")
        #expect(!copy.accessibilityFrameInParentSpace().isEmpty)
        #expect(copy.accessibilityPerformPress())
        #expect(pasteboard.string(forType: .string) == "let x = 1")
    }

    @Test func commentaryRowsAreLabeledLikeTheirHeader() {
        #expect(row(.agent(markdown: "Checking the tests.", commentary: true)).accessibilityLabel() == "Working…")
        #expect(row(.agent(markdown: "Done.", commentary: false)).accessibilityLabel() != "Working…")
    }

    @Test func aRightToLeftSelectionIsHighlighted() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "שלום עולם", attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ))
        let extent = ACPTranscriptCoreTextRowView.selectionExtent(of: line, from: 0, to: 4, hasText: true, runsTo: nil)
        #expect(extent.upperBound - extent.lowerBound > 10)
    }

    @Test func codeBlockLanguageIsAccessibleStaticText() throws {
        let view = row(.agent(markdown: "```swift\nlet x = 1\n```\n\n```\nplain\n```", commentary: false))
        _ = view.measuredHeight(forWidth: 800)
        let labels = (view.accessibilityChildren() ?? []).compactMap { $0 as? ACPTranscriptCodeLabelAccessibilityElement }
        #expect(labels.map { $0.accessibilityLabel() } == ["SWIFT"])
        let frame = try #require(labels.first?.accessibilityFrameInParentSpace())
        #expect(view.codeLabelAccessibilityElement(at: NSPoint(x: frame.midX, y: frame.midY)) === labels.first)
    }

    @Test func codeBlockCopyCopiesOnlyTheCodeAndShowsCopiedUntilTheDelayEnds() async throws {
        let view = row(.agent(markdown: "```swift\nlet x = 1\n```", commentary: false))
        _ = view.measuredHeight(forWidth: 800)
        let (wait, release) = AsyncStream<Void>.makeStream()
        view.codeCopyFeedbackWait = { for await _ in wait { break } }
        let pasteboard = NSPasteboard(name: .init("acp-native-copy-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(view.clickCodeCopyForTesting(block: 0, pasteboard: pasteboard))
        #expect(pasteboard.string(forType: .string) == "let x = 1")
        #expect(view.copiedCodeBlockForTesting == 0)
        release.yield()
        await view.codeCopyFeedbackTaskForTesting?.value
        #expect(view.copiedCodeBlockForTesting == nil)
    }

    @Test(arguments: [true, false])
    func reconfiguringKeepsTheSelectionOnlyForTheSameContent(sameContent: Bool) {
        let content = ACPTranscriptCoreTextRowView.Content.agent(markdown: "Keep me", commentary: false)
        let view = row(content)
        _ = view.measuredHeight(forWidth: 800)
        view.selectAllForTesting()
        view.configure(content: sameContent ? content : .agent(markdown: "Other", commentary: false), contentMaxWidth: 720,
                       inToolCallGroup: false, theme: theme, typography: .default, actions: .testing(menu: false))
        #expect(view.selectedText().isEmpty == !sameContent)
    }
    @Test func textRowsReadTheirPlainTextAndBindTheSelection() throws {
        let view = row(.agent(markdown: "Hello **bold** world\n\nSecond `code` here", commentary: false))
        _ = view.measuredHeight(forWidth: 800)
        let element = try #require(view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first)
        #expect(element.accessibilityRole() == .textArea)
        #expect(element.accessibilityValue() as? String == "Hello bold world\nSecond code here")
        #expect(element.accessibilityRange(forLine: 1).location == 17)
        element.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 15))
        #expect(view.selectedText() == "bold world\nSeco")
        #expect(element.accessibilitySelectedText() == "bold world\nSeco")
    }

    @Test func textLineRangesFollowTheCurrentWrappingWithAStableElement() throws {
        let view = row(.agent(markdown: String(repeating: "Words that wrap. ", count: 40), commentary: false))
        _ = view.measuredHeight(forWidth: 800)
        let element = try #require(view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first)
        let wide = element.accessibilityRange(forLine: 1)
        // The same reference, with no fresh query of the children.
        _ = view.measuredHeight(forWidth: 300)
        #expect(element.accessibilityRange(forLine: 1) != wide)
        let after = try #require(view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first)
        #expect(after === element)
    }

    @Test func reconfiguringContentReplacesTheTextArea() throws {
        let view = row(.agent(markdown: "Hi", commentary: false))
        _ = view.measuredHeight(forWidth: 800)
        let first = try #require(view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first)
        view.configure(content: .agent(markdown: "Hi", commentary: true), contentMaxWidth: 720, inToolCallGroup: false, theme: theme, typography: .default)
        _ = view.measuredHeight(forWidth: 800)
        let second = try #require(view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first)
        #expect(second !== first)
        view.configure(content: .thought(label: "Planning"), contentMaxWidth: 720, inToolCallGroup: false, theme: theme, typography: .default)
        _ = view.measuredHeight(forWidth: 800)
        #expect(view.accessibilityChildren()?.isEmpty ?? true)
    }

    @Test func theActionsButtonIsAnAccessibilityChildOfTextRows() throws {
        var actions = ACPTranscriptNativeRows.Actions.testing(menu: true)
        actions.showsActionsPermanently = true
        let view = row(.agent(markdown: "Hi", commentary: false), actions: actions)
        _ = view.measuredHeight(forWidth: 800)
        let button = try #require(view.actionsButtonForTesting)
        let children = try #require(view.accessibilityChildren())
        #expect(children.contains { $0 as AnyObject === button })
    }

    @Test(arguments: [
        (false, "Collapsed", true), (true, "Expanded", false),
    ])
    func oneLineRowsAreButtonsThatToggle(headerExpanded: Bool, value: String, toggledTo: Bool) {
        var toggled: [Bool] = []
        var actions = ACPTranscriptNativeRows.Actions.inert
        actions.toggleExpanded = { toggled.append($0) }
        let header = row(.toolGroupHeader(label: "Ran 3 commands", iconSystemName: "terminal", expanded: headerExpanded), actions: actions)
        #expect(header.accessibilityRole() == .button)
        #expect(header.accessibilityLabel() == "Ran 3 commands")
        #expect(header.accessibilityValue() as? String == value)
        #expect(header.accessibilityPerformPress())
        #expect(toggled == [toggledTo])
    }

    @Test func toolRowsDescribeTheirTargetDurationAndFailure() {
        var toggled: [Bool] = []
        var actions = ACPTranscriptNativeRows.Actions.inert
        actions.toggleExpanded = { toggled.append($0) }
        let presentation = ACPToolCallPresentation.resolve(.init(toolCallId: "t", title: "Ran ls", kind: "execute", status: "failed"))
        let view = row(.toolCall(presentation: presentation, target: "ls", duration: "12ms", failed: true), actions: actions)
        #expect(view.accessibilityRole() == .button)
        #expect(view.accessibilityLabel() == "\(presentation.label) ls, 12ms, failed")
        #expect(view.accessibilityValue() as? String == "Collapsed")
        #expect(view.accessibilityPerformPress())
        #expect(toggled == [true])
    }
}

private final class CancelProbe: NSResponder {
    private(set) var cancelled = false
    override func cancelOperation(_ sender: Any?) { cancelled = true }
}

extension ACPTranscriptNativeRows.Actions {
    static func testing(menu: Bool) -> Self {
        var actions = Self.inert
        if menu {
            actions.menu = .init(
                markdown: { "Hi" }, createdAt: nil, checkpointID: nil, forkBoundary: nil, forkTargets: [],
                onQuote: { _ in }, onFork: { _, _ in }, onRestoreCheckpoint: { _ in }, messageMenuItems: { [] }
            )
        }
        return actions
    }
}
