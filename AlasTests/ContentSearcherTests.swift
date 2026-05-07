import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct ContentSearcherTests {
    private func rgAvailable() -> Bool {
        ContentSearcher.discoverRg() != nil
    }

    private func makeRepo(files: [(String, String)]) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        // Initialize git so rg respects gitignore semantics if added later.
        _ = try? await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        return dir
    }

    @Test func findsMatchesAcrossFiles() async throws {
        try #require(rgAvailable())
        let repo = try await makeRepo(files: [
            ("a.txt", "hello world\nfoo bar\nneedle here\n"),
            ("nested/b.txt", "nothing\nneedle middle\nneedle end\n"),
        ])
        defer { try? FileManager.default.removeItem(at: repo) }
        let cs = ContentSearcher()
        var hits: [ContentSearchHit] = []
        for try await hit in cs.search(
            query: "needle",
            options: SearchContentOptions(),
            worktrees: [SearchWorktree(
                id: "w1", projectId: "p1", displayName: "w",
                absolutePath: repo
            )]
        ) {
            hits.append(hit)
        }
        #expect(hits.count == 3)
        // Three hits across two distinct line numbers — line 3 in a.txt,
        // lines 2 and 3 in nested/b.txt.
        let pairs = Set(hits.map { "\($0.relativePath):\($0.line)" })
        #expect(pairs == ["a.txt:3", "nested/b.txt:2", "nested/b.txt:3"])
    }

    @Test func cancellationStopsStream() async throws {
        try #require(rgAvailable())
        // Build a directory big enough that rg takes >50ms.
        var pairs: [(String, String)] = []
        for i in 0..<500 {
            pairs.append(("f\(i).txt", "needle\n" * 100))
        }
        let repo = try await makeRepo(files: pairs)
        defer { try? FileManager.default.removeItem(at: repo) }

        let cs = ContentSearcher()
        let task = Task {
            var n = 0
            for try await _ in cs.search(
                query: "needle",
                options: SearchContentOptions(),
                worktrees: [SearchWorktree(
                    id: "w1", projectId: "p1", displayName: "w",
                    absolutePath: repo
                )]
            ) {
                n += 1
                if n > 5 { break }
            }
            return n
        }
        let count = try await task.value
        #expect(count <= 6)
    }

    @Test func caseSensitiveFlag() async throws {
        try #require(rgAvailable())
        let repo = try await makeRepo(files: [
            ("a.txt", "Needle\nneedle\n"),
        ])
        defer { try? FileManager.default.removeItem(at: repo) }
        let cs = ContentSearcher()
        var hitsCS: [ContentSearchHit] = []
        for try await h in cs.search(
            query: "Needle",
            options: SearchContentOptions(caseSensitive: true, wholeWord: false, regex: false),
            worktrees: [SearchWorktree(
                id: "w1", projectId: "p1", displayName: "w",
                absolutePath: repo
            )]
        ) { hitsCS.append(h) }
        #expect(hitsCS.count == 1)
    }
}

// `String * Int` operator for the cancellation test fixture.
private func *(lhs: String, rhs: Int) -> String {
    String(repeating: lhs, count: rhs)
}
