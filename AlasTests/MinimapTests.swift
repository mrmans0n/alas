import AppKit
import Testing

@testable import Alas

@MainActor
private final class MinimapColorReferenceView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSColor.red.setFill()
        CGRect(x: 14, y: 10, width: 10, height: 10).fill()
        NSColor.blue.setFill()
        CGRect(x: 14, y: 70, width: 10, height: 10).fill()
    }
}

@Suite("Minimap")
struct MinimapTests {
    @Test("Drag release does not navigate twice when the viewport changes")
    @MainActor func dragRelease() throws {
        let view = MinimapView(frame: CGRect(x: 0, y: 0, width: 96, height: 600))
        view.proportion = 0.2
        view.update(drawing: MinimapDrawing(height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        var destinations: [Double] = []
        view.onNavigate = { value in
            destinations.append(value)
            view.proportion = 0.01
            view.value = value * 0.8 / 0.99
        }
        func event(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: 40, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, y: 60))
        view.mouseDragged(with: try event(.leftMouseDragged, y: 300))
        let destination = view.value
        view.mouseUp(with: try event(.leftMouseUp, y: 300))
        #expect(destinations.count == 1)
        #expect(view.value == destination)
    }

    @Test("A detailed minimap click stays put on release and dragging reaches both ends")
    @MainActor func pointerNavigation() throws {
        let view = MinimapView(frame: CGRect(x: 0, y: 0, width: 96, height: 600))
        view.preservesLineScale = true
        view.proportion = 0.1
        view.update(drawing: MinimapDrawing(height: 1500))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        func event(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: 40, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, y: 300))
        let clicked = view.value
        #expect(clicked > 0 && clicked < 0.3)
        view.mouseUp(with: try event(.leftMouseUp, y: 300))
        #expect(view.value == clicked)
        view.mouseDragged(with: try event(.leftMouseDragged, y: 1200))
        #expect(view.value == 1)
        view.mouseDragged(with: try event(.leftMouseDragged, y: -1200))
        #expect(view.value == 0)
    }

