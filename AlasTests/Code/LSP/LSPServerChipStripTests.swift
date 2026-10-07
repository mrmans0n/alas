import Testing
@testable import Alas

struct ChipAggregationCase: Sendable, CustomTestStringConvertible {
    let name: String
    let input: [LSPChipSnapshot]
    let orderedIDs: [String]
    let presentation: LSPServerChipAggregation.Presentation
    var testDescription: String { name }
}

private func snap(_ id: String, _ language: String, _ root: String = "/repo", _ severity: LSPChipSeverity = .ready) -> LSPChipSnapshot {
    LSPChipSnapshot(id: id, language: language, root: root, severity: severity)
}

@Suite("LSPServerChipAggregation")
struct LSPServerChipStripTests {
    @Test("server details default to expanded through eight entries", arguments: [(8, true), (9, false)])
    func defaultExpansion(count: Int, expanded: Bool) {
        #expect(LSPServerChipAggregation.isExpandedByDefault(count: count) == expanded)
    }

    @Test("chips dedupe, sort, and collapse past the inline limit", arguments: [
        ChipAggregationCase(
            name: "dedupes by id and sorts by language then root",
            input: [snap("r2", "rust", "/repo/b"), snap("s1", "swift"), snap("r1", "rust", "/repo/a", .loading), snap("s1", "swift")],
            orderedIDs: ["r1", "r2", "s1"],
            presentation: .inline
        ),
        ChipAggregationCase(
            name: "three servers stay inline even with a problem",
            input: [snap("a", "go", "/r", .problem), snap("b", "rust"), snap("c", "swift")],
            orderedIDs: ["a", "b", "c"],
            presentation: .inline
        ),
        ChipAggregationCase(
            name: "four servers collapse and a problem outranks loading",
            input: [snap("a", "go"), snap("b", "kotlin", "/r", .loading), snap("c", "rust", "/r", .problem), snap("d", "swift")],
            orderedIDs: ["a", "b", "c", "d"],
            presentation: .summary(ready: 2, total: 4, worst: .problem)
        ),
        ChipAggregationCase(
            name: "loading outranks ready in the summary",
            input: [snap("a", "go"), snap("b", "kotlin"), snap("c", "rust", "/r", .loading), snap("d", "swift")],
            orderedIDs: ["a", "b", "c", "d"],
            presentation: .summary(ready: 3, total: 4, worst: .loading)
        ),
    ])
    func aggregation(_ testCase: ChipAggregationCase) {
        let ordered = LSPServerChipAggregation.ordered(testCase.input)
        #expect(ordered.map(\.id) == testCase.orderedIDs)
        #expect(LSPServerChipAggregation.presentation(ordered) == testCase.presentation)
    }
}
