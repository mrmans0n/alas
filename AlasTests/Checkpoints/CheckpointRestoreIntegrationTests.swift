import Foundation
import Testing
@testable import Alas

struct CheckpointRestoreIntegrationTests {
    @Test func capturePreservesIndexBytesWhenOnlyFileMetadataChanged() async throws {
        let repo = try await CheckpointTestRepository.makeFromTemplate()
        defer { repo.remove() }
        let root = URL(fileURLWithPath: "/private/tmp/checkpoint-stat-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try repo.write("unchanged contents", to: "file")
        try await repo.commitAll("baseline")
        let before = try repo.disk(".git/index")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: repo.root.appendingPathComponent("file").path)
        let service = WorktreeCheckpointService(store: .init(root: root))
        _ = try await service.createManual(target: repo.target, label: "Unchanged")
        #expect(try repo.disk(".git/index") == before)
    }

    @Test(arguments: [false, true])
    func restoreCreatesAndRemovesUntrackedSymlinks(savedLink: Bool) async throws {
        let repo = try await CheckpointTestRepository.makeFromTemplate()
        defer { repo.remove() }
        let root = URL(fileURLWithPath: "/private/tmp/checkpoint-link-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorktreeCheckpointService(store: .init(root: root))
        if savedLink { try repo.symlink("missing-saved-target", at: "link") }
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        if savedLink { try FileManager.default.removeItem(at: repo.root.appendingPathComponent("link")) }
        else { try repo.symlink("missing-later-target", at: "link") }
        let preview = try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear)
        _ = try await service.restore(target: repo.target, preview: preview, selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        if savedLink {
            #expect(try LiveCheckpointFileSystem().readLeaf(root: repo.root, relativePath: "link") == .symlink(Data("missing-saved-target".utf8)))
        } else {
            #expect(try LiveCheckpointFileSystem().metadata(root: repo.root, relativePath: "link") == nil)
        }
    }

    @Test func restoreReplacesTrackedFileToDirectoryTransition() async throws {
        let repo = try await CheckpointTestRepository.makeFromTemplate()
        defer { repo.remove() }
        let root = URL(fileURLWithPath: "/private/tmp/checkpoint-file-dir-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try repo.write("saved config", to: "config")
        try await repo.commitAll("baseline")
        let service = WorktreeCheckpointService(store: .init(root: root))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("config"))
        try repo.write("local override", to: "config/local.json")

        let preview = try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear)
        _ = try await service.restore(target: repo.target, preview: preview,
                                      selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)

        #expect(try repo.disk("config") == Data("saved config".utf8))
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("config/local.json").path))
    }

    @Test func restoreAllowsUserFileSharingRestorePrefix() async throws {
        let repo = try await CheckpointTestRepository.makeFromTemplate()
        defer { repo.remove() }
        let root = URL(fileURLWithPath: "/private/tmp/checkpoint-restore-prefix-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = ".alas-checkpoint-restore-notes"
        try repo.write("saved notes", to: path)
        try await repo.commitAll("baseline")
        let service = WorktreeCheckpointService(store: .init(root: root))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try repo.write("local notes", to: path)

        let preview = try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear)
        _ = try await service.restore(target: repo.target, preview: preview,
                                      selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)

        #expect(try repo.disk(path) == Data("saved notes".utf8))
    }

    @Test func restoreReplacesTrackedFileWithSavedDirectoryTransition() async throws {
        let repo = try await CheckpointTestRepository.makeFromTemplate()
        defer { repo.remove() }
        let root = URL(fileURLWithPath: "/private/tmp/checkpoint-dir-file-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try repo.write("baseline config", to: "config")
        try await repo.commitAll("baseline")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("config"))
        try repo.write("saved override", to: "config/local.json")
        let service = WorktreeCheckpointService(store: .init(root: root))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try await repo.git(["restore", "--source=HEAD", "--worktree", "."])

        let preview = try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear)
        _ = try await service.restore(target: repo.target, preview: preview,
                                      selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)

        #expect(try repo.disk("config/local.json") == Data("saved override".utf8))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("config").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func restoreOrdersStructuralParentsBeforeUnrelatedDeeperPaths() async throws {
        let repo = try await CheckpointTestRepository.makeFromTemplate()
        defer { repo.remove() }
        let root = URL(fileURLWithPath: "/private/tmp/checkpoint-restore-order-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try repo.write("baseline", to: "base.txt")
        try await repo.commitAll("baseline")
        try repo.write("saved child", to: "z/c")
        try repo.write("saved unrelated", to: "zz/u")
        let service = WorktreeCheckpointService(store: .init(root: root))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("z"))
        try repo.write("current file", to: "z")
        try repo.write("current unrelated", to: "zz/u")

        let preview = try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear)
        let preparation = try await service.prepareRestore(target: repo.target, preview: preview,
                                                           selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)

        let parentIndex = try #require(preparation.selectedPaths.firstIndex(of: "z"))
        let childIndex = try #require(preparation.selectedPaths.firstIndex(of: "z/c"))
        #expect(parentIndex < childIndex)

        _ = try await CheckpointRestoreTransaction(store: .init(root: root), git: LiveCheckpointGitRunner(), fileSystem: LiveCheckpointFileSystem())
            .apply(preparation)

        #expect(try repo.disk("z/c") == Data("saved child".utf8))
        #expect(try repo.disk("zz/u") == Data("saved unrelated".utf8))
    }

    @Test func fullRestorePreservesEverySavedLayerAndPublishesRecovery() async throws {
        let fixture = try await CheckpointRestoreFixture.makeFromTemplate()
        defer { fixture.remove() }
        let saved = try await fixture.pathSnapshot()
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let before = try await fixture.pathSnapshot()
        let preview = try await fixture.preview(checkpoint.id)

        let result = try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                                       selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)

        let after = try await fixture.pathSnapshot()
        #expect(after.paths == saved.paths)
        #expect(after.headOID == before.headOID)
        #expect(try await fixture.repo.index("selected.bin") == Data([0, 255, 1]))
        #expect(try fixture.repo.disk("selected.bin") == Data([0, 254, 2]))
        #expect(try await fixture.repo.indexMode("run.sh") == "100755")
        #expect(try fixture.repo.diskPermissions("run.sh") & 0o111 != 0)
        #expect(try LiveCheckpointFileSystem().readLeaf(root: fixture.repo.root, relativePath: "link") == .symlink(Data("saved-target".utf8)))
        let recovery = try await fixture.service.manifest(target: fixture.repo.target, id: result.recoveryCheckpointID)
        #expect(recovery.kind == .recovery)
        #expect(recovery.paths.count == result.restoredPaths.count)
        for path in recovery.paths { #expect(path == before.paths[path.relativePath]) }
        #expect(try await fixture.service.summaries(target: fixture.repo.target).summaries.contains { $0.id == recovery.id })
        #expect(try await fixture.store.recoverableJournals(lineageID: fixture.repo.target.lineageID).isEmpty)
    }

    @Test func selectiveRestorePreservesUnselectedIndexAndDiskBytes() async throws {
        let fixture = try await CheckpointRestoreFixture.makeFromTemplate()
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        let selected = Set(preview.groups.filter { $0.primaryPath == "selected.bin" }.map(\.id))
        let before = try await fixture.pathSnapshot()
        let indexOID = try await fixture.repo.git(["rev-parse", ":keep.swift"])
        let diskHash = CheckpointBlobReference.make(for: try fixture.repo.disk("keep.swift"))

        let result = try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                                       selectedGroupIDs: selected, coordination: .clear)

        #expect(result.restoredPaths == ["selected.bin"])
        #expect(try await fixture.repo.git(["rev-parse", ":keep.swift"]) == indexOID)
        #expect(CheckpointBlobReference.make(for: try fixture.repo.disk("keep.swift")) == diskHash)
        let after = try await fixture.pathSnapshot()
        for (path, state) in before.paths where path != "selected.bin" { #expect(after.paths[path] == state) }
        #expect(after.headOID == before.headOID)
        #expect(try await fixture.repo.index("selected.bin") == Data([0, 255, 1]))
        #expect(try fixture.repo.disk("selected.bin") == Data([0, 254, 2]))
    }
}