    @Test("Editor preview uses actual tab stops and syntax attributes")
    func editorTabs() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 60)]
        let text = NSAttributedString(string: "\tlet x\r\n  return x", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.systemPink,
        ])
        let drawing = MinimapDrawing.editorText(text)
        #expect(drawing.height == 6)
        #expect(try #require(drawing.marks.first).rect.minX > 8)
        #expect(drawing.marks.allSatisfy { $0.color == NSColor.systemPink })
        #expect(drawing.marks.contains { abs($0.rect.minX - 2) < 0.01 && $0.rect.minY == 3 })
    }

    @Test("The cached bitmap preserves top-to-bottom orientation and distinct colors")
    @MainActor func pixels() throws {
        let view = MinimapView(frame: CGRect(x: 0, y: 0, width: 96, height: 100))
        view.backgroundColor = .black
        view.indicatorColor = .clear
        view.update(drawing: MinimapDrawing(marks: [
            .init(rect: CGRect(x: 10, y: 10, width: 10, height: 10), color: .red),
            .init(rect: CGRect(x: 10, y: 70, width: 10, height: 10), color: .blue),
        ], height: 100))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let top = try #require(bitmap.colorAt(x: Int(19 * scale), y: Int(15 * scale))?.usingColorSpace(.sRGB))
        let bottom = try #require(bitmap.colorAt(x: Int(19 * scale), y: Int(75 * scale))?.usingColorSpace(.sRGB))
        let reference = MinimapColorReferenceView(frame: view.frame)
        window.contentView = reference
        let referenceBitmap = try #require(reference.bitmapImageRepForCachingDisplay(in: reference.bounds))
        reference.cacheDisplay(in: reference.bounds, to: referenceBitmap)
        let referenceScale = CGFloat(referenceBitmap.pixelsWide) / reference.bounds.width
        let referenceTop = try #require(referenceBitmap.colorAt(x: Int(19 * referenceScale), y: Int(15 * referenceScale))?.usingColorSpace(.sRGB))
        let referenceBottom = try #require(referenceBitmap.colorAt(x: Int(19 * referenceScale), y: Int(75 * referenceScale))?.usingColorSpace(.sRGB))
        for (actual, expected) in [(top, referenceTop), (bottom, referenceBottom)] {
            #expect(abs(actual.redComponent - expected.redComponent) < 0.02, "\(actual) versus native \(expected)")
            #expect(abs(actual.greenComponent - expected.greenComponent) < 0.02)
            #expect(abs(actual.blueComponent - expected.blueComponent) < 0.02)
        }
        #expect(top.redComponent > top.blueComponent + 0.5)
        #expect(bottom.blueComponent > bottom.redComponent + 0.5)
    }

    @Test("Legacy settings leave both minimaps off")
    func legacyPreferences() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.defaults)) as? [String: Any])
        var code = try #require(object["code"] as? [String: Any])
        var harness = try #require(object["harness"] as? [String: Any])
        code.removeValue(forKey: "showMinimap")
        harness.removeValue(forKey: "acpShowMinimap")
        object["code"] = code
        object["harness"] = harness
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.code.showMinimap)
        #expect(!decoded.harness.acpShowMinimap)
    }

    @Test("Transcript code blocks reuse syntax colors and user bubbles retain their alignment")
    @MainActor func transcriptColors() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let code = ACPTranscriptMinimap.preview(.agent(id: UUID(), StreamingText("```swift\nlet value = 42\n```")), theme: theme)
        let keyword = NSColor(theme.color("syntax-keyword"))
        let number = NSColor(theme.color("mod"))
        #expect(code.marks.contains { $0.color == keyword })
        #expect(code.marks.contains { $0.color == number })
        let user = ACPTranscriptMinimap.preview(.user(id: UUID(), text: "hello", attachments: []), theme: theme)
        #expect(user.marks.allSatisfy { $0.rect.minX >= 24 })
        #expect(user.marks.contains { $0.color == NSColor(theme.color("accent")).withAlphaComponent(0.26) })
    }

    @Test("Transcript previews update for streaming and never carry content between sessions")
    @MainActor func transcriptInvalidation() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let transcript = ACPTranscript()
        let buffer = StreamingText("a")
        transcript.messages = [.agent(id: UUID(), buffer)]
        let renderer = ACPTranscriptMinimap()
        let before = renderer.drawing(transcript: transcript, theme: theme)
        #expect(!renderer.needsUpdate(transcript: transcript, theme: theme))
        buffer.append("bc")
        transcript.streamingTick &+= 1
        let after = renderer.drawing(transcript: transcript, theme: theme)
        #expect(after.marks.count > before.marks.count)
        let second = ACPTranscript()
        second.messages = [.systemNotice(id: UUID(), text: "different session")]
        second.streamingTick = transcript.streamingTick
        #expect(renderer.needsUpdate(transcript: second, theme: theme))
        #expect(renderer.needsUpdate(transcript: transcript, theme: try Theme.loadBundled(id: "light")))
    }

    @Test("Long transcript previews keep fallback marks bounded")
    @MainActor func transcriptPreviewBounded() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let transcript = ACPTranscript()
        transcript.messages = (0..<10_000).map { _ in
            .systemNotice(id: UUID(), text: "message")
        }
        let drawing = ACPTranscriptMinimap().drawing(transcript: transcript, theme: theme)
        #expect(drawing.marks.count < 3_000)
    }

    @Test("Character blocks preserve indentation, gaps, and attributed syntax colors")
    func syntaxBlocks() {
        let text = NSMutableAttributedString(string: "  let x\n\t42\n", attributes: [.foregroundColor: NSColor.white])
        text.addAttribute(.foregroundColor, value: NSColor.systemPink, range: NSRange(location: 2, length: 3))
        let drawing = MinimapDrawing.text(text, columns: 80, tabWidth: 4)
        #expect(drawing.height == 9)
        #expect(drawing.marks.first?.rect.minX == 2)
        #expect(drawing.marks.first?.color == NSColor.systemPink)
        #expect(!drawing.marks.contains { $0.rect.contains(CGPoint(x: 5.5, y: 1)) })
        #expect(drawing.marks.contains { $0.rect.minX == 4 && $0.rect.minY == 3 })
    }

    @Test("CRLF and composed characters retain line and column positions")
    func unicodeBlocks() {
        let drawing = MinimapDrawing.text(NSAttributedString(string: "e\u{301}x\r\ny"), columns: 80)
        #expect(drawing.height == 6)
        #expect(drawing.marks.map(\.rect.minX) == [0, 1, 0])
        #expect(drawing.marks.map(\.rect.minY) == [0, 0, 3])
    }

    @Test("The viewport thumb stays usable for long documents and empty tracks")
    func thumbGeometry() {
        let geometry = MinimapGeometry(height: 400, proportion: 0.001, value: 0.5)
        #expect(geometry.thumb.minY == 192)
        #expect(geometry.thumb.height == 16)
        #expect(MinimapGeometry(height: 0, proportion: 1, value: 1).thumb == CGRect(x: 0, y: 0, width: 96, height: 0))
    }

    @Test("Minimap reserves space without covering the document or scrollbars")
    @MainActor func layout() {
        let scroll = MinimapScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        scroll.tile()
        let originalWidth = scroll.contentView.frame.width
        scroll.showsMinimap = true
        scroll.tile()
        #expect(scroll.contentView.frame.width == originalWidth - MinimapView.width)
        #expect(scroll.verticalScroller!.frame.maxX <= scroll.minimap.frame.minX)
        scroll.tile()
        #expect(scroll.contentView.frame.width == originalWidth - MinimapView.width)
        scroll.showsMinimap = false
        scroll.tile()
        #expect(scroll.contentView.frame.width == originalWidth)
    }

    @Test("Transcript minimap collapses when the chat pane is too narrow")
    @MainActor func transcriptResponsiveVisibility() {
        #expect(!ACPTranscriptScrollerView.shouldShowMinimap(preferred: true, availableWidth: 719))
        #expect(ACPTranscriptScrollerView.shouldShowMinimap(preferred: true, availableWidth: 720))
        #expect(!ACPTranscriptScrollerView.shouldShowMinimap(preferred: false, availableWidth: 1_200))

        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 719, height: 400))
        scroller.minimapPreferred = true
        scroller.layoutSubtreeIfNeeded()
        #expect(!scroller.showsMinimap)
        scroller.setFrameSize(NSSize(width: 720, height: 400))
        scroller.layoutSubtreeIfNeeded()
        #expect(scroller.showsMinimap)
    }

    @Test("Editor and transcript visibility survive independent config round trips")
    func visibilityPersistence() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.defaults)) as? [String: Any])
        for (section, key) in [("code", "showMinimap"), ("harness", "acpShowMinimap")] {
            var settings = try #require(object[section] as? [String: Any])
            settings[key] = true
            object[section] = settings
        }
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: object))
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect((saved["code"] as? [String: Any])?["showMinimap"] as? Bool == true)
        #expect((saved["harness"] as? [String: Any])?["acpShowMinimap"] as? Bool == true)
    }
}
