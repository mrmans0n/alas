import Testing
import Foundation
@testable import Alas

struct FileSearchRankerTests {
    @Test func filteredRankingMergesBackendAndMatchingOmittedEntries() async throws {
        let backendPath = "src/backend_needle.swift"
        let fallbackPath = "ignored/tracked_needle.swift"
        let backendRow = FileSearchBackendResult(
            relativePath: backendPath,
            score: 1_000,
            matchIndices: [4, 5, 6]
        )
        let source = FileSearchRankingSource(
            worktreeId: "worktree",
            projectId: "project",
            entries: [
                .init(relativePath: backendPath, ext: "swift"),
                .init(relativePath: fallbackPath, ext: "swift"),
                .init(relativePath: "src/unrelated.swift", ext: "swift"),
            ],
            backendResults: [backendRow],
            statuses: [
                backendPath: .modified,
                fallbackPath: .added,
            ]
        )

        let results = try await FileSearchRanker().rank(query: "needle", sources: [source])

        #expect(results.map(\.relativePath) == [backendPath, fallbackPath])
        let backendResult = try #require(results.first)
        #expect(backendResult.score == 1_002)
        #expect(backendResult.statusBadge == .modified)
        #expect(backendResult.matchIndices == [4, 5, 6])

        let fallbackResult = try #require(results.last)
        let fallbackMatch = try #require(FuzzyMatch.score(query: "needle", target: fallbackPath))
        #expect(fallbackResult.score == fallbackMatch.score + 10)
        #expect(fallbackResult.statusBadge == .added)
        #expect(fallbackResult.matchIndices == fallbackMatch.indices)
    }

    @Test func emptyQueryRanksStatusesFirstThenAlphabeticallyAndCapsAtFifty() async throws {
        let alphabeticalEntries = (0..<55).reversed().map {
            FileIndex.Entry(relativePath: String(format: "file_%02d.swift", $0), ext: "swift")
        }
        let taggedPath = "zz_tagged.swift"
        let source = FileSearchRankingSource(
            worktreeId: "worktree",
            projectId: "project",
            entries: alphabeticalEntries + [
                .init(relativePath: taggedPath, ext: "swift"),
            ],
            backendResults: nil,
            statuses: [taggedPath: .modified]
        )

        let results = try await FileSearchRanker().rank(query: "", sources: [source])

        #expect(results.count == 50)
        #expect(results.first?.relativePath == taggedPath)
        #expect(results.dropFirst().map(\.relativePath) == (0..<49).map {
            String(format: "file_%02d.swift", $0)
        })
        #expect(results.first?.score == 100)
    }
}
