import AppKit
import Testing
@testable import Alas

struct CheckpointDiffLoaderTests {
    @Test func textDiffUsesCheckpointBeforeCurrentAfterWithoutMutation() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("checkpoint text\n", to: "file.txt")
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try repo.write("current text\n", to: "file.txt")
        let before = try await repo.status()
        guard case .text(let diff) = await service.diffContent(target: repo.target, id: checkpoint.id, path: "file.txt") else {
            Issue.record("Expected text diff")
            return
        }
        let lines = diff.hunks.flatMap(\.lines)
        #expect(lines.filter { $0.kind == .delete }.map(\.text) == ["checkpoint text"])
        #expect(lines.filter { $0.kind == .add }.map(\.text) == ["current text"])
        #expect(try await repo.status() == before)
        _ = try await service.delete(target: repo.target, id: checkpoint.id)
        guard case .unavailable = await service.diffContent(target: repo.target, id: checkpoint.id, path: "file.txt") else {
            Issue.record("Deleted checkpoint must be unavailable")
            return
        }
    }

    @Test func binarySizesAndMissingBlobAreExplicit() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let saved = Data([0, 255, 1])
        try repo.write(saved, to: "file.dat")
        let root = repo.root.appendingPathComponent(".git/checkpoints")
        let service = WorktreeCheckpointService(store: .init(root: root))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try repo.write(Data([0, 254, 2, 3, 4]), to: "file.dat")
        guard case .binary(let before, let after) = await service.diffContent(target: repo.target, id: checkpoint.id, path: "file.dat") else {
            Issue.record("Expected binary diff")
            return
        }
        #expect(before == 3)
        #expect(after == 5)
        let blob = root.appendingPathComponent(repo.target.lineageID).appendingPathComponent("blobs").appendingPathComponent(CheckpointBlobReference.make(for: saved).sha256)
        try FileManager.default.removeItem(at: blob)
        guard case .unavailable = await service.diffContent(target: repo.target, id: checkpoint.id, path: "file.dat") else {
            Issue.record("Missing blob must be unavailable")
            return
        }
    }

    @Test @MainActor func imagesKeepBothSidesAndFrameCounts() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let first = try png(width: 2)
        let second = try png(width: 3)
        try repo.write(first, to: "image.png")
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try repo.write(second, to: "image.png")
        guard case .image(let pair) = await service.diffContent(target: repo.target, id: checkpoint.id, path: "image.png") else {
            Issue.record("Expected image diff")
            return
        }
        #expect(pair.beforeImage?.size.width == 2)
        #expect(pair.afterImage?.size.width == 3)
        #expect(pair.beforeFrameCount == 1)
        #expect(pair.afterFrameCount == 1)
    }

    @MainActor private func png(width: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<width { bitmap.setColor(.red, atX: x, y: 0) }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
