import Foundation
import Testing
@testable import Alas

struct WorktreeCheckpointCaptureTests {
    @Test func manualCapturePersistsExactStateWithoutChangingRepository() async throws {
        let fixture = try await CheckpointCaptureFixture.make()
        defer { fixture.remove() }
        try fixture.repo.write("secret", to: ".env")
        let before = try await WorktreeStateSnapshotter.live.snapshot(target: fixture.target)
        let status = try await fixture.repo.status()
        let service = fixture.service()
        let summary = try await service.createManual(target: fixture.target, label: "  Before edit  ")
        #expect(summary.label == "Before edit")
        #expect(summary.kind == .manual)
        #expect(summary.stagedFileCount == 1)
        #expect(summary.unstagedFileCount == 1)
        let manifest = try await service.manifest(target: fixture.target, id: summary.id)
        #expect(manifest.exclusions == [.init(relativePath: ".env", reason: .likelySecret)])
        let path = try #require(manifest.paths.first)
        #expect(try await fixture.payload(path.head) == Data("original\n".utf8))
        #expect(try await fixture.payload(path.index) == Data("staged\n".utf8))
        #expect(try await fixture.payload(path.worktree) == Data("first\n".utf8))
        #expect(manifest.byteCount == 22)
        let after = try await WorktreeStateSnapshotter.live.snapshot(target: fixture.target)
        #expect(after.headOID == before.headOID)
        #expect(after.indexChecksum == before.indexChecksum)
        #expect(after.paths == before.paths)
        #expect(try await fixture.repo.status() == status)
        #expect(try fixture.repo.disk("file.swift") == Data("first\n".utf8))
        #expect(try await fixture.service().summaries(target: fixture.target).summaries == [summary])
        #expect(try await fixture.service().delete(target: fixture.target, id: summary.id).summaries.isEmpty)
    }

    @Test func captureRetriesOneConcurrentChangeAndPublishesOneStableCheckpoint() async throws {
        let fixture = try await CheckpointCaptureFixture.make()
        defer { fixture.remove() }
        let service = fixture.service(hooks: .init(afterPayloadStaging: { attempt in
            if attempt == 1 { try fixture.repo.write("second\n", to: "file.swift") }
        }))
        let summary = try await service.createManual(target: fixture.target, label: "Before edit")
        #expect(try await service.summaries(target: fixture.target).summaries == [summary])
        let manifest = try await service.manifest(target: fixture.target, id: summary.id)
        #expect(try await fixture.payload(#require(manifest.paths.first).worktree) == Data("second\n".utf8))
        let discarded = fixture.blobs.appendingPathComponent(CheckpointBlobReference.make(for: Data("first\n".utf8)).sha256)
        #expect(!FileManager.default.fileExists(atPath: discarded.path))
    }

    @Test func repeatedConcurrentChangesPublishNothing() async throws {
        let fixture = try await CheckpointCaptureFixture.make()
        defer { fixture.remove() }
        let service = fixture.service(hooks: .init(afterPayloadStaging: { attempt in
            try fixture.repo.write("change \(attempt)\n", to: "file.swift")
        }))
        await #expect(throws: CheckpointCaptureError.unstableWorktree) {
            try await service.createManual(target: fixture.target, label: "Before edit")
        }
        #expect(try await service.summaries(target: fixture.target).summaries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.blobs.path).isEmpty)
    }

    @Test func blankLabelFailsBeforeAccessingGit() async throws {
        let fixture = try await CheckpointCaptureFixture.make()
        defer { fixture.remove() }
        fixture.repo.remove()
        await #expect(throws: CheckpointModelError.invalidLabel) {
            try await fixture.service().createManual(target: fixture.target, label: " \n ")
        }
    }

    @Test func recoveryPublishesOnlySelectedCurrentStates() async throws {
        let fixture = try await CheckpointCaptureFixture.make()
        defer { fixture.remove() }
        try fixture.repo.write("unrelated", to: "other.swift")
        let current = try await WorktreeStateSnapshotter.live.snapshot(target: fixture.target)
        let service = fixture.service()
        let summary = try await service.createRecovery(target: fixture.target, current: current, selectedPaths: ["file.swift"])
        #expect(summary.kind == .recovery)
        #expect(summary.label == "Before checkpoint restore")
        let manifest = try await service.manifest(target: fixture.target, id: summary.id)
        #expect(manifest.paths == [try #require(current.paths["file.swift"])])
        #expect(manifest.groups.flatMap(\.memberPaths) == ["file.swift"])
        #expect(manifest.byteCount == 22)
        #expect(try await fixture.payload(#require(manifest.paths.first).worktree) == Data("first\n".utf8))
        #expect(try await service.summaries(target: fixture.target).summaries == [summary])
    }
}

private struct CheckpointCaptureFixture: Sendable {
    let repo: CheckpointTestRepository
    let storeRoot: URL
    var target: CheckpointWorktreeTarget { repo.target }
    var blobs: URL { storeRoot.appendingPathComponent(target.lineageID).appendingPathComponent("blobs") }

    static func make() async throws -> Self {
        let repo = try await CheckpointTestRepository.make()
        try repo.write("original\n", to: "file.swift")
        try await repo.commitAll("file")
        try repo.write("staged\n", to: "file.swift")
        try await repo.stage("file.swift")
        try repo.write("first\n", to: "file.swift")
        return Self(repo: repo, storeRoot: URL(fileURLWithPath: "/private/tmp/checkpoint-store-\(UUID().uuidString)"))
    }

    func service(hooks: CheckpointCaptureHooks = .none) -> WorktreeCheckpointService {
        .init(store: WorktreeCheckpointStore(root: storeRoot), hooks: hooks)
    }

    func payload(_ state: CheckpointFileState) async throws -> Data {
        try await WorktreeCheckpointStore(root: storeRoot).readBlob(#require(state.blob), lineageID: target.lineageID)
    }

    func remove() {
        repo.remove()
        try? FileManager.default.removeItem(at: storeRoot)
    }
}