/// A per-process copy source for `CheckpointTestRepository.makeFromTemplate()`.
/// It holds exactly what `CheckpointTestRepository.make()` builds (same `git init`,
/// same config, same empty seed commit) but never gets a lineage marker, so each
/// copy mints its own lineage. The seed commit tracks no files, so the index has
/// no stat entries that could go stale when the directory is copied.
private enum CheckpointRepositoryTemplate {
    static let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("checkpoint-template-\(UUID().uuidString)")
    static let ready = Task<URL, any Error> {
        try FileManager.default.createDirectory(at: CheckpointRepositoryTemplate.root, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Checkpoint Tests"],
                     ["config", "user.email", "checkpoints@example.test"], ["config", "commit.gpgsign", "false"],
                     ["config", "core.hooksPath", "/dev/null"], ["config", "core.filemode", "true"],
                     ["commit", "--allow-empty", "-m", "seed"]] {
            let result = try await Process.git(args, cwd: CheckpointRepositoryTemplate.root)
            guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        }
        atexit { try? FileManager.default.removeItem(at: CheckpointRepositoryTemplate.root) }
        return CheckpointRepositoryTemplate.root
    }
}

extension CheckpointTestRepository {
    /// Equivalent to `make()` — a real repository with the same config and seed
    /// commit, and a fresh lineage — but copied from a template instead of
    /// spawning seven `git` processes per test.
    static func makeFromTemplate() async throws -> Self {
        let template = try await CheckpointRepositoryTemplate.ready.value
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("checkpoint-test-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: template, to: root)
            let lineage = try #require(WorktreeService.localLineageID(forWorktreeAt: root))
            return Self(root: root, target: .init(worktreeID: UUID().uuidString, projectID: "test", path: root,
                                                 lineageID: lineage, branch: "main", repositoryName: "test", workspaceName: nil))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

struct CheckpointRestoreFixture: Sendable {
    enum Fault: Error { case injected }
    let repo: CheckpointTestRepository
    let storeRoot: URL
    let store: WorktreeCheckpointStore
    let service: WorktreeCheckpointService
    static let paths: Set<String> = ["selected.bin", "keep.swift", "deleted", "added", "old", "new", "run.sh", "link", "untracked", "later-only"]

    static func make(faultInjector: CheckpointRestoreFaultInjector = .none) async throws -> Self {
        try await populate(CheckpointTestRepository.make(), faultInjector: faultInjector)
    }

    /// Same fixture as `make()`, built on a template-copied repository.
    static func makeFromTemplate(faultInjector: CheckpointRestoreFaultInjector = .none) async throws -> Self {
        try await populate(CheckpointTestRepository.makeFromTemplate(), faultInjector: faultInjector)
    }

    private static func populate(_ repo: CheckpointTestRepository, faultInjector: CheckpointRestoreFaultInjector) async throws -> Self {
        let root = URL(fileURLWithPath: "/private/tmp/checkpoint-apply-store-\(UUID().uuidString)")
        let store = WorktreeCheckpointStore(root: root)
        let service = WorktreeCheckpointService(store: store, restoreFaultInjector: faultInjector)
        for path in ["selected.bin", "keep.swift", "deleted", "old", "run.sh"] { try repo.write("baseline \(path)\n", to: path) }
        try repo.symlink("baseline-target", at: "link")
        try await repo.commitAll("baseline")
        try await repo.git(["mv", "old", "new"])
        try await repo.git(["rm", "deleted"])
        try repo.write(Data([0, 255, 1]), to: "selected.bin")
        try repo.write("saved index", to: "keep.swift")
        try repo.write("saved addition", to: "added")
        try repo.write("#!/bin/sh\necho saved\n", to: "run.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.appendingPathComponent("run.sh").path)
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("link"))
        try repo.symlink("saved-target", at: "link")
        try await repo.git(["add", "-A"])
        try repo.write(Data([0, 254, 2]), to: "selected.bin")
        try repo.write("saved disk", to: "keep.swift")
        try repo.write("saved untracked", to: "untracked")
        return .init(repo: repo, storeRoot: root, store: store, service: service)
    }

    func later() async throws {
        try await repo.git(["restore", "--source=HEAD", "--staged", "--worktree", "."])
        for path in ["selected.bin", "keep.swift", "deleted", "old", "run.sh"] { try repo.write("later index \(path)", to: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: repo.root.appendingPathComponent("run.sh").path)
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("link"))
        try repo.symlink("later-target", at: "link")
        try await repo.git(["add", "-u"])
        try repo.write("later disk", to: "selected.bin")
        try repo.write("keep later disk", to: "keep.swift")
        try repo.write("later untracked", to: "untracked")
        try repo.write("remove on restore", to: "later-only")
    }

    func snapshot() async throws -> WorktreeStateSnapshot {
        try await WorktreeStateSnapshotter.live.snapshot(target: repo.target, includingPaths: Self.paths)
    }

    /// The same path states, HEAD, and index checksum as `snapshot()`, without
    /// retaining payload bytes: blobs are hashed via one streamed `cat-file` per
    /// entry instead of `cat-file -s` plus `cat-file blob`. Assertions only read
    /// `paths` and `headOID`, whose values do not depend on retention.
    func pathSnapshot() async throws -> WorktreeStateSnapshot {
        try await WorktreeStateSnapshotter.live.snapshot(target: repo.target, includingPaths: Self.paths, retainingPayloads: false)
    }

    func preview(_ id: CheckpointID) async throws -> CheckpointRestorePreview {
        try await service.restorePreview(target: repo.target, id: id, coordination: .clear)
    }

    func remove() {
        repo.remove()
        try? FileManager.default.removeItem(at: storeRoot)
    }
}
