import AppKit
import Testing
@testable import Alas

@Suite("ACP composer paired delimiters")
@MainActor
struct ACPComposerPairedDelimiterTests {
    @Test("backticks wrap selected styled text without losing attributes")
    func backticksWrapStyledSelection() throws {
        let customAttribute = NSAttributedString.Key("alas.tests.customStyle")
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "value",
            attributes: [customAttribute: "keep-me"]
        ))
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "`value`")
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(customAttribute, at: 1, effectiveRange: nil) as? String == "keep-me")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 5))
    }

    @Test("backticks wrap a mention attachment without losing its URI")
    func backticksWrapMentionAttachment() throws {
        let uri = "file:///tmp/File.swift"
        let attachment = NSMutableAttributedString(attachment: NSTextAttachment())
        attachment.addAttribute(.attachmentURI, value: uri, range: NSRange(location: 0, length: 1))
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.textStorage?.setAttributedString(attachment)
        textView.setSelectedRange(NSRange(location: 0, length: 1))

        textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "`\u{fffc}`")
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.attachmentURI, at: 1, effectiveRange: nil) as? String == uri)
        #expect(textView.selectedRange() == NSRange(location: 1, length: 1))
    }

    @Test("opening delimiter inserts an empty pair")
    func openingDelimiterInsertsEmptyPair() {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))

        textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "()")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test("typing an existing closer steps over it")
    func existingCloserStepsOver() {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.string = "()"
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.string == "()")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }
}
