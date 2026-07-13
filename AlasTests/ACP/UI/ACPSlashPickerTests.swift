import Testing
@testable import Alas

@MainActor
@Suite("ACP slash picker model")
struct ACPSlashPickerTests {
    @Test("empty query keeps the full (de-duplicated) list in order")
    func emptyQueryKeepsAll() {
        let model = ACPSlashPickerModel(suggestions: [
            .init(command: "/clear", description: "Clear"),
            .init(command: "/init", description: "Init"),
            .init(command: "/review", description: "Review a PR", hint: "<pr>"),
        ])
        #expect(model.query.isEmpty)
        #expect(model.filtered.map(\.command) == ["/clear", "/init", "/review"])
    }

    @Test("filters by prefix/contains/subsequence and ranks best match first")
    func filteringRanks() {
        let model = ACPSlashPickerModel(suggestions: [
            .init(command: "/init", description: nil),
            .init(command: "/clear", description: nil),
            .init(command: "/review", description: nil),
        ])
        model.setQuery("i")
        // "/init" is an exact match (minus slash) and should beat "/review"
        // (subsequence) and outrank everything else.
        #expect(model.filtered.first?.command == "/init")
        // "/review" contains "i" as a subsequence and should still appear.
        #expect(model.filtered.map(\.command).contains("/review"))
        // "/clear" has no "i" at all and must be dropped.
        #expect(!model.filtered.map(\.command).contains("/clear"))
    }

    @Test("setQuery resets the selection cursor to the top")
    func setQueryResetsSelection() {
        let model = ACPSlashPickerModel(suggestions: [
            .init(command: "/a", description: nil),
            .init(command: "/b", description: nil),
        ])
        model.moveDown()
        #expect(model.selectedIndex == 1)
        model.setQuery("a")
        #expect(model.selectedIndex == 0)
        #expect(model.selected()?.command == "/a")
    }

    @Test("de-duplicates commands emitted more than once by the agent")
    func deduplicatesDuplicateCommands() {
        let model = ACPSlashPickerModel(suggestions: [
            .init(command: "/clear", description: "Clear context"),
            .init(command: "/clear", description: "Clear context"),   // exact dup
            .init(command: "/init", description: "Init", hint: "<lang>"),
            .init(command: "/clear", description: "Different desc"),  // same command, kept once
            .init(command: "/init", description: "Init", hint: "<lang>"), // dup of /init
        ])
        // First occurrence wins; later duplicates are dropped, order preserved.
        #expect(model.filtered.map(\.command) == ["/clear", "/init"])
        #expect(model.filtered[0].description == "Clear context")
        #expect(model.filtered[1].hint == "<lang>")
    }

    @Test("arrow keys wrap within the filtered list bounds")
    func arrowKeysClampAndWrap() {
        let model = ACPSlashPickerModel(suggestions: [
            .init(command: "/a", description: nil),
            .init(command: "/b", description: nil),
            .init(command: "/c", description: nil),
        ])
        // Up from index 0 wraps to the last row.
        model.moveUp()
        #expect(model.selectedIndex == 2)
        #expect(model.selected()?.command == "/c")
        model.moveDown()
        #expect(model.selectedIndex == 0)

        // With a filter that leaves one row, movement is a no-op at 0.
        model.setQuery("b")
        #expect(model.filtered.count == 1)
        model.moveDown()
        model.moveUp()
        #expect(model.selectedIndex == 0)
        #expect(model.selected()?.command == "/b")
    }
}
