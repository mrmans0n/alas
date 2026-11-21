import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("ACP command pill")
@MainActor
struct ACPCommandPillTests {
    private let suggestions = [
        ACPPromptSuggestion(command: "/review", description: "Review changes"),
        ACPPromptSuggestion(command: "/brainstorming", description: "Explore intent", hint: "[topic]"),
    ]
    private let font = NSFont.systemFont(ofSize: 13)

    @Test("submitted commands render inline, including at the end, while code and links stay text", arguments: [
        ("please /review and /brainstorming", 2),
        ("please `/review` and [/brainstorming](https://example.com)", 0),
        ("please /reviewer and abc/review", 0),
    ])
    func transcriptCommandChips(text: String, expected: Int) {
        let rendered = ACPMarkdownInlineRenderer.makeAttributedString(
            source: text, theme: Theme(id: "test", name: "Test", tokens: [:]),
            typography: .default, role: .body
        )
        #expect(ACPTranscriptCommandChip.chipify(rendered, suggestions: suggestions) == expected)
        if expected > 0 {
            #expect(ACPUpstreamReferenceChip.plainText(of: rendered) == text)
            var chippedSuggestions: [ACPPromptSuggestion] = []
            rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                if let chip = value as? ACPTranscriptCommandChipAttachment {
                    chippedSuggestions.append(chip.suggestion)
                }
            }
            #expect(chippedSuggestions == suggestions)
        }
    }

    @Test("chipify replaces the leading command and keeps draft and wire text unchanged")
    func chipifyKeepsTextRoundTrip() {
        let storage = NSMutableAttributedString(string: "/review the parser")
        ACPSlashCommand.chipify(storage, suggestions: suggestions, font: font)
        #expect(storage.length == 1 + " the parser".count)
        #expect(storage.attribute(.commandChipName, at: 0, effectiveRange: nil) as? String == "/review")
        #expect(ACPInputField.Coordinator.draft(from: storage).segments == [.text("/review the parser")])
        #expect(ACPInputField.Coordinator.extract(storage).0 == "/review the parser")
    }

    @Test("chipify waits for whitespace after the command and never double-chips")
    func chipifyRequiresTrailingWhitespace() {
        let typing = NSMutableAttributedString(string: "/review")
        ACPSlashCommand.chipify(typing, suggestions: suggestions, font: font)
        #expect(typing.string == "/review")

        let storage = NSMutableAttributedString(string: "/review x /review y")
        ACPSlashCommand.chipify(storage, suggestions: suggestions, font: font)
        let once = storage.length
        #expect(ACPInputField.Coordinator.extract(storage).0 == "/review x /review y")
        ACPSlashCommand.chipify(storage, suggestions: suggestions, font: font)
        #expect(storage.length == once)
    }

    @Test("ghost hint shows after a chipped command followed by a space")
    func ghostHintWithChip() {
        let storage = NSMutableAttributedString(string: "/brainstorming ")
        ACPSlashCommand.chipify(storage, suggestions: suggestions, font: font)
        let end = NSRange(location: storage.length, length: 0)
        #expect(ACPNSTextView.argumentGhostHint(storage: storage, selection: end, suggestions: suggestions) == "[topic]")

        storage.append(NSAttributedString(string: "x"))
        let newEnd = NSRange(location: storage.length, length: 0)
        #expect(ACPNSTextView.argumentGhostHint(storage: storage, selection: newEnd, suggestions: suggestions) == nil)
    }

    @Test("the debounced composer restyle leaves the command chip in place")
    func restyleKeepsChip() {
        let storage = NSTextStorage(string: "/review the parser")
        ACPSlashCommand.chipify(storage, suggestions: suggestions, font: font)
        let typography = ACPChatTypography.default
        let theme = Theme(id: "test", name: "Test", tokens: [:])
        let style = ACPInputField.codeBlockStyle(theme: theme, baseFont: typography.appKitFont(), typography: typography)

        let blocks = MarkdownCodeBlockStyler.restyle(storage, in: nil, style: style).map(\.outerRange)
        ACPMarkdownLiveStyler.restyle(storage, typography: typography, excluding: blocks)

        #expect(storage.attribute(.attachment, at: 0, effectiveRange: nil) is ACPCommandChipAttachment)
        #expect(storage.attribute(.commandChipName, at: 0, effectiveRange: nil) as? String == "/review")
    }

    @Test("ghost hint still works for plain-text commands")
    func ghostHintPlainText() {
        let storage = NSAttributedString(string: "/brainstorming ")
        let end = NSRange(location: storage.length, length: 0)
        #expect(ACPNSTextView.argumentGhostHint(storage: storage, selection: end, suggestions: suggestions) == "[topic]")
    }

    @Test("an image attached before the leading command still lets the pill render")
    func leadingCommandSurvivesImageAtOffsetZero() {
        // Mirrors what ACPUserMessageText.content computes: the leading
        // command is detected against the RAW text first (images
        // contribute no wire text, so it's unaffected either way), then
        // markers are spliced into `rest` only, re-anchored by however many
        // characters the command consumed. An image whose captured offset
        // is 0 in the FULL message — attached before the command was typed
        // — must not corrupt the "/" prefix that `match` looks for.
        let text = "/review the parser"
        let match = ACPSlashCommand.match(in: text, suggestions: suggestions)
        #expect(match?.suggestion.command == "/review")
        let consumed = text.count - (match?.rest.count ?? 0)
        let rest = ACPUserMessageImageMarkers.displayText(
            text: String(match?.rest ?? ""),
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png", textOffset: 0)],
            offsetAdjustment: -consumed
        )
        #expect(rest == "🖼 the parser")
    }
}
