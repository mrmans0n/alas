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
    func privateKeyBlocksAreRedactedWithoutShiftingLineNumbers() throws {
        let log = """
        loading deploy key
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ
        -----END OPENSSH PRIVATE KEY-----
        fatal: could not read from remote repository
        """

        let excerpt = try #require(FailureLogSelection.select(log))

        #expect(excerpt.lines.map(\.number) == [4, 5])
        #expect(excerpt.lines[0].text == "[redacted private key]")
        #expect(excerpt.lines.allSatisfy { !LocalTextSafety.containsCredential($0.text) })
    }

    @Test
    func outputWithoutErrorMarkersFallsBackToItsFinalLines() throws {
        let log = (1...30).map { "step \($0)" }.joined(separator: "\n") + "\n\n"

        let excerpt = try #require(FailureLogSelection.select(log))

        #expect(!excerpt.matchedErrors)
        #expect(excerpt.lines.map(\.number) == Array(16...30))
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
