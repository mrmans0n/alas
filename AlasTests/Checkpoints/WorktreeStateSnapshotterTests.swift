import Foundation
import Testing
@testable import Alas

struct WorktreeStateSnapshotterTests {
    @Test func snapshotKeepsHeadIndexAndDiskVersionsDistinct() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("original\n", to: "file.swift")
        try await repo.commitAll("file")
        try repo.write("staged\n", to: "file.swift")
        try await repo.stage("file.swift")
        try repo.write("unstaged\n", to: "file.swift")
        let before = try await repo.status()
        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        let path = try #require(snapshot.paths["file.swift"])
        #expect(try snapshot.payload(path.head) == Data("original\n".utf8))
        #expect(try snapshot.payload(path.index) == Data("staged\n".utf8))
        #expect(try snapshot.payload(path.worktree) == Data("unstaged\n".utf8))
        #expect(try await repo.head("file.swift") == Data("original\n".utf8))
        #expect(try await repo.index("file.swift") == Data("staged\n".utf8))
        #expect(try repo.disk("file.swift") == Data("unstaged\n".utf8))
        #expect(try await repo.status() == before)
    }

    @Test func trackedDeletionIsAbsentOnDisk() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("original", to: "deleted")
        try await repo.commitAll("file")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("deleted"))
        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        #expect(snapshot.paths["deleted"]?.worktree == .absent)
        #expect(try snapshot.payload(#require(snapshot.paths["deleted"]).index) == Data("original".utf8))
    }

    @Test func stagedRenameGroupsBothPaths() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("original", to: "old name")
        try await repo.commitAll("file")
        try await repo.git(["mv", "old name", "new\nname"])
        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        let group = try #require(snapshot.groups.first { $0.primaryPath == "new\nname" })
        #expect(group.renameSource == "old name")
        #expect(Set(group.memberPaths) == ["old name", "new\nname"])
        #expect(snapshot.paths["old name"]?.index == .absent)
    }

    @Test func executableModesSurvive() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("script", to: "run")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.appendingPathComponent("run").path)
        try await repo.stage("run")
        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        #expect(snapshot.paths["run"]?.index.mode == "100755")
        #expect(snapshot.paths["run"]?.worktree.mode == "100755")
        #expect(try await repo.indexMode("run") == "100755")
        #expect(try repo.diskPermissions("run") & 0o111 != 0)
    }

    @Test func symlinkCapturesTargetBytes() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.symlink("nonexistent-target", at: "link")
        try await repo.stage("link")
        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        let path = try #require(snapshot.paths["link"])
        #expect(path.worktree.kind == .symlink)
        #expect(try snapshot.payload(path.worktree) == Data("nonexistent-target".utf8))
        #expect(try snapshot.payload(path.index) == Data("nonexistent-target".utf8))
    }

    @Test func binaryDataSurvives() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write(Data([0, 255, 254, 128]), to: "binary")
        try await repo.stage("binary")
        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        let path = try #require(snapshot.paths["binary"])
        #expect(try snapshot.payload(path.index) == Data([0, 255, 254, 128]))
        #expect(try snapshot.payload(path.worktree) == Data([0, 255, 254, 128]))
    }

    @Test func untrackedSourceIncludedAndIgnoredContentAbsent() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("ignored/\n", to: ".gitignore")
        try await repo.commitAll("ignore")
        try repo.write("source", to: "source.swift")
        try repo.write("ignored", to: "ignored/file")
        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        #expect(Set(snapshot.paths.keys) == ["source.swift"])
    }

    @Test func gitlinkFailsCapture() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let oid = String(decoding: try await repo.git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try await repo.git(["update-index", "--add", "--cacheinfo", "160000,\(oid),module"])
        await #expect(throws: (any Error).self) { try await WorktreeStateSnapshotter.live.snapshot(target: repo.target) }
    }

    @Test func unmergedEntryFailsCapture() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("base", to: "file")
        try await repo.commitAll("base")
        try await repo.git(["checkout", "-b", "other"])
        try repo.write("other", to: "file")
        try await repo.commitAll("other")
        try await repo.git(["checkout", "main"])
        try repo.write("main", to: "file")
        try await repo.commitAll("main")
        _ = try await Process.git(["merge", "other"], cwd: repo.root)
        await #expect(throws: (any Error).self) { try await WorktreeStateSnapshotter.live.snapshot(target: repo.target) }
    }

    @Test func sparseStateFailsCapture() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("base", to: "file")
        try await repo.commitAll("base")
        try await repo.git(["update-index", "--skip-worktree", "file"])
        await #expect(throws: (any Error).self) { try await WorktreeStateSnapshotter.live.snapshot(target: repo.target) }
    }

    @Test func assumeUnchangedDiskEditFailsCapture() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("original", to: "hidden.swift")
        try await repo.commitAll("file")
        try await repo.git(["update-index", "--assume-unchanged", "hidden.swift"])
        try repo.write("hidden disk edit", to: "hidden.swift")
        #expect(try await repo.status().isEmpty)
        #expect(try await repo.git(["diff", "--name-only"]).isEmpty)
        await #expect(throws: CheckpointSnapshotError.unsupportedPaths(["hidden.swift"])) {
            try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        }
        #expect(try repo.disk("hidden.swift") == Data("hidden disk edit".utf8))
        #expect(try await repo.index("hidden.swift") == Data("original".utf8))
    }

    @Test func untrackedPolicyUsesExactNamesAndCaseInsensitiveExtensions() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let ignored = [".build/a", "build/a", "DerivedData/a", "node_modules/a", ".swiftpm/a", ".gradle/a", "Pods/a", "Carthage/a"]
        let secrets = [".env", ".env.local", ".netrc", "credentials", "credentials.json", "cert.KEY", "cert.pem", "cert.p12",
                       "cert.pfx", "cert.mobileprovision", "cert.keystore"]
        // Separate directories avoid case-folding aliases on macOS volumes.
        let allowed = ["case/Build/a", "case/Credentials", ".environment", "env.swift", "cert.pem.swift"]
        let internalPath = ".alas-checkpoint-restore-12345678-1234-1234-1234-123456789012/file"
        for path in ignored + secrets + allowed + [internalPath] { try repo.write("content", to: path) }
        try repo.write(Data(repeating: 0, count: 10 * 1024 * 1024 + 1), to: "large")
        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        #expect(Set(snapshot.paths.keys) == Set(allowed))
        let reasons = Dictionary(uniqueKeysWithValues: snapshot.exclusions.map { ($0.relativePath, $0.reason) })
        for path in ignored { #expect(reasons[path] == .ignoredByPolicy) }
        for path in secrets { #expect(reasons[path] == .likelySecret) }
        #expect(reasons[internalPath] == .internalRestoreDirectory)
        #expect(reasons["large"] == .tooLarge)
    }

    @Test func trackedSecretNamesRemainIncluded() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("tracked", to: ".env")
        try await repo.stage(".env")
        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        #expect(snapshot.paths[".env"] != nil)
        #expect(snapshot.exclusions.isEmpty)
    }

    @Test func fingerprintIsStableAndChangesWithDiskBytes() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("one", to: "file")
        let first = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        let second = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        #expect(first.fingerprint == second.fingerprint)
        try repo.write("two", to: "file")
        let changed = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        #expect(first.fingerprint != changed.fingerprint)
    }

    @Test func lineageReplacementFailsCapture() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("\(UUID().uuidString.lowercased())\n", to: ".git/alas-worktree-lineage")
        await #expect(throws: CheckpointSnapshotError.lineageChanged) {
            try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        }
    }
}
