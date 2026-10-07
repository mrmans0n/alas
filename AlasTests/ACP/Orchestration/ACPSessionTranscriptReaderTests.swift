import Foundation
import Testing
@testable import Alas

@MainActor
struct ACPSessionTranscriptReaderTests {
    private func entries(_ texts: [String]) -> [ACPSessionTranscriptReader.Entry] {
        texts.enumerated().map { .init(index: $0.offset, role: "agent", text: $0.element) }
    }

    @Test("messages become verbatim text entries; tool calls are summarized and thoughts left out")
    func entriesSummarizeTranscript() {
        let messages: [ACPMessage] = [
            .user(id: UUID(), text: "Fix the parser", attachments: []),
            .thought(id: UUID(), StreamingText("private reasoning")),
            .toolCall(.init(toolCallId: "t1", title: "Run tests", status: "completed", content: "huge output", name: "Bash")),
            .fileEdit(id: UUID(), .init(path: "Sources/Parser.swift", added: 3, removed: 1)),
            .agent(id: UUID(), StreamingText("  ")),
            .agent(id: UUID(), StreamingText("    let indented = true\n")),
            .visualAid(ACPVisualAid(
                id: UUID(), title: "Layouts", html: "<h2>secret markup</h2>", question: nil,
                answer: .answered(selectedOptionIds: ["b"], note: nil, at: Date()), createdAt: Date()
            )),
        ]

        let result = ACPSessionTranscriptReader.entries(messages)

        #expect(result.map(\.role) == ["user", "tool", "tool", "agent", "tool"])
        #expect(result.map(\.text) == [
            "Fix the parser", "Bash [completed]", "Edited Sources/Parser.swift (+3 -1)", "    let indented = true\n",
            "visual aid: Layouts (answered: b)",
        ])
        #expect(result.map(\.index) == [0, 1, 2, 3, 4])
    }

    @Test("without an offset the latest entries are read, within both bounds")
    func tailPage() {
        let page = ACPSessionTranscriptReader.page(
            entries(["aaaa", "bbbb", "cccc", "dddd"]), offset: nil, limit: 3, maxChars: 8
        )

        #expect(page.entries.map(\.text) == ["cccc", "dddd"])
        #expect((page.start, page.end, page.total) == (2, 4, 4))
    }

    @Test("an offset reads forward and end continues where the page stopped")
    func forwardPage() {
        let all = entries(["aaaa", "bbbb", "cccc", "dddd"])

        let first = ACPSessionTranscriptReader.page(all, offset: 1, limit: 2, maxChars: 100)
        let next = ACPSessionTranscriptReader.page(all, offset: first.end, limit: 2, maxChars: 100)
        let past = ACPSessionTranscriptReader.page(all, offset: 9, limit: 2, maxChars: 100)

        #expect(first.entries.map(\.text) == ["bbbb", "cccc"])
        #expect(next.entries.map(\.text) == ["dddd"])
        #expect(past.entries.isEmpty && past.start == 4 && past.end == 4)
    }

    @Test("while the session runs, end stays on its last entry so a growing message is read again", arguments: [
        Int?.some(1), nil,
    ])
    func liveLastEntryIsTheResumePoint(offset: Int?) {
        let all = entries(["aaaa", "bbbb", "partial"])

        let live = ACPSessionTranscriptReader.page(all, offset: offset, limit: 5, maxChars: 100, lastEntryIsLive: true)
        let idle = ACPSessionTranscriptReader.page(all, offset: offset, limit: 5, maxChars: 100)

        #expect(live.entries.last?.text == "partial")
        #expect(live.end == 2)
        #expect(idle.end == 3)
    }

    @Test("an entry larger than the budget is cut rather than skipped", arguments: [
        (Int?.some(0), "abc"),
        (Int?.none, "xyz"),
    ])
    func oversizedEntryIsTruncated(offset: Int?, expected: String) {
        let page = ACPSessionTranscriptReader.page(entries(["abcdefxyz"]), offset: offset, limit: 5, maxChars: 3)

        #expect(page.entries.map(\.text) == [expected])
        #expect(page.entries.first?.truncated == true)
    }

    @Test("search is case-insensitive and returns a snippet around the first hit")
    func searchSnippets() {
        let long = String(repeating: "x", count: 100) + " Parser broke\nhere " + String(repeating: "y", count: 100)
        let matches = ACPSessionTranscriptReader.search(entries(["nothing", long, "PARSER ok"]), query: "parser")

        #expect(matches.map(\.index) == [1, 2])
        let snippet = matches.first?.snippet ?? ""
        #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…"))
        #expect(snippet.contains("Parser broke here"))
        #expect(matches.last?.snippet == "PARSER ok")
    }
}
