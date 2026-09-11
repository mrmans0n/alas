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

        #expect(throws: CheckpointStoreError.self) { try await store.publish(tooLarge) }
        #expect(try await store.catalog(lineageID: lineageA).summaries.map(\.label) == ["Small"])
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

        #expect(throws: CheckpointStoreError.operationReferencesCheckpoint) {
            try await store.delete(id: checkpoint.manifest.id, lineageID: lineageA)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func blobURL(root: URL, lineageID: String, blob: CheckpointBlobReference) -> URL {
        root.appendingPathComponent(lineageID).appendingPathComponent("blobs").appendingPathComponent(blob.sha256)
    }
}
