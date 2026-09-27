import Testing
@testable import Alas

struct FailureLogSelectionTests {
    @Test
    func selectsErrorClustersWithContextAndOriginalLineNumbers() throws {
        let log = """
        Compiling Foo.swift
        Compiling Bar.swift
        Sources/Bar.swift:12:5: error: cannot find 'baz' in scope
            baz()
        Compiling Qux.swift
        Linking
        Tests passed: 10
        Test Suite 'Net' FAILED
        Done
        """

        let excerpt = try #require(FailureLogSelection.select(log))

        #expect(excerpt.matchedErrors)
        #expect(!excerpt.truncated)
        #expect(excerpt.lines.map(\.number) == [2, 3, 4, 7, 8, 9])
        #expect(excerpt.lines[1].text == "Sources/Bar.swift:12:5: error: cannot find 'baz' in scope")
    }

    @Test
    func alreadyTruncatedOutputMarksTheExcerptTruncated() throws {
        let excerpt = try #require(FailureLogSelection.select("error: boom", inputTruncated: true))

        #expect(excerpt.truncated)
    }

    @Test
    func outputWithoutErrorMarkersFallsBackToItsFinalLines() throws {
        let log = (1...30).map { "step \($0)" }.joined(separator: "\n") + "\n\n"

        let excerpt = try #require(FailureLogSelection.select(log))

        #expect(!excerpt.matchedErrors)
        #expect(excerpt.lines.map(\.number) == Array(16...30))
        #expect(excerpt.truncated)
    }

    @Test
    func manyErrorsKeepTheLastMatchesAndLongLinesAreCapped() throws {
        let long = "TypeError: " + String(repeating: "x", count: 5_000)
        let log = (1...100).map { "error: failure \($0)" }.joined(separator: "\n") + "\n" + long

        let excerpt = try #require(FailureLogSelection.select(log))

        #expect(excerpt.truncated)
        #expect(excerpt.lines.count == FailureLogSelection.maximumLines)
        #expect(excerpt.lines.last?.number == 101)
        #expect(excerpt.lines.allSatisfy { $0.text.count <= FailureLogSelection.maximumLineLength })
    }

    @Test(arguments: ["", "\n\n", "   \n\t\n"])
    func blankOutputHasNoExcerpt(output: String) {
        #expect(FailureLogSelection.select(output) == nil)
    }
}
