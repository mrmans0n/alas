import AppKit
import Testing
@testable import Alas

@MainActor
struct EditorDisplayDocumentTests {
    @Test func hintRefreshPreservesLayoutBeforeTheHintExtent() throws {
        let text = source(String(repeating: "let value = 123\n", count: 10000))
        let document = try EditorDisplayDocument(source: text, revision: 0, hints: [])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 800, height: 1e7))
        manager.addTextContainer(container)
        document.storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let offset = text.length * 3 / 4
        let hint = EditorDisplayHint(id: "hint", sourceOffset: offset, label: ": Int", size: CGSize(width: 35, height: 14))
        try document.replaceHints(source: text, revision: 0, hints: [hint])
        // A full storage replacement invalidates layout from zero. Keep the
        // already laid-out prefix when a viewport receives fresh LSP hints.
        #expect(manager.firstUnlaidCharacterIndex() >= offset - 16)
        #expect(document.storage.string == (text.string as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: "\u{FFFC}"))
        manager.ensureLayout(for: container)
        try document.replaceHints(source: text, revision: 0, hints: [])
        #expect(manager.firstUnlaidCharacterIndex() >= offset - 16)
        #expect(document.storage.string == text.string)
    }

    @Test func incrementalHintRefreshMatchesFullAssembly() throws {
        for text in ["", "a🙂\tb\nאבגד\n", "plain source"] {
            let original = source(text)
            let document = try EditorDisplayDocument(source: original, revision: 4, hints: [])
            let start = EditorDisplayHint(id: "start", sourceOffset: 0, label: "x:", size: CGSize(width: 12, height: 16))
            let second = EditorDisplayHint(id: "second", sourceOffset: 0, label: "y:", size: CGSize(width: 20, height: 16))
            let end = EditorDisplayHint(id: "end", sourceOffset: original.length, label: ": Int", size: CGSize(width: 40, height: 16))
            for hints in [[start], [end, second, start], [end], [], [], [second, start], []] {
                try document.replaceHints(source: original, revision: 4, hints: hints)
                let expected = try EditorDisplayDocument(source: original, revision: 4, hints: hints)
                #expect(document.storage.string == expected.storage.string)
                #expect(document.map.hintRuns.map(\.hint) == expected.map.hintRuns.map(\.hint))
                for index in 0..<document.storage.length {
                    var actualAttributes = document.storage.attributes(at: index, effectiveRange: nil)
                    var expectedAttributes = expected.storage.attributes(at: index, effectiveRange: nil)
                    let actualHint = actualAttributes.removeValue(forKey: .attachment) as? EditorHintAttachment
                    let expectedHint = expectedAttributes.removeValue(forKey: .attachment) as? EditorHintAttachment
                    #expect(actualHint?.hint == expectedHint?.hint)
                    #expect(NSDictionary(dictionary: actualAttributes).isEqual(to: expectedAttributes))
                }
            }
        }
    }

    @Test func hintRefreshRejectsInvalidHintsWithoutMutatingStorage() throws {
        let original = source("a🙂b")
        let document = try EditorDisplayDocument(source: original, revision: 4, hints: pair)
        let snapshot = NSAttributedString(attributedString: document.storage)
        let invalid = EditorDisplayHint(id: "invalid", sourceOffset: 2, label: "x", size: CGSize(width: 10, height: 10))
        #expect(throws: EditorDisplayMapError.self) {
            try document.replaceHints(source: original, revision: 4, hints: [invalid])
        }
        #expect(document.storage.isEqual(to: snapshot))
        #expect(document.map.hintRuns.map(\.hint) == pair)
    }

    @Test func incrementalLineStartsHandleInsertionDeletionAndBoundaryEdits() {
        let starts = [0, 3, 6] // "ab\ncd\n"
        let cases: [(EditorTextEdit, [Int])] = [
            (.init(location: 1, oldLength: 0, replacementText: "x"), [0, 4, 7]),
            (.init(location: 1, oldLength: 3, replacementText: ""), [0, 3]),
            (.init(location: 1, oldLength: 4, replacementText: "\nX\n"), [0, 2, 4, 5]),
            (.init(location: 3, oldLength: 0, replacementText: "x\n"), [0, 3, 5, 8]),
            (.init(location: 5, oldLength: 1, replacementText: ""), [0, 3]),
            (.init(location: 0, oldLength: 6, replacementText: ""), [0]),
            (.init(location: 1, oldLength: 0, replacementText: "🙂\n"), [0, 4, 6, 9]),
            (.init(location: 1, oldLength: 1, replacementText: "x"), [0, 3, 6])
        ]
        for (edit, expected) in cases {
            #expect(EditorDisplayAdapter.applying(edit, toLineStarts: starts) == expected)
        }
        #expect(EditorDisplayAdapter.applying(.init(location: 0, oldLength: 0, replacementText: "\n"), toLineStarts: [0]) == [0, 1])
        // Removing the CR from "a\r\nb" shifts the next line without removing it.
        #expect(EditorDisplayAdapter.applying(.init(location: 1, oldLength: 1, replacementText: ""), toLineStarts: [0, 3]) == [0, 2])
    }

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

    @Test(arguments: ["insert", "replace", "delete"])
    func committedSourceEditsPreserveExactUnicodeAndStorageIdentity(operation: String) throws {
        let document = try EditorDisplayDocument(source: source("a🙂b"), revision: 3, hints: [])
        let storage = document.storage
        let edit: EditorTextEdit
        let expected: String
        switch operation {
        case "insert":
            edit = .init(location: 1, oldLength: 0, replacementText: "X")
            expected = "aX🙂b"
        case "replace":
            edit = .init(location: 1, oldLength: 2, replacementText: "e\u{301}")
            expected = "ae\u{301}b"
        default:
            edit = .init(location: 1, oldLength: 2, replacementText: "")
            expected = "ab"
        }
        #expect(document.applySourceEdit(edit, source: source(expected), revision: 4))
        #expect(document.storage === storage)
        #expect(Array(storage.string.utf16) == Array(expected.utf16))
        #expect(document.map.revision == 4)
        #expect(document.map.sourceLength == (expected as NSString).length)
    }

    @Test func invalidSourceEditsLeaveDisplayAndRevisionUnchanged() throws {
        let original = source("a🙂b")
        let document = try EditorDisplayDocument(source: original, revision: 3, hints: [])
        let snapshot = NSAttributedString(attributedString: document.storage)
        let valid = EditorTextEdit(location: 1, oldLength: 2, replacementText: "X")
        #expect(!document.applySourceEdit(valid, source: source("aXb"), revision: 5))
        #expect(!document.applySourceEdit(valid, source: source("aYb"), revision: 4))
        #expect(!document.applySourceEdit(.init(location: 2, oldLength: 0, replacementText: "X"), source: source("aX🙂b"), revision: 4))
        #expect(!document.applySourceEdit(.init(location: 1, oldLength: 20, replacementText: "X"), source: source("aXb"), revision: 4))
        #expect(document.storage.isEqual(to: snapshot))
        #expect(document.map.revision == 3)
        let hinted = try EditorDisplayDocument(source: original, revision: 3, hints: pair)
        #expect(!hinted.applySourceEdit(valid, source: source("aXb"), revision: 4))
        #expect(hinted.storage.string == "a\u{FFFC}\u{FFFC}🙂b")
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

    @Test func paintRemovalCrossesHintsWithoutStylingOrReplacingAttachments() throws {
        let original = NSMutableAttributedString(attributedString: source("abcd"))
        original.addAttributes([.foregroundColor: NSColor.red, .underlineStyle: 1], range: NSRange(location: 0, length: 4))
        let document = try EditorDisplayDocument(source: original, revision: 4, hints: pair)
        let attachment = document.storage.attribute(.attachment, at: 1, effectiveRange: nil) as? EditorHintAttachment
        original.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: 3))
        original.addAttribute(.foregroundColor, value: NSColor.blue, range: NSRange(location: 0, length: 3))
        #expect(document.updatePaintAttributes(source: original, revision: 4, range: NSRange(location: 0, length: 3)))
        for offset in [0, 3, 4] {
            #expect(document.storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor == .blue)
            #expect(document.storage.attribute(.underlineStyle, at: offset, effectiveRange: nil) == nil)
        }
        #expect(document.storage.attribute(.underlineStyle, at: 5, effectiveRange: nil) as? Int == 1)
        #expect(document.storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) == nil)
        #expect(document.storage.attribute(.attachment, at: 1, effectiveRange: nil) as? EditorHintAttachment === attachment)
        #expect(document.storage.string == "a\u{FFFC}\u{FFFC}bcd")
    }

    @Test func paintUpdateRefusesMixedLayoutChangesBeforeMutatingAnyRun() throws {
        let original = NSMutableAttributedString(attributedString: source("abcd"))
        let document = try EditorDisplayDocument(source: original, revision: 4, hints: pair)
        let snapshot = NSAttributedString(attributedString: document.storage)
        original.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
        original.addAttribute(.font, value: NSFont.systemFont(ofSize: 30), range: NSRange(location: 2, length: 1))
        #expect(!document.updatePaintAttributes(source: original, revision: 4, range: NSRange(location: 0, length: 4)))
        #expect(document.storage.isEqual(to: snapshot))
        #expect(!document.updatePaintAttributes(source: original, revision: 5, range: NSRange(location: 0, length: 1)))
        #expect(!document.updatePaintAttributes(source: original, revision: 4, range: NSRange(location: 3, length: 2)))
        #expect(document.storage.isEqual(to: snapshot))
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
