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

        textView.performKeyboardTextInsertion {
            textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

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

        textView.performKeyboardTextInsertion {
            textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "`\u{fffc}`")
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.attachmentURI, at: 1, effectiveRange: nil) as? String == uri)
        #expect(textView.selectedRange() == NSRange(location: 1, length: 1))
    }

    @Test("three backticks fence a mention attachment without losing its URI")
    func tripleBackticksFenceMentionAttachment() throws {
        let uri = "file:///tmp/File.swift"
        let textView = makeChipTextView(attributes: [.attachmentURI: uri])
        let cell = try #require(
            textView.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )

        typeBackticks(3, into: textView)

        #expect(textView.string == "```\n\u{fffc}\n```")
        let storage = try #require(textView.textStorage)
        // The attachment character surviving is not enough — a chip stripped of
        // its `.attachment` cell and `.attachmentURI` is an inert glyph that
        // draws as a placeholder and submits as nothing.
        #expect(storage.attribute(.attachmentURI, at: 4, effectiveRange: nil) as? String == uri)
        #expect(storage.attribute(.attachment, at: 4, effectiveRange: nil) as? NSTextAttachment === cell)
        // …and the fence characters must not inherit the chip's identity.
        #expect(storage.attribute(.attachmentURI, at: 0, effectiveRange: nil) == nil)
        #expect(storage.attribute(.attachmentURI, at: 8, effectiveRange: nil) == nil)
        #expect(textView.selectedRange() == NSRange(location: 4, length: 1))
    }

    @Test("three backticks fence an image chip without losing its URI")
    func tripleBackticksFenceImageAttachment() throws {
        let uri = "file:///tmp/shot.png"
        let textView = makeChipTextView(attributes: [
            .imageAttachmentURI: uri,
            .imageAttachmentMime: "image/png",
        ])
        let cell = try #require(
            textView.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )

        typeBackticks(3, into: textView)

        #expect(textView.string == "```\n\u{fffc}\n```")
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.imageAttachmentURI, at: 4, effectiveRange: nil) as? String == uri)
        #expect(storage.attribute(.imageAttachmentMime, at: 4, effectiveRange: nil) as? String == "image/png")
        #expect(storage.attribute(.attachment, at: 4, effectiveRange: nil) as? NSTextAttachment === cell)
        #expect(storage.attribute(.imageAttachmentURI, at: 0, effectiveRange: nil) == nil)
    }

    @Test("a dead-key third backtick fences a mention attachment without losing its URI")
    func deadKeyTripleBackticksFenceMentionAttachment() throws {
        let uri = "file:///tmp/File.swift"
        let textView = makeChipTextView(attributes: [.attachmentURI: uri])
        let cell = try #require(
            textView.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )

        for _ in 0..<3 {
            textView.typingAttributes = Self.baseTypingAttributes
            textView.setMarkedText(
                "`",
                selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            textView.typingAttributes = Self.baseTypingAttributes
            textView.performKeyboardTextInsertion {
                textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }

        #expect(textView.string == "```\n\u{fffc}\n```")
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.attachmentURI, at: 4, effectiveRange: nil) as? String == uri)
        #expect(storage.attribute(.attachment, at: 4, effectiveRange: nil) as? NSTextAttachment === cell)
        #expect(storage.attribute(.attachmentURI, at: 0, effectiveRange: nil) == nil)
        #expect(textView.selectedRange() == NSRange(location: 4, length: 1))
    }

    /// The attributes `ACPNSTextView.keyDown` installs before every keystroke.
    /// Setting them explicitly keeps a test from passing by accident: AppKit
    /// derives `typingAttributes` from the character next to the selection, so
    /// a chip's own attributes would otherwise be smeared over anything the
    /// editor types on the user's behalf.
    private static let baseTypingAttributes: [NSAttributedString.Key: Any] = [
        .font: ACPChatTypography.default.appKitFont(),
        .foregroundColor: NSColor.labelColor,
    ]

    private func makeChipTextView(attributes: [NSAttributedString.Key: Any]) -> ACPNSTextView {
        let chip = NSMutableAttributedString(attachment: NSTextAttachment())
        chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.markdownFencesEnabled = true
        textView.textStorage?.setAttributedString(chip)
        textView.setSelectedRange(NSRange(location: 0, length: chip.length))
        return textView
    }

    private func typeBackticks(_ count: Int, into textView: ACPNSTextView) {
        for _ in 0..<count {
            textView.typingAttributes = Self.baseTypingAttributes
            textView.performKeyboardTextInsertion {
                textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    @Test("opening delimiter inserts an empty pair")
    func openingDelimiterInsertsEmptyPair() {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))

        textView.performKeyboardTextInsertion {
            textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "()")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test("typing an existing closer steps over it")
    func existingCloserStepsOver() {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.string = "()"
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.performKeyboardTextInsertion {
            textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(textView.string == "()")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }
}
