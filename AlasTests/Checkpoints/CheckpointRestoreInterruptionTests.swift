import Foundation
import Testing
@testable import Alas

struct CheckpointRestoreInterruptionTests {
    @Test(arguments: [false, true])
    func selectiveRecoveryPreservesUnrelatedEditsMadeAfterInterruption(replacedByDirectory: Bool) async throws {
        let fixture = try await CheckpointRestoreFixture.make(faultInjector: .init {
            if $0 == .beforeIndexInstall { throw CheckpointRestoreFixture.Fault.injected }
            if case .duringRollback = $0 { throw CheckpointRestoreFixture.Fault.injected }
        })
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        let selected = Set(preview.groups.filter { $0.primaryPath == "selected.bin" }.map(\.id))
        let before = try await fixture.snapshot()
        await #expect(throws: (any Error).self) {
            try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                               selectedGroupIDs: selected, coordination: .clear)
        }
        let unrelatedPath: String
        if replacedByDirectory {
            try FileManager.default.removeItem(at: fixture.repo.root.appendingPathComponent("keep.swift"))
            unrelatedPath = "keep.swift/note.txt"
        } else {
            unrelatedPath = "keep.swift"
        }
        try fixture.repo.write("unrelated edit after interruption", to: unrelatedPath)
        try fixture.repo.write("new unrelated file", to: "after-interruption.txt")
        try fixture.repo.write("new excluded file", to: ".env")
        let store = WorktreeCheckpointStore(root: fixture.storeRoot)
        let service = WorktreeCheckpointService(store: store)
        let journals = try await store.recoverableJournals(lineageID: fixture.repo.target.lineageID)
        let journal = try #require(journals.first)
        let result = try await service.recoverInterruptedRestore(target: fixture.repo.target, operationID: journal.id, coordination: .clear)
        #expect(result.restoredPaths == ["selected.bin"])
        let after = try await WorktreeStateSnapshotter.live.snapshot(target: fixture.repo.target, includingPaths: ["selected.bin"], onlyIncludedPaths: true)
        #expect(after.paths["selected.bin"] == before.paths["selected.bin"])
        #expect(after.indexChecksum == before.indexChecksum)
        #expect(try fixture.repo.disk(unrelatedPath) == Data("unrelated edit after interruption".utf8))
        #expect(try fixture.repo.disk("after-interruption.txt") == Data("new unrelated file".utf8))
        #expect(try fixture.repo.disk(".env") == Data("new excluded file".utf8))
        #expect(try await store.recoverableJournals(lineageID: fixture.repo.target.lineageID).isEmpty)
    }

    @Test(arguments: [CheckpointRestoreFaultPoint.afterPartialIndexWrite, .beforeIndexCandidateSync,
                      .afterIndexCandidatePublication, .afterIndexLockHandoff], [false, true])
    func indexInstallationInterruptionCanRecoverWithoutTrustingForeignLockBytes(point: CheckpointRestoreFaultPoint, tamper: Bool) async throws {
        let fixture = try await CheckpointRestoreFixture.make(faultInjector: .init {
            if $0 == point { throw CheckpointRestoreFixture.Fault.injected }
            if case .duringRollback = $0 { throw CheckpointRestoreFixture.Fault.injected }
        })
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        let before = try await fixture.snapshot()
        await #expect(throws: (any Error).self) {
            try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                               selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        }
        let store = WorktreeCheckpointStore(root: fixture.storeRoot)
        let service = WorktreeCheckpointService(store: store)
        let journals = try await store.recoverableJournals(lineageID: fixture.repo.target.lineageID)
        let journal = try #require(journals.first)
        if tamper {
            try fixture.repo.write("foreign lock bytes", to: ".git/index.lock")
            await #expect(throws: (any Error).self) {
                try await service.recoverInterruptedRestore(target: fixture.repo.target, operationID: journal.id, coordination: .clear)
            }
            #expect(try fixture.repo.disk(".git/index.lock") == Data("foreign lock bytes".utf8))
            #expect(try await store.recoverableJournals(lineageID: fixture.repo.target.lineageID).count == 1)
        } else {
            _ = try await service.recoverInterruptedRestore(target: fixture.repo.target, operationID: journal.id, coordination: .clear)
            let after = try await fixture.snapshot()
            #expect(after.paths == before.paths)
            #expect(after.indexChecksum == before.indexChecksum)
            #expect(try await store.recoverableJournals(lineageID: fixture.repo.target.lineageID).isEmpty)
            let names = try FileManager.default.contentsOfDirectory(atPath: fixture.repo.root.appendingPathComponent(".git").path)
            #expect(!names.contains { $0.hasPrefix(".alas-checkpoint-index-") || $0 == "index.lock" })
        }
    }

    @Test(arguments: [CheckpointRestoreFaultPoint.afterFileMove(path: "added"), .afterFileMove(path: "selected.bin"),
                      .beforeIndexInstall, .afterIndexInstall, .beforeVerification])
    func failuresRollBackBothLayers(point: CheckpointRestoreFaultPoint) async throws {
        let fixture = try await CheckpointRestoreFixture.make(faultInjector: .init { if $0 == point { throw CheckpointRestoreFixture.Fault.injected } })
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        let before = try await fixture.snapshot()
        await #expect(throws: CheckpointRestoreError.restoreFailedButRecovered) {
            try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                               selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        }
        let after = try await fixture.snapshot()
        #expect(after.paths == before.paths)
        #expect(after.indexChecksum == before.indexChecksum)
        #expect(after.headOID == before.headOID)
        #expect(try await fixture.store.recoverableJournals(lineageID: fixture.repo.target.lineageID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.repo.root.appendingPathComponent(".git/index.lock").path))
    }

    @Test(arguments: [false, true], [CheckpointRestoreFaultPoint.beforeIndexInstall, .afterIndexInstall])
    func relaunchRecoversUnlessOwnedLockChanged(tamper: Bool, point: CheckpointRestoreFaultPoint) async throws {
        let fixture = try await CheckpointRestoreFixture.make(faultInjector: .init {
            if $0 == point { throw CheckpointRestoreFixture.Fault.injected }
            if case .duringRollback = $0 { throw CheckpointRestoreFixture.Fault.injected }
        })
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        let before = try await fixture.snapshot()
        await #expect(throws: (any Error).self) {
            try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                               selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        }
        let store = WorktreeCheckpointStore(root: fixture.storeRoot)
        let service = WorktreeCheckpointService(store: store)
        let journals = try await store.recoverableJournals(lineageID: fixture.repo.target.lineageID)
        let journal = try #require(journals.first)
        #expect(!journal.phase.isTerminal)
        #expect(try FileManager.default.contentsOfDirectory(atPath: journal.stagingRoot + "/backups").count > 0)
        if tamper {
            try fixture.repo.write("external replacement lock", to: ".git/index.lock")
            await #expect(throws: (any Error).self) {
                try await service.recoverInterruptedRestore(target: fixture.repo.target, operationID: journal.id, coordination: .clear)
            }
            #expect(try fixture.repo.disk(".git/index.lock") == Data("external replacement lock".utf8))
            #expect(try await store.recoverableJournals(lineageID: fixture.repo.target.lineageID).count == 1)
        } else {
            let result = try await service.recoverInterruptedRestore(target: fixture.repo.target, operationID: journal.id, coordination: .clear)
            #expect(result.recoveryCheckpointID == journal.recoveryCheckpointID)
            let after = try await fixture.snapshot()
            #expect(after.paths == before.paths)
            #expect(after.indexChecksum == before.indexChecksum)
            #expect(try await store.recoverableJournals(lineageID: fixture.repo.target.lineageID).isEmpty)
        }
    }

    @Test(arguments: ["disk", "index", "head", "lock", "lineage"])
    func staleStateNeverWritesSelectedFiles(change: String) async throws {
        let fixture = try await CheckpointRestoreFixture.make()
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        switch change {
        case "disk": try fixture.repo.write("concurrent", to: "selected.bin")
        case "index": try await fixture.repo.stage("selected.bin")
        case "head": try await fixture.repo.git(["commit", "--allow-empty", "-m", "concurrent"])
        case "lock": try fixture.repo.write("unrelated lock", to: ".git/index.lock")
        case "lineage":
            let gitDirectory = fixture.repo.root.appendingPathComponent(".git")
            let marker = try #require(FileManager.default.contentsOfDirectory(at: gitDirectory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("lineage") })
            try Data(UUID().uuidString.utf8).write(to: marker)
        default: break
        }
        let disk = try fixture.repo.disk("selected.bin")
        let index = try fixture.repo.disk(".git/index")
        await #expect(throws: (any Error).self) {
            try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                               selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        }
        #expect(try fixture.repo.disk("selected.bin") == disk)
        #expect(try fixture.repo.disk(".git/index") == index)
        if change == "lock" { #expect(try fixture.repo.disk(".git/index.lock") == Data("unrelated lock".utf8)) }
    }

    @Test func lockedRevalidationRejectsChangesAfterPreparation() async throws {
        let fixture = try await CheckpointRestoreFixture.make()
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        let index = try fixture.repo.disk(".git/index")
        let service = WorktreeCheckpointService(store: fixture.store, restoreFaultInjector: .init {
            if $0 == .afterJournalPrepared { try fixture.repo.write("concurrent after preparation", to: "selected.bin") }
        })
        await #expect(throws: CheckpointRestoreError.stalePreview) {
            try await service.restore(target: fixture.repo.target, preview: preview,
                                       selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        }
        #expect(try fixture.repo.disk("selected.bin") == Data("concurrent after preparation".utf8))
        #expect(try fixture.repo.disk(".git/index") == index)
        #expect(try await fixture.store.recoverableJournals(lineageID: fixture.repo.target.lineageID).isEmpty)
    }

    @Test func recoveryRefusesSessionsDirtyBuffersAndReplacedLockInode() async throws {
        let fixture = try await CheckpointRestoreFixture.make(faultInjector: .init {
            if $0 == .beforeIndexInstall { throw CheckpointRestoreFixture.Fault.injected }
            if case .duringRollback = $0 { throw CheckpointRestoreFixture.Fault.injected }
        })
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        await #expect(throws: (any Error).self) {
            try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                               selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        }
        let journals = try await fixture.store.recoverableJournals(lineageID: fixture.repo.target.lineageID)
        let journal = try #require(journals.first)
        let service = WorktreeCheckpointService(store: fixture.store)
        for coordination in [
            CheckpointCoordinationSnapshot(dirtyEditorPaths: [], activeTerminalCount: 1, activeACPCount: 0,
                                            otherGitMutationActive: false, scopeDescription: "Test"),
            .init(dirtyEditorPaths: ["selected.bin"], activeTerminalCount: 0, activeACPCount: 0,
                  otherGitMutationActive: false, scopeDescription: "Test"),
        ] {
            await #expect(throws: (any Error).self) {
                try await service.recoverInterruptedRestore(target: fixture.repo.target, operationID: journal.id, coordination: coordination)
            }
        }
        let lock = fixture.repo.root.appendingPathComponent(".git/index.lock")
        let originalLock = try Data(contentsOf: lock)
        try FileManager.default.moveItem(at: lock, to: fixture.repo.root.appendingPathComponent(".git/displaced-lock"))
        try originalLock.write(to: lock)
        await #expect(throws: (any Error).self) {
            try await service.recoverInterruptedRestore(target: fixture.repo.target, operationID: journal.id, coordination: .clear)
        }
        #expect(try Data(contentsOf: lock) == originalLock)
        #expect(try await fixture.store.recoverableJournals(lineageID: fixture.repo.target.lineageID).count == 1)
    }

    @Test func rollbackPreservesConcurrentSelectedEditAndBackups() async throws {
        let fixture = try await CheckpointRestoreFixture.make()
        defer { fixture.remove() }
        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        try await fixture.later()
        let preview = try await fixture.preview(checkpoint.id)
        let service = WorktreeCheckpointService(store: fixture.store, restoreFaultInjector: .init {
            if $0 == .beforeVerification {
                try fixture.repo.write("concurrent selected edit", to: "selected.bin")
                throw CheckpointRestoreFixture.Fault.injected
            }
        })
        await #expect(throws: (any Error).self) {
            try await service.restore(target: fixture.repo.target, preview: preview,
                                       selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        }
        #expect(try fixture.repo.disk("selected.bin") == Data("concurrent selected edit".utf8))
        let journals = try await fixture.store.recoverableJournals(lineageID: fixture.repo.target.lineageID)
        let journal = try #require(journals.first)
        let name = try #require(journal.stagingNames["selected.bin"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: journal.stagingRoot + "/backups/" + name)) == Data("later disk".utf8))
    }

    @Test func checkpointRefreshScavengesUnjournaledRestoreStaging() async throws {
        let fixture = try await CheckpointRestoreFixture.make()
        defer { fixture.remove() }
        let orphanID = UUID()
        let orphan = fixture.repo.root.appendingPathComponent(".alas-checkpoint-restore-\(orphanID.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan.appendingPathComponent("payload"))

        _ = try await fixture.service.nonterminalJournals(target: fixture.repo.target)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }
}
