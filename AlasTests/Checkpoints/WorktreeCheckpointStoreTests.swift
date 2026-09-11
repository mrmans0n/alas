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
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: 3))
        let first = try publication(lineageID: lineageA, label: "Small", bytes: Data([1, 2, 3]))
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
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: 6))
        let recovery = try publication(lineageID: lineageA, label: "Recovery old", bytes: Data([1, 1, 1]), kind: .recovery, createdAt: Date(timeIntervalSince1970: 1))
        let manual = try publication(lineageID: lineageA, label: "Manual old", bytes: Data([2, 2, 2]), createdAt: Date(timeIntervalSince1970: 2))
        let incoming = try publication(lineageID: lineageA, label: "Manual new", bytes: Data([3, 3, 3]), createdAt: Date(timeIntervalSince1970: 3))

        _ = try await store.publish(recovery)
        _ = try await store.publish(manual)
        let catalog = try await store.publish(incoming)

        #expect(catalog.byteCount == 6)
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
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: 1_000))
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

    @Test func sharedReferencesCountOnceTowardByteLimit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeCheckpointStore(root: root, limits: .init(manualCount: 20, recoveryCount: 5, bytes: 3))
        let first = try publication(lineageID: lineageA, label: "One", bytes: Data([7, 8, 9]))
        let second = try publication(lineageID: lineageA, label: "Two", bytes: Data([7, 8, 9]))

        _ = try await store.publish(first)
        #expect(try await store.publish(second).byteCount == 3)
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
