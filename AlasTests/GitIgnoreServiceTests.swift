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

    @Test func appendsToInfoExclude() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let exclude = repo
            .appendingPathComponent(".git")
            .appendingPathComponent("info")
            .appendingPathComponent("exclude")

        // `git init` typically creates .git/info/exclude with a header comment;
        // overwrite with empty so we can assert exact contents.
        try "".write(to: exclude, atomically: true, encoding: .utf8)

        let written = try GitIgnoreService.appendIgnore(
            entryPath: "secret.local",
            isDirectory: false,
            destination: .infoExclude,
            repoURL: repo
        )

        #expect(written == exclude)
        #expect(try read(exclude) == "secret.local\n")
    }

    @Test func appendsToInfoExcludeCreatingDirectoryIfMissing() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let info = repo.appendingPathComponent(".git").appendingPathComponent("info")
        try? FileManager.default.removeItem(at: info)
        #expect(!FileManager.default.fileExists(atPath: info.path))

        let written = try GitIgnoreService.appendIgnore(
            entryPath: "dropped.local",
            isDirectory: false,
            destination: .infoExclude,
            repoURL: repo
        )

        #expect(written == info.appendingPathComponent("exclude"))
        #expect(try read(written) == "dropped.local\n")
    }

    /// Linked worktrees store `info/exclude` in the per-worktree git dir,
    /// not under `<worktree>/.git/info/exclude`. The caller resolves the
    /// real path via `git rev-parse --git-path info/exclude` and passes
    /// it as `infoExcludeURL`. The pattern is still written relative to
    /// the worktree root.
    @Test func infoExcludeURLOverrideTargetsLinkedWorktreeGitDir() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Simulate a per-worktree git dir outside the working tree.
        let externalGitDir = repo
            .deletingLastPathComponent()
            .appendingPathComponent("alas-ign-linked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: externalGitDir) }
        let override = externalGitDir
            .appendingPathComponent("info")
            .appendingPathComponent("exclude")

        let written = try GitIgnoreService.appendIgnore(
            entryPath: "src/foo/secret.local",
            isDirectory: false,
            destination: .infoExclude,
            repoURL: repo,
            infoExcludeURL: override
        )

        #expect(written == override)
        #expect(try read(override) == "src/foo/secret.local\n")
        // The default path under <repo>/.git/info/exclude must not have been
        // written (overwriting `git init`'s seeded header would be a regression).
        let defaultPath = repo
            .appendingPathComponent(".git")
            .appendingPathComponent("info")
            .appendingPathComponent("exclude")
        let defaultContents = (try? String(contentsOf: defaultPath, encoding: .utf8)) ?? ""
        #expect(!defaultContents.contains("src/foo/secret.local"))
    }

    @Test func escapesLeadingHashBangBracketAndTrailingSpaces() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let gi = repo.appendingPathComponent(".gitignore")
        try "".write(to: gi, atomically: true, encoding: .utf8)

        _ = try GitIgnoreService.appendIgnore(
            entryPath: "#hash.txt",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )
        _ = try GitIgnoreService.appendIgnore(
            entryPath: "!bang.txt",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )
        _ = try GitIgnoreService.appendIgnore(
            entryPath: "[bracket].txt",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )
        _ = try GitIgnoreService.appendIgnore(
            entryPath: "trailing space ",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )

        let expected = """
        \\#hash.txt
        \\!bang.txt
        \\[bracket].txt
        trailing space\\ 

        """
        #expect(try read(gi) == expected)
    }

    /// Interior glob metacharacters (`[`, `*`, `?`) must be escaped too,
    /// otherwise git interprets the path as a pattern and the file stays
    /// untracked. Backslashes in filenames must be escaped to themselves.
    @Test func escapesInteriorGlobMetacharacters() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let gi = repo.appendingPathComponent(".gitignore")
        try "".write(to: gi, atomically: true, encoding: .utf8)

        _ = try GitIgnoreService.appendIgnore(
            entryPath: "src/[draft].md",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )
        _ = try GitIgnoreService.appendIgnore(
            entryPath: "logs/wild*name.log",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )
        _ = try GitIgnoreService.appendIgnore(
            entryPath: "data/who?.csv",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )
        _ = try GitIgnoreService.appendIgnore(
            entryPath: "weird\\name.txt",
            isDirectory: false,
            destination: .repoRoot,
            repoURL: repo
        )

        let expected = """
        src/\\[draft].md
        logs/wild\\*name.log
        data/who\\?.csv
        weird\\\\name.txt

        """
        #expect(try read(gi) == expected)
    }
}
