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

    @Test("matches a known leading command and returns the rest")
    func matchesLeadingCommand() {
        let match = ACPLeadingCommand.match(in: "/review the parser", suggestions: suggestions)
        #expect(match?.suggestion.command == "/review")
        #expect(match?.rest == "the parser")
        #expect(ACPLeadingCommand.match(in: "/review", suggestions: suggestions)?.rest == "")
    }

    @Test("ignores unknown, partial, and non-leading commands")
    func ignoresNonMatches() {
        #expect(ACPLeadingCommand.match(in: "/reviewer x", suggestions: suggestions) == nil)
        #expect(ACPLeadingCommand.match(in: "/tmp is full", suggestions: suggestions) == nil)
        #expect(ACPLeadingCommand.match(in: "please /review", suggestions: suggestions) == nil)
    }

    @Test("chipify replaces the leading command and keeps draft and wire text unchanged")
    func chipifyKeepsTextRoundTrip() {
        let storage = NSMutableAttributedString(string: "/review the parser")
        ACPLeadingCommand.chipify(storage, suggestions: suggestions, font: font)
        #expect(storage.length == 1 + " the parser".count)
        #expect(storage.attribute(.commandChipName, at: 0, effectiveRange: nil) as? String == "/review")
        #expect(ACPInputField.Coordinator.draft(from: storage).segments == [.text("/review the parser")])
        #expect(ACPInputField.Coordinator.extract(storage).0 == "/review the parser")
    }

    @Test("chipify waits for whitespace after the command and never double-chips")
    func chipifyRequiresTrailingWhitespace() {
        let typing = NSMutableAttributedString(string: "/review")
        ACPLeadingCommand.chipify(typing, suggestions: suggestions, font: font)
        #expect(typing.string == "/review")

        let storage = NSMutableAttributedString(string: "/review x")
        ACPLeadingCommand.chipify(storage, suggestions: suggestions, font: font)
        let once = storage.length
        ACPLeadingCommand.chipify(storage, suggestions: suggestions, font: font)
        #expect(storage.length == once)
    }

    @Test("ghost hint shows after a chipped command followed by a space")
    func ghostHintWithChip() {
        let storage = NSMutableAttributedString(string: "/brainstorming ")
        ACPLeadingCommand.chipify(storage, suggestions: suggestions, font: font)
        let end = NSRange(location: storage.length, length: 0)
        #expect(ACPNSTextView.argumentGhostHint(storage: storage, selection: end, suggestions: suggestions) == "[topic]")

        storage.append(NSAttributedString(string: "x"))
        let newEnd = NSRange(location: storage.length, length: 0)
        #expect(ACPNSTextView.argumentGhostHint(storage: storage, selection: newEnd, suggestions: suggestions) == nil)
    }

    @Test("the debounced composer restyle leaves the command chip in place")
    func restyleKeepsChip() {
        let storage = NSTextStorage(string: "/review the parser")
        ACPLeadingCommand.chipify(storage, suggestions: suggestions, font: font)
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
        let match = ACPLeadingCommand.match(in: "/review\n\n# Results", suggestions: suggestions)
        #expect(match?.rest == "\n\n# Results")
    }

    @Test("only the single separating space is stripped, not repeated whitespace")
    func matchStripsExactlyOneSeparatingSpace() {
        #expect(ACPLeadingCommand.match(in: "/review the parser", suggestions: suggestions)?.rest == "the parser")
        #expect(ACPLeadingCommand.match(in: "/review\tthe parser", suggestions: suggestions)?.rest == "\tthe parser")
    }
}
