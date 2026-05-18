import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitIgnoreServiceTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        return dir
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func appendsFilePatternToRepoRootGitignore() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let gi = repo.appendingPathComponent(".gitignore")
        try "existing.log\n".write(to: gi, atomically: true, encoding: .utf8)

        let written = try GitIgnoreService.appendIgnore(
            entryPath: "src/foo/bar.log",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )

        #expect(written == gi)
        #expect(try read(gi) == "existing.log\nsrc/foo/bar.log\n")
    }

    @Test func appendsFolderPatternWithTrailingSlash() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let gi = repo.appendingPathComponent(".gitignore")
        try "".write(to: gi, atomically: true, encoding: .utf8)

        _ = try GitIgnoreService.appendIgnore(
            entryPath: "build",
            isDirectory: true,
            destination: .repoRoot,
            repoURL: repo
        )

        #expect(try read(gi) == "build/\n")
    }

    @Test func dedupSkipsExistingPattern() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let gi = repo.appendingPathComponent(".gitignore")
        try "src/foo/bar.log\nother.txt\n".write(to: gi, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: gi)

        _ = try GitIgnoreService.appendIgnore(
            entryPath: "src/foo/bar.log",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )

        let after = try Data(contentsOf: gi)
        #expect(before == after)
    }

    @Test func createsGitignoreWhenAbsent() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let gi = repo.appendingPathComponent(".gitignore")
        #expect(!FileManager.default.fileExists(atPath: gi.path))

        _ = try GitIgnoreService.appendIgnore(
            entryPath: "fresh.log",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )

        #expect(try read(gi) == "fresh.log\n")
    }

    @Test func addsMissingTrailingNewlineBeforeAppending() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let gi = repo.appendingPathComponent(".gitignore")
        try "no-newline-at-end".write(to: gi, atomically: true, encoding: .utf8)

        _ = try GitIgnoreService.appendIgnore(
            entryPath: "new.log",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )

        #expect(try read(gi) == "no-newline-at-end\nnew.log\n")
    }

    @Test func nearestUsesExistingGitignoreInParentChain() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let src = repo.appendingPathComponent("src")
        let foo = src.appendingPathComponent("foo")
        try FileManager.default.createDirectory(at: foo, withIntermediateDirectories: true)
        let srcGi = src.appendingPathComponent(".gitignore")
        try "other\n".write(to: srcGi, atomically: true, encoding: .utf8)

        let written = try GitIgnoreService.appendIgnore(
            entryPath: "src/foo/bar.log",
            isDirectory: false,
            destination: .nearest,
            repoURL: repo
        )

        #expect(written == srcGi)
        // Pattern is relative to the .gitignore's directory (src/).
        #expect(try read(srcGi) == "other\nfoo/bar.log\n")
    }

    @Test func nearestFallbackCreatesGitignoreAtEntryParent() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let foo = repo.appendingPathComponent("src").appendingPathComponent("foo")
        try FileManager.default.createDirectory(at: foo, withIntermediateDirectories: true)

        let written = try GitIgnoreService.appendIgnore(
            entryPath: "src/foo/bar.log",
            isDirectory: false,
            destination: .nearest,
            repoURL: repo
        )

        #expect(written == foo.appendingPathComponent(".gitignore"))
        #expect(try read(written) == "bar.log\n")
    }

    @Test func nearestFallbackForTopLevelEntryUsesRepoRoot() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let written = try GitIgnoreService.appendIgnore(
            entryPath: "top.log",
            isDirectory: false,
            destination: .nearest,
            repoURL: repo
        )

        #expect(written == repo.appendingPathComponent(".gitignore"))
        #expect(try read(written) == "top.log\n")
    }
}
