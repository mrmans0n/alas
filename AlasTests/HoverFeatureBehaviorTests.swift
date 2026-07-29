import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct HoverFeatureBehaviorTests {
    private func makeTextView() -> CodeTextView {
        let storage = NSTextStorage(string: "let value = foo + bar\n")
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        _ = layoutManager.glyphRange(for: container)
        return textView
    }

    private func point(forCharacterAt index: Int, in textView: CodeTextView) -> NSPoint {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return .zero }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSPoint(
            x: rect.midX + textView.textContainerInset.width,
            y: rect.midY + textView.textContainerInset.height
        )
    }

    private func makeFeature(textView: CodeTextView, recorder: HoverRequestRecorder) -> HoverFeature {
        let theme = (try? Theme.loadBundled(id: "cool-slate"))
            ?? Theme(id: "fallback", name: "Fallback", tokens: [:])
        return HoverFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/example.swift" },
            getTheme: { theme },
            getMonoFontFamily: { "SF Mono" },
            getMonoFontSize: { 13 },
            requestHover: { uri, position in
                await recorder.record(uri: uri, position: position)
                return recorder.nextResponse()
            }
        )
    }

    @Test func mouseOverNonSymbolIssuesNoRequest() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: NSPoint(x: 600, y: 8))
        try? await Task.sleep(nanoseconds: 900_000_000)

        #expect(await recorder.calls.count == 0)
        #expect(feature.isShowingPopover == false)
    }

    @Test func dwellOverSymbolFiresRequestAfterTimer() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.plainText("foo: Int"))
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(await recorder.calls.count == 0)
        #expect(feature.isShowingPopover == false)

        try? await Task.sleep(nanoseconds: 700_000_000)
        #expect(await recorder.calls.count == 1)
        #expect(feature.isShowingPopover == true)
    }

    @Test func mouseExitsSymbolBeforeDwellCancelsTimer() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        try? await Task.sleep(nanoseconds: 200_000_000)
        feature.simulateMouseMoved(at: NSPoint(x: 600, y: 8))
        try? await Task.sleep(nanoseconds: 900_000_000)

        #expect(await recorder.calls.count == 0)
        #expect(feature.isShowingPopover == false)
    }

    @Test func mouseMovesBetweenSymbolsResetsTimer() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.plainText("first"))
        recorder.queueResponse(.plainText("second"))
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        try? await Task.sleep(nanoseconds: 200_000_000)
        feature.simulateMouseMoved(at: point(forCharacterAt: 18, in: textView))
        try? await Task.sleep(nanoseconds: 900_000_000)

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(feature.isShowingPopover == true)
    }

    @Test func optionAcceleratorFiresImmediately() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.plainText("Int"))
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        feature.simulateOptionPressed()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(await recorder.calls.count == 1)
        #expect(feature.isShowingPopover == true)
    }

    @Test func optionWithoutSymbolDoesNothing() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: NSPoint(x: 600, y: 8))
        feature.simulateOptionPressed()
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(await recorder.calls.count == 0)
        #expect(feature.isShowingPopover == false)
    }

    @Test func mouseMovementInsideShownSymbolDoesNotReRequest() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.plainText("foo: Int"))
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        try? await Task.sleep(nanoseconds: 900_000_000)
        #expect(feature.isShowingPopover == true)
        #expect(await recorder.calls.count == 1)

        feature.simulateMouseMoved(at: point(forCharacterAt: 13, in: textView))
        feature.simulateMouseMoved(at: point(forCharacterAt: 14, in: textView))
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(await recorder.calls.count == 1)
        #expect(feature.isShowingPopover == true)
    }

    @Test func scrollNotificationDismisses() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.plainText("foo"))
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        feature.simulateOptionPressed()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(feature.isShowingPopover == true)

        feature.notifyScrolled()
        #expect(feature.isShowingPopover == false)
    }

    @Test func caretChangeNotificationDismisses() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.plainText("foo"))
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        feature.simulateOptionPressed()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(feature.isShowingPopover == true)

        feature.notifyCaretChanged()
        #expect(feature.isShowingPopover == false)
    }

    @Test func escapeKeyDismissesAndConsumesEvent() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.plainText("foo"))
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        feature.simulateOptionPressed()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(feature.isShowingPopover == true)

        let consumed = feature.handleEscape()
        #expect(consumed == true)
        #expect(feature.isShowingPopover == false)
    }

    @Test func escapeKeyWhenNotShownDoesNotConsume() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        let feature = makeFeature(textView: textView, recorder: recorder)

        let consumed = feature.handleEscape()
        #expect(consumed == false)
    }

    @Test func windowResizeNotificationDismisses() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.plainText("foo"))
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        feature.simulateOptionPressed()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(feature.isShowingPopover == true)

        feature.notifyWindowResized()
        #expect(feature.isShowingPopover == false)
    }

    @Test func mermaidExpansionAllowsSameSymbolToReopen() async throws {
        let textView = makeTextView()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.mermaid("graph TD; A-->B"))
        recorder.queueResponse(.plainText("reopened"))
        let feature = makeFeature(textView: textView, recorder: recorder)
        defer {
            MermaidDiagramViewerController.shared.dismiss()
            feature.tearDown()
            window.close()
        }
        let symbolPoint = point(forCharacterAt: 12, in: textView)

        feature.simulateMouseMoved(at: symbolPoint)
        feature.simulateOptionPressed()
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(await recorder.calls.count == 1)
        #expect(feature.isShowingPopover)
        let overlay = try #require(window.childWindows?.first)
        overlay.contentViewController?.view.layoutSubtreeIfNeeded()
        let hoverTextView = try #require(
            firstTextView(in: overlay.contentViewController?.view)
        )
        let cell = try #require(firstMermaidCell(in: hoverTextView))

        cell.delegate?.mermaidTextAttachmentCellDidRequestExpansion(cell)

        #expect(!feature.isShowingPopover)
        #expect(window.attachedSheet?.title == "Mermaid Diagram")
        MermaidDiagramViewerController.shared.dismiss()

        feature.simulateMouseMoved(at: symbolPoint)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(await recorder.calls.count == 2)
        #expect(feature.isShowingPopover)
    }

    @Test func mouseExitsEditorAfterGraceDismisses() async {
        let textView = makeTextView()
        let recorder = HoverRequestRecorder()
        recorder.queueResponse(.plainText("foo"))
        let feature = makeFeature(textView: textView, recorder: recorder)

        feature.simulateMouseMoved(at: point(forCharacterAt: 12, in: textView))
        feature.simulateOptionPressed()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(feature.isShowingPopover == true)

        // Mouse left the editor: grace timer arms, popover stays for now.
        textView.mouseExitedHandler?()
        #expect(feature.isShowingPopover == true)

        // After the grace window with no safe-area entry, popover dismisses.
        // (In unit-test geometry the safe area is empty, so the grace timer
        // will dismiss regardless.)
        try? await Task.sleep(nanoseconds: 700_000_000)
        #expect(feature.isShowingPopover == false)
    }

    private func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = firstTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    private func firstMermaidCell(
        in textView: NSTextView
    ) -> MermaidTextAttachmentCell? {
        guard let storage = textView.textStorage else { return nil }
        var found: MermaidTextAttachmentCell?
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, stop in
            guard let attachment = value as? MermaidTextAttachment else {
                return
            }
            found = attachment.mermaidCell
            stop.pointee = true
        }
        return found
    }
}

@MainActor
final class HoverRequestRecorder {
    struct Call: Equatable {
        let uri: String
        let position: LSPPosition
    }

    private(set) var calls: [Call] = []
    private var responses: [LSPHoverResult?] = []

    func record(uri: String, position: LSPPosition) {
        calls.append(Call(uri: uri, position: position))
    }

    func queueResponse(_ response: LSPHoverResult?) {
        responses.append(response)
    }

    func nextResponse() -> LSPHoverResult? {
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }
}

private extension LSPHoverResult {
    static func plainText(_ value: String) -> LSPHoverResult {
        LSPHoverResult(contents: .plain(value), range: nil)
    }

    static func mermaid(_ source: String) -> LSPHoverResult {
        LSPHoverResult(
            contents: .markupContent(
                kind: "markdown",
                value: "```mermaid\n\(source)\n```"
            ),
            range: nil
        )
    }
}
