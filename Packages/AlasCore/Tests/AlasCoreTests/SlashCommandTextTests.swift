import Foundation
import Testing
@testable import AlasCore

@Suite("Slash command text")
struct SlashCommandTextTests {
    private let commands = ["/review", "/brainstorming"]

    @Test("matches a known leading command and returns the rest")
    func matchesLeadingCommand() {
        let match = SlashCommandText.match(in: "/review the parser", commands: commands)
        #expect(match?.command == "/review")
        #expect(match?.rest == "the parser")
        #expect(SlashCommandText.match(in: "/review", commands: commands)?.rest == "")
    }

    @Test("ignores unknown, partial, and non-leading commands")
    func ignoresNonMatches() {
        #expect(SlashCommandText.match(in: "/reviewer x", commands: commands) == nil)
        #expect(SlashCommandText.match(in: "/tmp is full", commands: commands) == nil)
        #expect(SlashCommandText.match(in: "please /review", commands: commands) == nil)
    }

    @Test("a leading command keeps a newline-delimited body intact in rest")
    func matchPreservesNewlinesAfterCommand() {
        #expect(SlashCommandText.match(in: "/review\n\n# Results", commands: commands)?.rest == "\n\n# Results")
    }

    @Test("only the single separating space is stripped, not repeated whitespace")
    func matchStripsExactlyOneSeparatingSpace() {
        #expect(SlashCommandText.match(in: "/review the parser", commands: commands)?.rest == "the parser")
        #expect(SlashCommandText.match(in: "/review\tthe parser", commands: commands)?.rest == "\tthe parser")
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
        #expect(SlashCommandText.chipTargets(in: text, commands: commands).map(\.command) == expected)
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
        let target = SlashCommandText.chipTarget(
            completingWith: " ", at: NSRange(location: (text as NSString).length, length: 0),
            in: text, commands: commands
        )
        #expect(target?.command == expected)
    }

    @Test("a pasted command chips only when its destination is a boundary outside code", arguments: [
        ("hi ", "", true),
        ("hi", "", false),
        ("run ` ", " now`", false),
        ("```\n", "\n```\n", false),
    ])
    func pasteTargets(before: String, after: String, chips: Bool) {
        let targets = SlashCommandText.chipTargets(
            inFragment: "/review x", replacing: NSRange(location: (before as NSString).length, length: 0),
            in: before + after, commands: commands)
        #expect(targets.map(\.range) == (chips ? [NSRange(location: 0, length: 7)] : []))
    }
}
