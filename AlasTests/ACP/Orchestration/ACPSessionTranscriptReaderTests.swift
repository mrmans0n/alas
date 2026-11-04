import Foundation
import Testing
@testable import Alas

@MainActor
struct ACPSessionTranscriptReaderTests {
    private func entries(_ texts: [String]) -> [ACPSessionTranscriptReader.Entry] {
        texts.enumerated().map { .init(index: $0.offset, role: "agent", text: $0.element) }
    }

    @Test("messages become verbatim text entries; tool calls are summarized, plans read as agent text, and thoughts left out")
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
            .plan(id: UUID(), [.init(content: "checklist step", status: "pending")]),
            .planDocument(id: UUID(), .markdownFixture),
            .planDocument(id: UUID(), .fileFixture),
            .planDocument(id: UUID(), .hiddenFixture),
        ]

        let result = ACPSessionTranscriptReader.entries(messages)

        #expect(result.map(\.role) == ["user", "tool", "tool", "agent", "tool", "agent", "agent", "system"])
        #expect(result.map(\.text) == [
            "Fix the parser", "Bash [completed]", "Edited Sources/Parser.swift (+3 -1)", "    let indented = true\n",
            "visual aid: Layouts (answered: b)", "# Plan", "Plan file: /p.md", "Plan removed.",
        ])
        #expect(result.map(\.index) == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    private func incident(
        title: String = "Model overloaded", details: String? = nil, revision: Int = 1, severity: String = "error",
        kind: String? = nil, endedTurn: Bool = false
    ) throws -> ACPMessage {
        let record = try ACPSessionFailureRecord.fixture(
            revision: revision, title: title, severity: severity, details: details, kind: kind)
        return .failureIncident(id: UUID(), ACPFailureIncident(record: record, endedTurn: endedTurn))
    }

    @Test("a failure incident reads as a system entry, keeps its slot across revisions and is not agent text")
    func failureIncidentReadsAsSystem() throws {
        let answer = ACPMessage.agent(id: UUID(), StreamingText("Partial."))
        let later = ACPMessage.user(id: UUID(), text: "Again", attachments: [])
        let first = try incident(details: "Try later.")
        let revised = try incident(title: "Still overloaded", revision: 2)

        let entries = ACPSessionTranscriptReader.entries([answer, first, later])

        #expect(entries.map(\.role) == ["agent", "system", "user"])
        #expect(entries[1].text == "Model overloaded\n\nTry later.")
        #expect(ACPSessionTranscriptReader.entries([answer, revised, later]).map(\.index) == entries.map(\.index))
        #expect(ACPSessionTranscriptReader.lastAgentText([answer, first]) == "Partial.")
    }

    enum TrailingFailure: CaseIterable {
        case endedTurnError, backgroundErrorAfterSuccess, warning, usageLimit, olderFailureThenNewTurn, noIncident
    }

    @Test(arguments: TrailingFailure.allCases)
    func trailingTurnFailure(_ row: TrailingFailure) throws {
        let user = ACPMessage.user(id: UUID(), text: "Fix it", attachments: [])
        let answer = ACPMessage.agent(id: UUID(), StreamingText("Done."))
        let messages: [ACPMessage]
        var expected: String?
        switch row {
        case .endedTurnError:
            // Text after the incident is the same turn's: only a user row starts another.
            messages = [user, try incident(details: "Try later.", endedTurn: true), answer]
            expected = "Model overloaded"
        case .backgroundErrorAfterSuccess:
            messages = [user, answer, try incident()]
        case .warning:
            messages = [user, try incident(severity: "warning", endedTurn: true)]
        case .usageLimit:
            messages = [user, try incident(kind: ACPSessionFailureRecord.quotaExhaustedKind, endedTurn: true)]
        case .olderFailureThenNewTurn:
            messages = [user, try incident(endedTurn: true), user, answer]
        case .noIncident:
            messages = [user, answer]
        }

        #expect(ACPSessionTranscriptReader.trailingTurnFailure(messages) == expected)
    }

    @Test("hiding a plan between paged reads keeps later entries at their offsets")
    func hiddenPlanKeepsReadOffsets() {
        let user = ACPMessage.user(id: UUID(), text: "Plan it", attachments: [])
        let tool = ACPMessage.toolCall(.init(toolCallId: "t1", title: "Read", status: "completed", content: "", name: "Read"))
        let answer = ACPMessage.agent(id: UUID(), StreamingText("Answer"))
        let before = ACPSessionTranscriptReader.entries([user, .planDocument(id: UUID(), .markdownFixture), tool, answer])
        let after = ACPSessionTranscriptReader.entries([user, .planDocument(id: UUID(), .hiddenFixture), tool, answer])

        #expect(after.map(\.text)[2...] == before.map(\.text)[2...])
    }

    @Test("the last agent text is the latest agent message or shown plan")
    func lastAgentTextIncludesPlans() {
        func last(_ messages: ACPMessage...) -> String? { ACPSessionTranscriptReader.lastAgentText(messages) }
        let planning = ACPMessage.agent(id: UUID(), StreamingText("Planning."))

        #expect(last(planning, .planDocument(id: UUID(), .markdownFixture)) == "# Plan")
        #expect(last(.planDocument(id: UUID(), .markdownFixture), .agent(id: UUID(), StreamingText("Done."))) == "Done.")
        #expect(last(planning, .planDocument(id: UUID(), .hiddenFixture)) == "Planning.")
        #expect(last(.planDocument(id: UUID(), .fileFixture)) == "Plan file: /p.md")
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
