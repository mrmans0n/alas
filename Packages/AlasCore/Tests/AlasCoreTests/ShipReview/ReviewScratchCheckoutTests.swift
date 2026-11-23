import AlasCore
import Foundation
import Testing

/// Throwaway review checkouts of a real repository.
@MainActor
struct ReviewScratchCheckoutTests {
    private let id = ShipReviewID(worktreeID: "wt-1", sessionID: "s1")

    /// A repository with three commits and an empty checkouts root.
    private func fixture() async throws -> (repo: URL, checkouts: ReviewScratchCheckouts, shas: [String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-review-checkouts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo")
        let shas = try await GitTemplate.repositoryAheadOfOrigin(at: repo)
        return (repo, ReviewScratchCheckouts(root: root.appendingPathComponent("checkouts")), shas)
    }

    private func git(_ args: [String], in directory: URL) async throws -> String {
        let result = try await Process.git(args, cwd: directory)
        try GitService.assertSuccess(result, op: args[0])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func movingToTheNextHeadDropsWhatTheReviewerWrote() async throws {
        let (repo, checkouts, shas) = try await fixture()
        let checkout = try await checkouts.prepare(id, repository: repo, sha: shas[0])
        try "edit".write(to: checkout.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)

        let moved = try await checkouts.prepare(id, repository: repo, sha: shas[1])

        #expect(moved == checkout)
        #expect(try await git(["rev-parse", "HEAD"], in: moved) == shas[1])
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("stray.txt").path))
    }

    @Test func removeDeletesTheCheckoutAndItsRegistration() async throws {
        let (repo, checkouts, shas) = try await fixture()
        let checkout = try await checkouts.prepare(id, repository: repo, sha: shas[0])

        await checkouts.remove(id)

        #expect(!FileManager.default.fileExists(atPath: checkout.path))
        #expect(try await !git(["worktree", "list"], in: repo).contains(checkout.lastPathComponent))
    }

    @Test func pruneLeftoversRemovesCheckoutsNoLiveReviewOwns() async throws {
        let (repo, checkouts, shas) = try await fixture()
        let orphanID = ShipReviewID(worktreeID: "wt-1", sessionID: "gone")
        let kept = try await checkouts.prepare(id, repository: repo, sha: shas[0])
        let orphan = try await checkouts.prepare(orphanID, repository: repo, sha: shas[0])

        await checkouts.pruneLeftovers(keeping: [id])

        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try await !git(["worktree", "list"], in: repo).contains(orphan.lastPathComponent))
    }
}
