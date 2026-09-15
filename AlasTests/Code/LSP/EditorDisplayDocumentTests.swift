import AppKit
import Testing
@testable import Alas

@MainActor
struct EditorDisplayDocumentTests {
    private var pair: [EditorDisplayHint] {
        [EditorDisplayHint(id: "first", sourceOffset: 1, label: "x:", size: CGSize(width: 12, height: 16)),
         EditorDisplayHint(id: "second", sourceOffset: 1, label: "type:", size: CGSize(width: 40, height: 16))]
    }

    private func source(_ text: String, rtl: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 84, options: [:])]
        paragraph.defaultTabInterval = 84
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        return NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .paragraphStyle: paragraph])
    }

    @Test func copiesSourceAttributesAndBytesWithoutIntroducingSourceAttachments() throws {
        let original = NSMutableAttributedString(attributedString: source("a🙂\u{FFFC}b"))
        original.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 1, length: 2))
        let snapshot = NSAttributedString(attributedString: original)
        let bytes = Data(original.string.utf8)
        let document = try EditorDisplayDocument(source: original, revision: 4, hints: pair)
        try #require(document.storage.string == "a\u{FFFC}\u{FFFC}🙂\u{FFFC}b")
        #expect(original.isEqual(to: snapshot))
        #expect(Data(original.string.utf8) == bytes)
        #expect(document.storage.attributedSubstring(from: NSRange(location: 0, length: 1)).isEqual(to: original.attributedSubstring(from: NSRange(location: 0, length: 1))))
        // Native font fixing chooses an effective emoji font in display storage.
        // The caller's requested font remains unchanged on the source snapshot.
        #expect(document.storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == .red)
        #expect(document.storage.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle == original.attribute(.paragraphStyle, at: 1, effectiveRange: nil) as? NSParagraphStyle)
        #expect(document.storage.attribute(.attachment, at: 5, effectiveRange: nil) == nil)
        let first = try #require(document.storage.attribute(.attachment, at: 1, effectiveRange: nil) as? EditorHintAttachment)
        let second = try #require(document.storage.attribute(.attachment, at: 2, effectiveRange: nil) as? EditorHintAttachment)
        #expect(first.hint.id == "first")
        #expect(second.hint.id == "second")
        #expect(first.attachmentCell !== second.attachmentCell)
        #expect(first.attachmentCell?.cellSize() == CGSize(width: 12, height: 16))
        #expect(second.attachmentCell?.cellSize() == CGSize(width: 40, height: 16))
    }

    @Test func replacementRetainsStorageIdentityAndRejectsInvalidInputAtomically() throws {
        let document = try EditorDisplayDocument(source: source("ab"), revision: 4, hints: pair)
        let storage = document.storage
        let snapshot = NSAttributedString(attributedString: storage)
        #expect(throws: Error.self) { try document.replace(source: source(""), revision: 5, hints: pair) }
        #expect(document.storage === storage)
        #expect(document.storage.isEqual(to: snapshot))
        #expect(document.map.revision == 4)
        #expect(try document.map.sourceOffset(forDisplay: 4) == 2)
        try document.replace(source: source("🙂"), revision: 6, hints: [])
        #expect(document.storage === storage)
        #expect(document.storage.string == "🙂")
        #expect(document.map.revision == 6)
        #expect(try document.map.sourceOffset(forDisplay: 2) == 2)
    }

    @Test func sortsHintsStablyAndSupportsEmptyDocument() throws {
        let end = EditorDisplayHint(id: "end", sourceOffset: 2, label: "end", size: CGSize(width: 7, height: 9))
        let document = try EditorDisplayDocument(source: source("ab"), revision: 0, hints: [end, pair[1], pair[0]])
        try #require(document.storage.length == 5)
        let ids = [1, 2, 4].map { (document.storage.attribute(.attachment, at: $0, effectiveRange: nil) as? EditorHintAttachment)?.hint.id }
        #expect(ids == ["second", "first", "end"])
        let empty = try EditorDisplayDocument(source: source(""), revision: 0, hints: [])
        #expect(empty.storage.length == 0)
        try empty.replace(source: source(""), revision: 1, hints: [EditorDisplayHint(id: "only", sourceOffset: 0, label: "only", size: CGSize(width: 8, height: 16))])
        #expect(empty.storage.length == 1)
        #expect(try empty.map.sourceOffset(forDisplay: 1) == 0)
    }

    @Test(arguments: ["abcd", "a🙂bc", "אבגד"])
    func nativeGeometryPreservesDistinctWidthsAndSourceOnlyRectangles(text: String) throws {
        let rtl = text == "אבגד"
        let document = try EditorDisplayDocument(source: source(text, rtl: rtl), revision: 0, hints: pair)
        let layout = Layout(document: document)
        let first = layout.rect(NSRange(location: 1, length: 1))
        let second = layout.rect(NSRange(location: 2, length: 1))
        #expect(abs(first.width - 12) < 0.01)
        #expect(abs(second.width - 40) < 0.01)
        #expect(!first.intersects(second))
        let length = text == "a🙂bc" ? 2 : 1
        let segment = try #require(document.map.displaySegments(forSource: NSRange(location: 1, length: length)).first)
        let actual = layout.rect(segment)
        let baseline = try EditorDisplayDocument(source: source(text, rtl: rtl), revision: 0, hints: [])
        let expected = Layout(document: baseline).rect(NSRange(location: 1, length: length))
        #expect(abs(actual.width - expected.width) < 0.01)
        #expect(abs(actual.minX - expected.minX - (rtl ? -52 : 52)) < 0.01)
        #expect(!actual.intersects(first))
        // Hebrew fallback ink overhang also occurs without hints.
        if rtl {
            #expect(first.minX > second.minX)
            #expect(second.minX > actual.minX)
        } else {
            #expect(!actual.intersects(second))
        }
    }

    @Test func nativeTabStopsAndWrappingIncludeAttachmentWidths() throws {
        let hints = pair.map { EditorDisplayHint(id: $0.id, sourceOffset: 1, label: $0.label, size: CGSize(width: 30, height: 16)) }
        let tabs = try EditorDisplayDocument(source: source("a\tb"), revision: 0, hints: hints)
        let tabSegment = try #require(tabs.map.displaySegments(forSource: NSRange(location: 2, length: 1)).first)
        #expect(abs(Layout(document: tabs).rect(tabSegment).minX - 84) < 0.01)
        let wrapped = try EditorDisplayDocument(source: source("abc"), revision: 0, hints: pair)
        let segment = try #require(wrapped.map.displaySegments(forSource: NSRange(location: 2, length: 1)).first)
        #expect(Layout(document: wrapped, width: 60).rect(segment).minY > 0)
    }

    @MainActor
    private struct Layout {
        let manager: NSLayoutManager
        let container: NSTextContainer
        init(document: EditorDisplayDocument, width: CGFloat = 400) {
            _ = NSApplication.shared
            manager = NSLayoutManager()
            container = NSTextContainer(size: CGSize(width: width, height: 1000))
            container.lineFragmentPadding = 0
            document.storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
        }
        func rect(_ range: NSRange) -> NSRect {
            manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        }
    }
}
