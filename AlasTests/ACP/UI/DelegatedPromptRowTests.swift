import Testing
@testable import Alas

@Suite("Delegated prompt folding")
struct DelegatedPromptRowTests {
    @Test("long prompts fold and report their raw line count", arguments: [
        ("Implement the linked issue.", nil),
        ("\n\n  short  \n\n", nil),
        (Array(repeating: "line", count: 12).joined(separator: "\n"), nil),
        (Array(repeating: "line", count: 13).joined(separator: "\n"), 13),
        (Array(repeating: "line", count: 13).joined(separator: "\r\n"), 13),
        (String(repeating: "a", count: 900), nil),
        (String(repeating: "a", count: 901), 1),
        ("  " + String(repeating: "a", count: 900) + "\n\n", nil)
    ] as [(String, Int?)])
    func foldedLineCount(text: String, expected: Int?) {
        #expect(DelegatedPromptRow.foldedLineCount(for: text) == expected)
    }

    @Test("a folded prompt mounts only its first lines, never the hidden tail", arguments: [
        (Array(repeating: "line", count: 13).joined(separator: "\n"), Array(repeating: "line", count: 8).joined(separator: "\n")),
        ("\n  first\nsecond\n\n", "first\nsecond"),
        (String(repeating: "a", count: 901), String(repeating: "a", count: 640))
    ] as [(String, String)])
    func foldedPreview(text: String, expected: String) {
        #expect(DelegatedPromptRow.foldedPreview(of: text) == expected)
    }
}
