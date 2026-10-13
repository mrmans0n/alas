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

    @Test(arguments: [
        ACPTranscriptCoreTextRowView.Content.thought(label: "Planning"),
        .toolGroupHeader(label: "Ran 3 commands", iconSystemName: "terminal", expanded: false),
    ])
    func oneLineRowsAreOneLineTall(content: ACPTranscriptCoreTextRowView.Content) {
        let height = row(content).measuredHeight(forWidth: 1_000)
        #expect(height > 10 && height < 30)
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

    @Test func rowsWithoutAMenuNeverGetAnActionsButton() {
        let view = row(.thought(label: "Planning"))
        view.hoverForTesting(true)
        #expect(view.actionsButtonForTesting == nil)
    }

    @Test func theActionsButtonSitsInTheRightLaneAndIsAlwaysVisibleForAssistiveTech() throws {
        var actions = ACPTranscriptNativeRows.Actions.testing(menu: true)
        actions.showsActionsPermanently = true
        let view = row(.agent(markdown: "Hi", commentary: false), actions: actions)
        _ = view.measuredHeight(forWidth: 1_400)
        let button = try #require(view.actionsButtonForTesting)
        #expect(button.alphaValue == 1)
        #expect(button.frame.minX == view.columnRect.maxX + ACPMessageGutterLayout.laneWidth - 8 - ACPMessageGutterLayout.menuWidth)
        #expect(button.frame.minY == -2)
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
        #expect(view.contentForTesting != nil)
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
