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

    private func publication(lineageID: String, label: String, bytes: Data, kind: CheckpointKind = .manual) throws -> CheckpointPublication {
        let blob = CheckpointBlobReference.make(for: bytes)
        let manifest = try WorktreeCheckpointManifest(
            kind: kind,
            label: label,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
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
}
