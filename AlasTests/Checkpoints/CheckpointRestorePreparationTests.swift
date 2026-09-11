import Foundation
import Testing
@testable import Alas

struct CheckpointRestorePreparationTests {
    @Test func prepareBuildsDesiredIndexAndLeavesTheWorktreeUntouched() async throws {
        let fixture = try await RestorePreparationFixture.make()
        defer { fixture.remove() }

        let checkpoint = try await fixture.service.createManual(target: fixture.target, label: "Saved state")
        try await fixture.makeLaterState()
        let preview = try await fixture.service.restorePreview(target: fixture.target, id: checkpoint.id, coordination: .clear)
        let preRestore = try await fixture.snapshot()
        let before = try await fixture.state()

        let preparation = try await fixture.service.prepareRestore(target: fixture.target, preview: preview,
                                                                    selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)

        #expect(try await fixture.state() == before)
        #expect(preparation.stagingRoot.deletingLastPathComponent() == fixture.repo.root)
        #expect(preparation.stagingRoot.lastPathComponent == ".alas-checkpoint-restore-\(preparation.operationID.uuidString.lowercased())")
        #expect(FileManager.default.fileExists(atPath: preparation.replacementsRoot.path))
        #expect(FileManager.default.fileExists(atPath: preparation.backupsRoot.path))

        let recovery = try await fixture.service.manifest(target: fixture.target, id: preparation.recoveryCheckpointID)
        #expect(recovery.label == "Before checkpoint restore")
        #expect(recovery.paths.map(\.relativePath).sorted() == preparation.selectedPaths)
        #expect(recovery.paths.sorted { $0.relativePath < $1.relativePath } ==
                    preparation.selectedPaths.compactMap { preRestore.paths[$0] }.sorted { $0.relativePath < $1.relativePath })

        #expect(try await fixture.gitIndex(preparation.preparedIndex, path: "delete.txt") == nil)
        let runIndex = try #require(await fixture.gitIndex(preparation.preparedIndex, path: "run.sh"))
        let linkIndex = try #require(await fixture.gitIndex(preparation.preparedIndex, path: "link"))
        #expect(runIndex == ("100755", Data("#!/bin/sh\necho saved\n".utf8)))
        #expect(linkIndex == ("120000", Data("saved-target".utf8)))
        #expect(try await fixture.gitIndex(preparation.preparedIndex, path: "untracked.txt") == nil)

        let journal = try await fixture.store.journal(id: preparation.operationID, lineageID: fixture.target.lineageID)
        #expect(journal?.phase == .prepared)
        #expect(journal?.recoveryCheckpointID == preparation.recoveryCheckpointID)
        #expect(journal?.stagingRoot == preparation.stagingRoot.path)
        #expect(journal?.stagingNames.keys.sorted() == preparation.selectedPaths)
        #expect(journal?.preparedIndexChecksum == preparation.preparedIndexChecksum)
    }

    @Test func storageFailureLeavesNoRestoreStagingDirectory() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let root = URL(fileURLWithPath: "/private/tmp/checkpoint-restore-limited-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try repo.write("baseline", to: "file.txt")
        try await repo.commitAll("baseline")
        try repo.write("saved", to: "file.txt")
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: 100))
        let service = WorktreeCheckpointService(store: store)
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try repo.write(String(repeating: "later", count: 50), to: "file.txt")
        let preview = try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear)

        await #expect(throws: CheckpointStoreError.byteLimitExceeded) {
            try await service.prepareRestore(target: repo.target, preview: preview, selectedGroupIDs: preview.selectedGroupIDs,
                                             coordination: .clear)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: repo.root.path)
        #expect(!names.contains { $0.hasPrefix(".alas-checkpoint-restore-") })
    }

    @Test func freshPreflightRejectsAnIndexLockAddedAfterPreview() async throws {
        let fixture = try await RestorePreparationFixture.make()
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.target, label: "Saved")
        try await fixture.makeLaterState()
        let preview = try await fixture.service.restorePreview(target: fixture.target, id: checkpoint.id, coordination: .clear)
        try fixture.repo.write("external lock", to: ".git/index.lock")

        await #expect(throws: CheckpointRestoreError.blocked(.indexLock)) {
            try await fixture.service.prepareRestore(target: fixture.target, preview: preview,
                                                     selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        }
        #expect(try await fixture.service.summaries(target: fixture.target).summaries == [checkpoint])
    }

    @Test func freshPreflightRejectsCurrentSessionCoordination() async throws {
        let fixture = try await RestorePreparationFixture.make()
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.target, label: "Saved")
        try await fixture.makeLaterState()
        let preview = try await fixture.service.restorePreview(target: fixture.target, id: checkpoint.id, coordination: .clear)
        let active = CheckpointCoordinationSnapshot(dirtyEditorPaths: [], activeTerminalCount: 1, activeACPCount: 0,
                                                    otherGitMutationActive: false, scopeDescription: "This repository only")

        await #expect(throws: CheckpointRestoreError.blocked(.activeSession)) {
            try await fixture.service.prepareRestore(target: fixture.target, preview: preview,
                                                     selectedGroupIDs: preview.selectedGroupIDs, coordination: active)
        }
        #expect(try await fixture.service.summaries(target: fixture.target).summaries == [checkpoint])
    }

    @Test func preparedJournalFaultRemovesJournalAndStaging() async throws {
        let fixture = try await RestorePreparationFixture.make()
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.target, label: "Saved")
        try await fixture.makeLaterState()
        let preview = try await fixture.service.restorePreview(target: fixture.target, id: checkpoint.id, coordination: .clear)
        let injector = CheckpointRestoreFaultInjector { point in
            if point == .afterJournalPrepared { throw RestorePreparationFixture.Fault.injected }
        }

        await #expect(throws: RestorePreparationFixture.Fault.injected) {
            try await fixture.service.prepareRestore(target: fixture.target, preview: preview,
                                                     selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear,
                                                     faultInjector: injector)
        }
        #expect(try await fixture.store.recoverableJournals(lineageID: fixture.target.lineageID).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.repo.root.path)
        #expect(!names.contains { $0.hasPrefix(".alas-checkpoint-restore-") })
    }
}

