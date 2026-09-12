import Foundation
import Testing
@testable import Alas

@Suite("Worktree checkpoint store")
struct WorktreeCheckpointStoreTests {
    private let lineageA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let lineageB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    @Test func publishedCheckpointSurvivesStoreRecreationAndIsIsolatedByLineage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try publication(lineageID: lineageA, label: "Before parser", bytes: Data([0, 255, 1]))
        let store = WorktreeCheckpointStore(root: root)
        _ = try await store.publish(first)

        let reloaded = WorktreeCheckpointStore(root: root)
        #expect(try await reloaded.catalog(lineageID: lineageA).summaries.map(\.label) == ["Before parser"])
        #expect(try await reloaded.catalog(lineageID: lineageB).summaries.isEmpty)
        #expect(try await reloaded.readBlob(first.blobs.keys.first!, lineageID: lineageA) == Data([0, 255, 1]))
    }

    @Test func deletingOneCheckpointRetainsOtherManifestAndSharedBlob() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("shared blob".utf8)
        let first = try publication(lineageID: lineageA, label: "First", bytes: bytes)
        let second = try publication(lineageID: lineageA, label: "Second", bytes: bytes)
        let store = WorktreeCheckpointStore(root: root)
        _ = try await store.publish(first)
        _ = try await store.publish(second)

        _ = try await store.delete(id: first.manifest.id, lineageID: lineageA)

        #expect(try await store.load(id: second.manifest.id, lineageID: lineageA) == second.manifest)
        #expect(try await store.readBlob(second.blobs.keys.first!, lineageID: lineageA) == bytes)
    }

    @Test func publicationOverByteLimitLeavesPreviousCatalogUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try publication(lineageID: lineageA, label: "Small", bytes: Data([1, 2, 3]))
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: try storageCost([first])))
        _ = try await store.publish(first)
        let tooLarge = try publication(lineageID: lineageA, label: "Large", bytes: Data([1, 2, 3, 4]))

        do {
            _ = try await store.publish(tooLarge)
            Issue.record("Expected the byte limit to reject publication")
        } catch let error as CheckpointStoreError {
            #expect(error == .byteLimitExceeded)
        } catch {
            throw error
        }
        #expect(try await store.catalog(lineageID: lineageA).summaries.map(\.label) == ["Small"])
    }

    @Test func byteLimitPrunesOldestRecoveryBeforeManualCheckpoint() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try publication(lineageID: lineageA, label: "Recovery old", bytes: Data([1, 1, 1]), kind: .recovery, createdAt: Date(timeIntervalSince1970: 1))
        let manual = try publication(lineageID: lineageA, label: "Manual old", bytes: Data([2, 2, 2]), createdAt: Date(timeIntervalSince1970: 2))
        let incoming = try publication(lineageID: lineageA, label: "Manual new", bytes: Data([3, 3, 3]), createdAt: Date(timeIntervalSince1970: 3))
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: try storageCost([manual, incoming])))

        _ = try await store.publish(recovery)
        _ = try await store.publish(manual)
        let catalog = try await store.publish(incoming)

        #expect(catalog.byteCount == (try storageCost([manual, incoming])))
        #expect(catalog.summaries.map(\.label) == ["Manual new", "Manual old"])
        await #expect(throws: CheckpointStoreError.checkpointNotFound) {
            try await store.load(id: recovery.manifest.id, lineageID: lineageA)
        }
    }

    @Test func byteLimitRejectsIncomingCheckpointThatCannotFitByItself() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: 2))
        let incoming = try publication(lineageID: lineageA, label: "Too large", bytes: Data([1, 2, 3]))

        await #expect(throws: CheckpointStoreError.byteLimitExceeded) {
            try await store.publish(incoming)
        }
    }

    @Test func activeJournalProtectsItsCheckpointsFromDeletion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = try publication(lineageID: lineageA, label: "Original", bytes: Data([1]))
        let recovery = try publication(lineageID: lineageA, label: "Recovery", bytes: Data([2]), kind: .recovery)
        let store = WorktreeCheckpointStore(root: root)
        _ = try await store.publish(checkpoint)
        _ = try await store.publish(recovery)
        let journal = CheckpointRestoreJournal(lineageID: lineageA, checkpointID: checkpoint.manifest.id, recoveryCheckpointID: recovery.manifest.id, phase: .prepared, stagingRoot: "/tmp/staging", selectedPaths: [], expectedFingerprint: "fingerprint", expectedIndexChecksum: "checksum")
        try await store.writeJournal(journal)

        do {
            _ = try await store.delete(id: checkpoint.manifest.id, lineageID: lineageA)
            Issue.record("Expected the active journal to protect its checkpoint")
        } catch let error as CheckpointStoreError {
            #expect(error == .operationReferencesCheckpoint)
        } catch {
            throw error
        }
        #expect(try await store.recoverableJournals(lineageID: lineageA) == [journal])
    }

    @Test func corruptBlobQuarantinesManifestAndRetainsUnavailableSummary() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = try publication(lineageID: lineageA, label: "Damaged", bytes: Data([1, 2, 3]))
        let store = WorktreeCheckpointStore(root: root)
        _ = try await store.publish(checkpoint)
        let blob = try #require(checkpoint.blobs.keys.first)
        try Data([9]).write(to: blobURL(root: root, lineageID: lineageA, blob: blob))

        let catalog = try await store.catalog(lineageID: lineageA)

        #expect(catalog.summaries.count == 1)
        #expect(catalog.summaries[0].label == "Damaged")
        #expect(catalog.summaries[0].unavailableReason != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(lineageA).appendingPathComponent("quarantine").path).contains { $0.hasPrefix(checkpoint.manifest.id.uuidString.lowercased()) })
    }

    @Test func publishingReplacesCorruptContentAddressedBlob() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3])
        let first = try publication(lineageID: lineageA, label: "Damaged", bytes: bytes, createdAt: Date(timeIntervalSince1970: 1))
        let second = try publication(lineageID: lineageA, label: "Replacement", bytes: bytes, createdAt: Date(timeIntervalSince1970: 2))
        let store = WorktreeCheckpointStore(root: root)
        _ = try await store.publish(first)
        let blob = try #require(first.blobs.keys.first)
        try Data([9]).write(to: blobURL(root: root, lineageID: lineageA, blob: blob))

        let catalog = try await store.publish(second)

        #expect(try await store.readBlob(blob, lineageID: lineageA) == bytes)
        #expect(try await store.load(id: second.manifest.id, lineageID: lineageA) == second.manifest)
        #expect(catalog.summaries.map(\.label) == ["Replacement", "Damaged"])
        #expect(catalog.summaries.first { $0.label == "Damaged" }?.unavailableReason != nil)
    }

    @Test func publishingReusedBlobValidatesExistingFileWithoutReadingItIntoMemory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("shared payload".utf8)
        let first = try publication(lineageID: lineageA, label: "First", bytes: bytes, createdAt: Date(timeIntervalSince1970: 1))
        let second = try publication(lineageID: lineageA, label: "Second", bytes: bytes, createdAt: Date(timeIntervalSince1970: 2))
        _ = try await WorktreeCheckpointStore(root: root).publish(first)
        let store = WorktreeCheckpointStore(root: root, fileSystem: BlobFileDataFailingFileSystem())

        let catalog = try await store.publish(second)

        #expect(catalog.summaries.map(\.label) == ["Second", "First"])
    }

    @Test func materializingBlobStreamsWithoutCallingBlobFileData() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("restore payload".utf8)
        let checkpoint = try publication(lineageID: lineageA, label: "Saved", bytes: bytes)
        _ = try await WorktreeCheckpointStore(root: root).publish(checkpoint)
        let blob = try #require(checkpoint.blobs.keys.first)
        let destination = root.appendingPathComponent("restored.bin")
        let store = WorktreeCheckpointStore(root: root, fileSystem: BlobFileDataFailingFileSystem())

        try await store.materializeBlob(blob, lineageID: lineageA, to: destination, mode: 0o600)

        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test func undecodableManifestRetainsUnavailableSummaryFromPreviousCatalog() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = try publication(lineageID: lineageA, label: "Unreadable manifest", bytes: Data([1, 2, 3]))
        let store = WorktreeCheckpointStore(root: root)
        _ = try await store.publish(checkpoint)
        let manifest = root
            .appendingPathComponent(lineageA)
            .appendingPathComponent("entries")
            .appendingPathComponent(checkpoint.manifest.id.uuidString.lowercased())
            .appendingPathComponent("manifest.json")
        try Data("not json".utf8).write(to: manifest)

        let catalog = try await store.catalog(lineageID: lineageA)

        #expect(catalog.summaries.map(\.label) == ["Unreadable manifest"])
        #expect(catalog.summaries.first?.unavailableReason != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(lineageA).appendingPathComponent("quarantine").path).contains { $0.hasPrefix(checkpoint.manifest.id.uuidString.lowercased()) })
    }

    @Test func deletingUnavailableCheckpointRemovesCatalogSummaryAndQuarantine() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = try publication(lineageID: lineageA, label: "Damaged", bytes: Data([1, 2, 3]))
        let store = WorktreeCheckpointStore(root: root)
        _ = try await store.publish(checkpoint)
        let blob = try #require(checkpoint.blobs.keys.first)
        try Data([9]).write(to: blobURL(root: root, lineageID: lineageA, blob: blob))
        _ = try await store.catalog(lineageID: lineageA)

        let catalog = try await store.delete(id: checkpoint.manifest.id, lineageID: lineageA)

        #expect(catalog.summaries.isEmpty)
        let quarantineNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(lineageA).appendingPathComponent("quarantine").path)
        #expect(!quarantineNames.contains { $0.hasPrefix(checkpoint.manifest.id.uuidString.lowercased()) })
    }

    @Test func corruptCatalogIsQuarantinedAndRebuiltFromValidManifests() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = try publication(lineageID: lineageA, label: "Valid", bytes: Data([1]))
        let store = WorktreeCheckpointStore(root: root)
        _ = try await store.publish(checkpoint)
        try Data("not json".utf8).write(to: root.appendingPathComponent(lineageA).appendingPathComponent("catalog.json"))

        #expect(try await store.catalog(lineageID: lineageA).summaries.map(\.label) == ["Valid"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(lineageA).appendingPathComponent("quarantine").path).contains { $0.hasPrefix("catalog-") })
    }

    @Test func retentionPrunesOldestRecoveryAndManualCheckpoints() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: 100_000))
        for index in 0 ..< 6 {
            _ = try await store.publish(publication(lineageID: lineageA, label: "Recovery \(index)", bytes: Data([UInt8(index)]), kind: .recovery, createdAt: Date(timeIntervalSince1970: Double(index))))
        }
        for index in 0 ..< 21 {
            _ = try await store.publish(publication(lineageID: lineageA, label: "Manual \(index)", bytes: Data([UInt8(index + 20)]), createdAt: Date(timeIntervalSince1970: Double(index + 20))))
        }

        let labels = try await store.catalog(lineageID: lineageA).summaries.map(\.label)
        #expect(!labels.contains("Recovery 0"))
        #expect(!labels.contains("Manual 0"))
        #expect(labels.filter { $0.hasPrefix("Recovery") }.count == 5)
        #expect(labels.filter { $0.hasPrefix("Manual") }.count == 20)
    }

    @Test func retentionDoesNotPruneIncomingCheckpointWhenExistingCheckpointIsProtected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 1, recoveryCount: 5, bytes: 100_000))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = try publication(lineageID: lineageA, label: "Existing", bytes: Data([1]), createdAt: createdAt)
        let incoming = try publication(lineageID: lineageA, label: "Incoming", bytes: Data([2]), createdAt: createdAt)
        _ = try await store.publish(existing)
        try await store.writeJournal(.init(
            lineageID: lineageA,
            checkpointID: existing.manifest.id,
            recoveryCheckpointID: UUID(),
            phase: .prepared,
            stagingRoot: root.appendingPathComponent("staging").path,
            selectedPaths: ["File.swift"],
            expectedFingerprint: "fingerprint",
            expectedIndexChecksum: "checksum"
        ))

        let catalog = try await store.publish(incoming)

        #expect(catalog.summaries.contains { $0.id == incoming.manifest.id })
        #expect(try await store.load(id: incoming.manifest.id, lineageID: lineageA) == incoming.manifest)
    }

    @Test func catalogRefreshDoesNotResurrectPrunedEntriesLeftAfterCatalogPublication() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 1, recoveryCount: 5, bytes: 100_000))
        let first = try publication(lineageID: lineageA, label: "First", bytes: Data([1]), createdAt: Date(timeIntervalSince1970: 1))
        let second = try publication(lineageID: lineageA, label: "Second", bytes: Data([2]), createdAt: Date(timeIntervalSince1970: 2))
        _ = try await store.publish(first)
        _ = try await store.publish(second)
        let orphan = root
            .appendingPathComponent(lineageA)
            .appendingPathComponent("entries")
            .appendingPathComponent(first.manifest.id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try JSONEncoder.checkpoints.encode(first.manifest).write(to: orphan.appendingPathComponent("manifest.json"))

        let catalog = try await WorktreeCheckpointStore(root: root, limits: .init(manualCount: 1, recoveryCount: 5, bytes: 100_000))
            .catalog(lineageID: lineageA)

        #expect(catalog.summaries.map(\.label) == ["Second"])
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func publishedCatalogSurvivesCleanupFailureAfterRetentionPrune() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try publication(lineageID: lineageA, label: "First", bytes: Data([1]), createdAt: Date(timeIntervalSince1970: 1))
        let second = try publication(lineageID: lineageA, label: "Second", bytes: Data([2]), createdAt: Date(timeIntervalSince1970: 2))
        let limits = WorktreeCheckpointStore.Limits(manualCount: 1, recoveryCount: 5, bytes: 100_000)
        _ = try await WorktreeCheckpointStore(root: root, limits: limits).publish(first)
        let fileSystem = RemoveFailingFileSystem(
            failingLastPathComponent: "manifest.json",
            failingParentLastPathComponent: first.manifest.id.uuidString.lowercased()
        )
        let store = WorktreeCheckpointStore(root: root, fileSystem: fileSystem, limits: limits)

        let catalog = try await store.publish(second)
        let orphan = root
            .appendingPathComponent(lineageA)
            .appendingPathComponent("entries")
            .appendingPathComponent(first.manifest.id.uuidString.lowercased(), isDirectory: true)

        #expect(catalog.summaries.map(\.label) == ["Second"])
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        let reloaded = try await WorktreeCheckpointStore(root: root, limits: limits).catalog(lineageID: lineageA)
        #expect(reloaded.summaries.map(\.label) == ["Second"])
        #expect(try await store.catalog(lineageID: lineageA).summaries.map(\.label) == ["Second"])
    }

    @Test func sharedReferencesCountOnceTowardByteLimit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try publication(lineageID: lineageA, label: "One", bytes: Data([7, 8, 9]))
        let second = try publication(lineageID: lineageA, label: "Two", bytes: Data([7, 8, 9]))
        let expectedByteCount = try storageCost([first, second])
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: expectedByteCount))

        _ = try await store.publish(first)
        #expect(try await store.publish(second).byteCount == expectedByteCount)
    }

    @Test func failedCatalogPublicationRemovesPromotedEntry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = CatalogWriteFailingFileSystem(failOnCatalogWriteNumber: 2)
        let store = WorktreeCheckpointStore(root: root, fileSystem: fileSystem)
        let checkpoint = try publication(lineageID: lineageA, label: "Reported failed", bytes: Data([1, 2, 3]))

        await #expect(throws: CatalogWriteFailingFileSystem.Failure.catalogWrite) {
            try await store.publish(checkpoint)
        }

        let reloaded = WorktreeCheckpointStore(root: root)
        #expect(try await reloaded.catalog(lineageID: lineageA).summaries.isEmpty)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(lineageA).appendingPathComponent("entries").path)
        #expect(entries.isEmpty)
        let blob = try #require(checkpoint.blobs.keys.first)
        #expect(!FileManager.default.fileExists(atPath: blobURL(root: root, lineageID: lineageA, blob: blob).path))
    }

    @Test func recoverableJournalsCleanTerminalJournalStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("backup".utf8).write(to: staging.appendingPathComponent("backup"))
        let store = WorktreeCheckpointStore(root: root)
        let journal = CheckpointRestoreJournal(
            lineageID: lineageA,
            checkpointID: UUID(),
            recoveryCheckpointID: UUID(),
            phase: .completed,
            stagingRoot: staging.path,
            selectedPaths: ["File.swift"],
            expectedFingerprint: "fingerprint",
            expectedIndexChecksum: "checksum"
        )
        try await store.writeJournal(journal)

        #expect(try await store.recoverableJournals(lineageID: lineageA).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        let journalNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(lineageA).appendingPathComponent("journals").path)
        #expect(journalNames.isEmpty)
    }

    @Test func recoverableJournalsKeepTerminalJournalWhenStagingCleanupFails() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("backup".utf8).write(to: staging.appendingPathComponent("backup"))
        let fileSystem = RemoveFailingFileSystem(failingLastPathComponent: "backup")
        let store = WorktreeCheckpointStore(root: root, fileSystem: fileSystem)
        let journal = CheckpointRestoreJournal(
            lineageID: lineageA,
            checkpointID: UUID(),
            recoveryCheckpointID: UUID(),
            phase: .completed,
            stagingRoot: staging.path,
            selectedPaths: ["File.swift"],
            expectedFingerprint: "fingerprint",
            expectedIndexChecksum: "checksum"
        )
        try await store.writeJournal(journal)

        await #expect(throws: RemoveFailingFileSystem.Failure.remove) {
            try await store.recoverableJournals(lineageID: lineageA)
        }

        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("backup").path))
        let journalNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(lineageA).appendingPathComponent("journals").path)
        #expect(journalNames == ["\(journal.id.uuidString.lowercased()).json"])
    }

    @Test func catalogReconciliationRemovesAbandonedCheckpointBlobs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = root.appendingPathComponent(lineageA).appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let digest = String(repeating: "a", count: 64)
        let temporary = blobs.appendingPathComponent(".\(digest).tmp")
        let finalized = blobs.appendingPathComponent(digest)
        let unrelated = blobs.appendingPathComponent(".not-a-checkpoint-blob.tmp")
        try Data("abandoned".utf8).write(to: temporary)
        try Data("abandoned".utf8).write(to: finalized)
        try Data("unrelated".utf8).write(to: unrelated)

        let store = WorktreeCheckpointStore(root: root)
        _ = try await store.catalog(lineageID: lineageA)

        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: finalized.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func concurrentStoreInstancesSerializePublicationForSameLineage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try publication(lineageID: lineageA, label: "First", bytes: Data([1]), createdAt: Date(timeIntervalSince1970: 1))
        let second = try publication(lineageID: lineageA, label: "Second", bytes: Data([2]), createdAt: Date(timeIntervalSince1970: 2))
        let gatedFileSystem = CatalogWriteGateFileSystem()
        let firstStore = WorktreeCheckpointStore(root: root, fileSystem: gatedFileSystem)
        let secondStore = WorktreeCheckpointStore(root: root)

        let firstTask = Task {
            try await firstStore.publish(first)
        }
        gatedFileSystem.waitUntilCatalogWriteIsBlocked()

        let secondTask = Task {
            try await secondStore.publish(second)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let secondEntry = root
            .appendingPathComponent(lineageA)
            .appendingPathComponent("entries")
            .appendingPathComponent(second.manifest.id.uuidString.lowercased())
        #expect(!FileManager.default.fileExists(atPath: secondEntry.path))

        gatedFileSystem.unblockCatalogWrite()
        _ = try await firstTask.value
        _ = try await secondTask.value

        let catalog = try await WorktreeCheckpointStore(root: root).catalog(lineageID: lineageA)
        #expect(catalog.summaries.map(\.label) == ["Second", "First"])
        #expect(try await WorktreeCheckpointStore(root: root).readBlob(first.blobs.keys.first!, lineageID: lineageA) == Data([1]))
        #expect(try await WorktreeCheckpointStore(root: root).readBlob(second.blobs.keys.first!, lineageID: lineageA) == Data([2]))
    }

    @Test func catalogReclaimsAbandonedLineageLock() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lineageRoot = root.appendingPathComponent(lineageA, isDirectory: true)
        let lock = lineageRoot.appendingPathComponent(".store.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)],
            ofItemAtPath: lock.path
        )

        let catalog = try await WorktreeCheckpointStore(root: root).catalog(lineageID: lineageA)

        #expect(catalog.summaries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func catalogDoesNotReclaimLiveLineageLockOnlyBecauseItIsOld() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lineageRoot = root.appendingPathComponent(lineageA, isDirectory: true)
        let lock = lineageRoot.appendingPathComponent(".store.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let owner = Data("""
        {
          "createdAt" : "\(ISO8601DateFormatter().string(from: Date()))",
          "pid" : \(getpid())
        }
        """.utf8)
        try owner.write(to: lock.appendingPathComponent("owner.json"))

        let task = Task {
            try await WorktreeCheckpointStore(root: root).catalog(lineageID: lineageA)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(FileManager.default.fileExists(atPath: lock.path))
        try FileManager.default.removeItem(at: lock)
        #expect(try await task.value.summaries.isEmpty)
    }

    @Test func catalogReclaimsLivePidLockWhenOwnerTimestampPredatesProcessStart() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lineageRoot = root.appendingPathComponent(lineageA, isDirectory: true)
        let lock = lineageRoot.appendingPathComponent(".store.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let owner = Data("""
        {
          "createdAt" : "2001-01-01T00:00:00Z",
          "pid" : \(getpid())
        }
        """.utf8)
        try owner.write(to: lock.appendingPathComponent("owner.json"))

        let catalog = try await WorktreeCheckpointStore(root: root).catalog(lineageID: lineageA)

        #expect(catalog.summaries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func stagedAdditionIsNotCountedAsUntracked() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("new file".utf8)
        let blob = CheckpointBlobReference.make(for: bytes)
        let manifest = try WorktreeCheckpointManifest(
            kind: .manual,
            label: "Staged add",
            createdAt: Date(timeIntervalSince1970: 1),
            byteCount: Int64(bytes.count),
            lineageID: lineageA,
            capturedPath: "/tmp/repository",
            repositoryName: "Alas",
            branch: "main",
            headOID: String(repeating: "f", count: 40),
            exclusions: [], groups: [],
            paths: [.init(relativePath: "New.swift", head: .absent, index: .regular(blob: blob, executable: false), worktree: .regular(blob: blob, executable: false))]
        )
        let store = WorktreeCheckpointStore(root: root)

        let summary = try await store.publish(.init(manifest: manifest, blobs: [blob: bytes])).summaries.first

        #expect(summary?.stagedFileCount == 1)
        #expect(summary?.unstagedFileCount == 0)
        #expect(summary?.untrackedFileCount == 0)
    }

    @Test func ordinaryUntrackedFileIsNotDoubleCountedAsUnstaged() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("scratch".utf8)
        let blob = CheckpointBlobReference.make(for: bytes)
        let manifest = try WorktreeCheckpointManifest(
            kind: .manual,
            label: "Untracked",
            createdAt: Date(timeIntervalSince1970: 1),
            byteCount: Int64(bytes.count),
            lineageID: lineageA,
            capturedPath: "/tmp/repository",
            repositoryName: "Alas",
            branch: "main",
            headOID: String(repeating: "f", count: 40),
            exclusions: [], groups: [],
            paths: [.init(relativePath: "Scratch.swift", head: .absent, index: .absent, worktree: .regular(blob: blob, executable: false))]
        )
        let store = WorktreeCheckpointStore(root: root)

        let summary = try await store.publish(.init(manifest: manifest, blobs: [blob: bytes])).summaries.first

        #expect(summary?.stagedFileCount == 0)
        #expect(summary?.unstagedFileCount == 0)
        #expect(summary?.untrackedFileCount == 1)
    }

    private func publication(lineageID: String, label: String, bytes: Data, kind: CheckpointKind = .manual, createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> CheckpointPublication {
        let blob = CheckpointBlobReference.make(for: bytes)
        let manifest = try WorktreeCheckpointManifest(
            kind: kind,
            label: label,
            createdAt: createdAt,
            byteCount: Int64(bytes.count),
            lineageID: lineageID,
            capturedPath: "/tmp/repository",
            repositoryName: "Alas",
            branch: "main",
            headOID: String(repeating: "f", count: 40),
            exclusions: [], groups: [],
            paths: [.init(relativePath: "File.swift", head: .regular(blob: blob, executable: false), index: .regular(blob: blob, executable: false), worktree: .regular(blob: blob, executable: false))]
        )
        return CheckpointPublication(manifest: manifest, blobs: [blob: bytes])
    }

    private func storageCost(_ publications: [CheckpointPublication]) throws -> Int64 {
        let manifestBytes = try publications.reduce(into: Int64(0)) { total, publication in
            total += Int64(try JSONEncoder.checkpoints.encode(publication.manifest).count)
        }
        var uniqueBlobs: [CheckpointBlobReference: Data] = [:]
        for publication in publications {
            for (reference, data) in publication.blobs {
                uniqueBlobs[reference] = data
            }
        }
        let blobBytes = uniqueBlobs.values.reduce(into: Int64(0)) { total, data in
            total += Int64(data.count)
        }
        return manifestBytes + blobBytes
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func blobURL(root: URL, lineageID: String, blob: CheckpointBlobReference) -> URL {
        root.appendingPathComponent(lineageID).appendingPathComponent("blobs").appendingPathComponent(blob.sha256)
    }
}

private final class CatalogWriteFailingFileSystem: CheckpointFileSystem, @unchecked Sendable {
    enum Failure: Error, Equatable { case catalogWrite }

    private let live = LiveCheckpointFileSystem()
    private let lock = NSLock()
    private let failOnCatalogWriteNumber: Int
    private var catalogWriteCount = 0

    init(failOnCatalogWriteNumber: Int) {
        self.failOnCatalogWriteNumber = failOnCatalogWriteNumber
    }

    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead {
        try live.readLeaf(root: root, relativePath: relativePath)
    }

    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata? {
        try live.metadata(root: root, relativePath: relativePath)
    }

    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL {
        try live.validateRelativePath(relativePath, under: root)
    }

    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws {
        try live.createDirectoryExclusively(url, mode: mode)
    }

    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws {
        if url.lastPathComponent == "catalog.json" {
            lock.lock()
            catalogWriteCount += 1
            let shouldFail = catalogWriteCount == failOnCatalogWriteNumber
            lock.unlock()
            if shouldFail { throw Failure.catalogWrite }
        }
        try live.writeDurable(data, to: url, mode: mode)
    }

    func createSymlink(target: Data, at url: URL) throws {
        try live.createSymlink(target: target, at: url)
    }

    func move(_ source: URL, to destination: URL) throws {
        try live.move(source, to: destination)
    }

    func moveExclusively(_ source: URL, to destination: URL) throws {
        try live.moveExclusively(source, to: destination)
    }

    func removeIfPresent(_ url: URL) throws {
        try live.removeIfPresent(url)
    }

    func list(_ url: URL) throws -> [URL] {
        try live.list(url)
    }

    func fileData(_ url: URL) throws -> Data {
        try live.fileData(url)
    }

    func synchronizeDirectory(_ url: URL) throws {
        try live.synchronizeDirectory(url)
    }
}

private final class RemoveFailingFileSystem: CheckpointFileSystem, @unchecked Sendable {
    enum Failure: Error, Equatable { case remove }

    private let live = LiveCheckpointFileSystem()
    private let failingLastPathComponent: String
    private let failingParentLastPathComponent: String?

    init(failingLastPathComponent: String, failingParentLastPathComponent: String? = nil) {
        self.failingLastPathComponent = failingLastPathComponent
        self.failingParentLastPathComponent = failingParentLastPathComponent
    }

    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead {
        try live.readLeaf(root: root, relativePath: relativePath)
    }

    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata? {
        try live.metadata(root: root, relativePath: relativePath)
    }

    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL {
        try live.validateRelativePath(relativePath, under: root)
    }

    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws {
        try live.createDirectoryExclusively(url, mode: mode)
    }

    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws {
        try live.writeDurable(data, to: url, mode: mode)
    }

    func createSymlink(target: Data, at url: URL) throws {
        try live.createSymlink(target: target, at: url)
    }

    func move(_ source: URL, to destination: URL) throws {
        try live.move(source, to: destination)
    }

    func moveExclusively(_ source: URL, to destination: URL) throws {
        try live.moveExclusively(source, to: destination)
    }

    func removeIfPresent(_ url: URL) throws {
        if url.lastPathComponent == failingLastPathComponent,
           failingParentLastPathComponent == nil || url.deletingLastPathComponent().lastPathComponent == failingParentLastPathComponent {
            throw Failure.remove
        }
        try live.removeIfPresent(url)
    }

    func list(_ url: URL) throws -> [URL] {
        try live.list(url)
    }

    func fileData(_ url: URL) throws -> Data {
        try live.fileData(url)
    }

    func synchronizeDirectory(_ url: URL) throws {
        try live.synchronizeDirectory(url)
    }
}

private final class BlobFileDataFailingFileSystem: CheckpointFileSystem, @unchecked Sendable {
    enum Failure: Error { case blobFileData(URL) }

    private let live = LiveCheckpointFileSystem()

    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead {
        try live.readLeaf(root: root, relativePath: relativePath)
    }

    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata? {
        try live.metadata(root: root, relativePath: relativePath)
    }

    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL {
        try live.validateRelativePath(relativePath, under: root)
    }

    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws {
        try live.createDirectoryExclusively(url, mode: mode)
    }

    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws {
        try live.writeDurable(data, to: url, mode: mode)
    }

    func createSymlink(target: Data, at url: URL) throws {
        try live.createSymlink(target: target, at: url)
    }

    func move(_ source: URL, to destination: URL) throws {
        try live.move(source, to: destination)
    }

    func moveExclusively(_ source: URL, to destination: URL) throws {
        try live.moveExclusively(source, to: destination)
    }

    func removeIfPresent(_ url: URL) throws {
        try live.removeIfPresent(url)
    }

    func list(_ url: URL) throws -> [URL] {
        try live.list(url)
    }

    func fileData(_ url: URL) throws -> Data {
        if url.deletingLastPathComponent().lastPathComponent == "blobs" {
            throw Failure.blobFileData(url)
        }
        return try live.fileData(url)
    }

    func synchronizeDirectory(_ url: URL) throws {
        try live.synchronizeDirectory(url)
    }
}

private final class CatalogWriteGateFileSystem: CheckpointFileSystem, @unchecked Sendable {
    private let live = LiveCheckpointFileSystem()
    private let didBlock = DispatchSemaphore(value: 0)
    private let unblock = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false

    func waitUntilCatalogWriteIsBlocked() {
        didBlock.wait()
    }

    func unblockCatalogWrite() {
        unblock.signal()
    }

    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead {
        try live.readLeaf(root: root, relativePath: relativePath)
    }

    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata? {
        try live.metadata(root: root, relativePath: relativePath)
    }

    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL {
        try live.validateRelativePath(relativePath, under: root)
    }

    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws {
        try live.createDirectoryExclusively(url, mode: mode)
    }

    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws {
        if url.lastPathComponent == "catalog.json" {
            lock.lock()
            let shouldBlock = !hasBlocked
            if shouldBlock { hasBlocked = true }
            lock.unlock()
            if shouldBlock {
                didBlock.signal()
                unblock.wait()
            }
        }
        try live.writeDurable(data, to: url, mode: mode)
    }

    func createSymlink(target: Data, at url: URL) throws {
        try live.createSymlink(target: target, at: url)
    }

    func move(_ source: URL, to destination: URL) throws {
        try live.move(source, to: destination)
    }

    func moveExclusively(_ source: URL, to destination: URL) throws {
        try live.moveExclusively(source, to: destination)
    }

    func removeIfPresent(_ url: URL) throws {
        try live.removeIfPresent(url)
    }

    func list(_ url: URL) throws -> [URL] {
        try live.list(url)
    }

    func fileData(_ url: URL) throws -> Data {
        try live.fileData(url)
    }

    func synchronizeDirectory(_ url: URL) throws {
        try live.synchronizeDirectory(url)
    }
}
