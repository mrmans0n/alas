import Foundation
import Testing
@testable import Alas

@Suite("ACP mention picker")
struct ACPMentionPickerTests {
    @Test("ranks fuzzy basename and path matches with shared scorer")
    func ranksFuzzyBasenameAndPathMatches() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let files = [
            root.appendingPathComponent("docs/build-notes.md"),
            root.appendingPathComponent(".github/workflows/build.yml"),
            root.appendingPathComponent(".github/workflows/nightly.yml"),
            root.appendingPathComponent("Sources/ACP/UI/ACPComposer.swift"),
        ]

        let basenameMatches = MentionFuzzy.rank(files: files, query: "byml", limit: 10, relativeTo: root)
        #expect(basenameMatches.first == root.appendingPathComponent(".github/workflows/build.yml"))

        let pathMatches = MentionFuzzy.rank(files: files, query: "aui comp", limit: 10, relativeTo: root)
        #expect(pathMatches.first == root.appendingPathComponent("Sources/ACP/UI/ACPComposer.swift"))
    }

    @Test("keeps directory tokens when candidates share a parent directory")
    func keepsDirectoryTokensWhenCandidatesShareParent() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let files = [
            root.appendingPathComponent("Sources/App.swift"),
            root.appendingPathComponent("Sources/Model.swift"),
        ]

        let matches = MentionFuzzy.rank(files: files, query: "Sources App", limit: 10, relativeTo: root)

        #expect(matches.first == root.appendingPathComponent("Sources/App.swift"))
    }
}
