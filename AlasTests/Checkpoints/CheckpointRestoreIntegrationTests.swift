import Foundation
import Testing
@testable import Alas

struct CheckpointRestoreIntegrationTests {
    @Test func capturePreservesIndexBytesWhenOnlyFileMetadataChanged() async throws {
        let repo = try await CheckpointTestRepository.make()
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
        let repo = try await CheckpointTestRepository.make()
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

    @Test func fullRestorePreservesEverySavedLayerAndPublishesRecovery() async throws {
        let fixture = try await CheckpointRestoreFixture.make()
        defer { fixture.remove() }
        let saved = try await fixture.snapshot()
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let before = try await fixture.snapshot()
        let preview = try await fixture.preview(checkpoint.id)

        let result = try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                                       selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)

        let after = try await fixture.snapshot()
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
        let fixture = try await CheckpointRestoreFixture.make()
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        let selected = Set(preview.groups.filter { $0.primaryPath == "selected.bin" }.map(\.id))
        let before = try await fixture.snapshot()
        let indexOID = try await fixture.repo.git(["rev-parse", ":keep.swift"])
        let diskHash = CheckpointBlobReference.make(for: try fixture.repo.disk("keep.swift"))

        let result = try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                                       selectedGroupIDs: selected, coordination: .clear)

        #expect(result.restoredPaths == ["selected.bin"])
        #expect(try await fixture.repo.git(["rev-parse", ":keep.swift"]) == indexOID)
        #expect(CheckpointBlobReference.make(for: try fixture.repo.disk("keep.swift")) == diskHash)
        let after = try await fixture.snapshot()
        for (path, state) in before.paths where path != "selected.bin" { #expect(after.paths[path] == state) }
        #expect(after.headOID == before.headOID)
        #expect(try await fixture.repo.index("selected.bin") == Data([0, 255, 1]))
        #expect(try fixture.repo.disk("selected.bin") == Data([0, 254, 2]))
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
        let repo = try await CheckpointTestRepository.make()
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

    func preview(_ id: CheckpointID) async throws -> CheckpointRestorePreview {
        try await service.restorePreview(target: repo.target, id: id, coordination: .clear)
    }

    func remove() {
        repo.remove()
        try? FileManager.default.removeItem(at: storeRoot)
    }
}
