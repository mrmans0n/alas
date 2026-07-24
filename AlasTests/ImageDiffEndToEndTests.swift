import Testing
import Foundation
import AppKit
@testable import Alas

@Suite(.serialized)
struct ImageDiffEndToEndTests {
    @MainActor
    @Test func standalonePairStillDefaultsToSideBySide() {
        let state = ImageDiffPresentationState()
        #expect(state.mode == .sideBySide)
        #expect(state.transform == ImageDiffTransform())
    }

    private func makeRepo() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-imgdiff-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        return tmp
    }

    /// Hardcoded base64 PNGs — `NSBitmapImageRep`-generated images produce
    /// indistinguishable bytes for different colors in the test host (see
    /// Task 4's findings).
    private enum PngFixture {
        /// 1x1 red pixel.
        static let red = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        )!
        /// 1x1 blue pixel.
        static let blue = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC"
        )!
    }

    @Test func endToEndModifiedPngProducesBothImages() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let pngURL = repo.appendingPathComponent("art.png")

        try PngFixture.red.write(to: pngURL)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        try PngFixture.blue.write(to: pngURL)

        let pair = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "art.png", staged: false
        )
        #expect(pair.kind == .modified)
        let before = try #require(pair.beforeImage)
        let after = try #require(pair.afterImage)
        let result = ImageDiffDifferenceComputer.compute(before: before, after: after)
        #expect(result.totalPixels >= 1)
        #expect(result.changedPixelCount >= 1)
    }
}
