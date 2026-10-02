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
        (String(repeating: "a", count: 901), 1)
    ] as [(String, Int?)])
    func foldedLineCount(text: String, expected: Int?) {
        #expect(DelegatedPromptRow.foldedLineCount(for: text) == expected)
    }
}
