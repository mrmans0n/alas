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
                    #expect(chip.image != nil)
                }
            }
            #expect(chippedSuggestions == suggestions)
        }
    }

    @Test("matches a known leading command and returns the rest")
    func matchesLeadingCommand() {
        let match = ACPSlashCommand.match(in: "/review the parser", suggestions: suggestions)
        #expect(match?.suggestion.command == "/review")
        #expect(match?.rest == "the parser")
        #expect(ACPSlashCommand.match(in: "/review", suggestions: suggestions)?.rest == "")
    }

    @Test("ignores unknown, partial, and non-leading commands")
    func ignoresNonMatches() {
        #expect(ACPSlashCommand.match(in: "/reviewer x", suggestions: suggestions) == nil)
        #expect(ACPSlashCommand.match(in: "/tmp is full", suggestions: suggestions) == nil)
        #expect(ACPSlashCommand.match(in: "please /review", suggestions: suggestions) == nil)
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

    @Test("chip targets are known commands on token boundaries, outside code", arguments: [
        ("/review x", ["/review"]),
        ("please /review x and /brainstorming\n", ["/review", "/brainstorming"]),
        ("a\n/review\tb", ["/review"]),
        ("abc/review x", []),
        ("/review/x y", []),
        ("please /review", []),
        ("run `/review x` now", []),
        ("```\n/review x\n```\n", []),
        ("```\n/review x\n", []),
    ])
    func chipTargets(text: String, expected: [String]) {
        #expect(ACPSlashCommand.chipTargets(in: text, suggestions: suggestions).map(\.command) == expected)
    }

    @Test("typing whitespace completes a command anywhere, but not inside open code", arguments: [
        ("/review", "/review"),
        ("please /review", "/review"),
        ("please/review", nil),
        ("please `/review", nil),
        ("please `example /review", nil),
        ("```\n/review", nil),
    ] as [(String, String?)])
    func keystrokeChipTarget(text: String, expected: String?) {
        let storage = NSAttributedString(string: text)
        let target = ACPSlashCommand.chipTarget(
            completingWith: " ", at: NSRange(location: storage.length, length: 0),
            in: storage, suggestions: suggestions
        )
        #expect(target?.command == expected)
    }

    @Test("a pasted command chips only when its destination is a boundary outside code", arguments: [
        ("hi ", "", true),
        ("hi", "", false),
        ("run ` ", " now`", false),
        ("```\n", "\n```\n", false),
    ])
    func pasteChipify(before: String, after: String, chips: Bool) {
        let storage = NSAttributedString(string: before + after)
        let fragment = NSMutableAttributedString(string: "/review x")
        let range = NSRange(location: (before as NSString).length, length: 0)
        #expect(ACPSlashCommand.chipify(
            fragment, replacing: range, in: storage, suggestions: suggestions, font: font
        ) == chips)
        #expect(ACPInputField.Coordinator.extract(fragment).0 == "/review x")
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

    @Test("a leading command keeps a newline-delimited body intact in rest")
    func matchPreservesNewlinesAfterCommand() {
        let match = ACPSlashCommand.match(in: "/review\n\n# Results", suggestions: suggestions)
        #expect(match?.rest == "\n\n# Results")
    }

    @Test("only the single separating space is stripped, not repeated whitespace")
    func matchStripsExactlyOneSeparatingSpace() {
        #expect(ACPSlashCommand.match(in: "/review the parser", suggestions: suggestions)?.rest == "the parser")
        #expect(ACPSlashCommand.match(in: "/review\tthe parser", suggestions: suggestions)?.rest == "\tthe parser")
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