private struct RestorePreparationFixture: Sendable {
    enum Fault: Error, Equatable { case injected }
    let repo: CheckpointTestRepository
    let storeRoot: URL
    let store: WorktreeCheckpointStore
    let service: WorktreeCheckpointService

    var target: CheckpointWorktreeTarget { repo.target }

    static func make() async throws -> Self {
        let repo = try await CheckpointTestRepository.make()
        let root = URL(fileURLWithPath: "/private/tmp/checkpoint-restore-store-\(UUID().uuidString)")
        let store = WorktreeCheckpointStore(root: root)
        let service = WorktreeCheckpointService(store: store)
        try repo.write("delete baseline\n", to: "delete.txt")
        try repo.write("#!/bin/sh\necho baseline\n", to: "run.sh")
        try await repo.stage("run.sh")
        try await repo.git(["update-index", "--chmod=+x", "run.sh"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.appendingPathComponent("run.sh").path)
        try repo.symlink("baseline-target", at: "link")
        try await repo.commitAll("baseline")
        try await repo.git(["rm", "delete.txt"])
        try repo.write("#!/bin/sh\necho saved\n", to: "run.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.appendingPathComponent("run.sh").path)
        try await repo.stage("run.sh")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("link"))
        try repo.symlink("saved-target", at: "link")
        try await repo.stage("link")
        return .init(repo: repo, storeRoot: root, store: store, service: service)
    }

    func makeLaterState() async throws {
        try await repo.git(["restore", "--source=HEAD", "--staged", "--worktree", "delete.txt", "run.sh", "link"])
        try repo.write("later delete\n", to: "delete.txt")
        try await repo.stage("delete.txt")
        try repo.write("#!/bin/sh\necho later\n", to: "run.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.appendingPathComponent("run.sh").path)
        try await repo.stage("run.sh")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("link"))
        try repo.symlink("later-target", at: "link")
        try await repo.stage("link")
        try repo.write("later untracked\n", to: "untracked.txt")
    }

    func state() async throws -> (String, Data, String, [String: Data]) {
        let snapshot = try await snapshot()
        let excludedPrefix = Array("? .alas-checkpoint-restore-".utf8)
        let records = try await repo.status().split(separator: 0).map(Array.init)
        let userStatus = Data(records.filter { !$0.starts(with: excludedPrefix) }.flatMap { $0 + [0] })
        return (snapshot.headOID, userStatus, snapshot.indexChecksum, [
            "delete.txt": try repo.disk("delete.txt"),
            "run.sh": try repo.disk("run.sh"),
            "link": try leaf("link"),
            "untracked.txt": try repo.disk("untracked.txt"),
        ])
    }

    func snapshot() async throws -> WorktreeStateSnapshot {
        try await WorktreeStateSnapshotter.live.snapshot(target: target, includingPaths: ["delete.txt", "run.sh", "link", "untracked.txt"])
    }

    private func leaf(_ path: String) throws -> Data {
        switch try LiveCheckpointFileSystem().readLeaf(root: repo.root, relativePath: path) {
        case .regular(let data, _), .symlink(let data): data
        }
    }

    func payload(_ state: CheckpointFileState) async throws -> Data {
        try await store.readBlob(#require(state.blob), lineageID: target.lineageID)
    }

    func gitIndex(_ index: URL, path: String) async throws -> (String, Data)? {
        let result = try await LiveCheckpointGitRunner().runData(["ls-files", "--stage", "--", path], cwd: repo.root,
                                                                   environment: ["GIT_INDEX_FILE": index.path])
        let output = String(decoding: result.stdout, as: UTF8.self)
        guard !output.isEmpty else { return nil }
        let fields = output.split(separator: "\t", maxSplits: 1)[0].split(separator: " ")
        let bytes = try await LiveCheckpointGitRunner().runData(["cat-file", "blob", String(fields[1])], cwd: repo.root,
                                                                  environment: ["GIT_INDEX_FILE": index.path]).stdout
        return (String(fields[0]), bytes)
    }

    func remove() {
        repo.remove()
        try? FileManager.default.removeItem(at: storeRoot)
    }
}
