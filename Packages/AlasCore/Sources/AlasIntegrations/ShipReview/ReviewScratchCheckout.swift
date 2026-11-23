import CryptoKit
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

private let scratchLogger = Logger(subsystem: "io.nlopez.alas", category: "ReviewScratchCheckouts")

/// The throwaway checkouts a reviewer whose read-only mode Alas can't
/// enforce reviews in, so its edits never reach the user's worktree. One
/// detached linked worktree per ship review, under `root`, moved to each
/// round's head and removed with the reviewer. Local worktrees only.
///
/// Operations on one review run in call order.
@MainActor
public final class ReviewScratchCheckouts {
    private let root: URL
    /// The last operation queued per review.
    private var tails: [ShipReviewID: Task<Void, Never>] = [:]

    public init(root: URL = Paths.reviewCheckoutsDir) {
        self.root = root
    }

    /// Where `id`'s checkout lives: a stable name per worktree and owning session.
    public func directory(for id: ShipReviewID) -> URL {
        let digest = SHA256.hash(data: Data("\(id.worktreeID)\u{0}\(id.sessionID)".utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// `id`'s checkout of `repository` at `sha`, created on first use. A
    /// checkout from an earlier round is moved to `sha` and cleaned, so
    /// nothing a reviewer wrote carries over.
    public func prepare(_ id: ShipReviewID, repository: URL, sha: String) async throws -> URL {
        let directory = directory(for: id)
        let root = root
        try await serialized(id) {
            if Self.isCheckout(directory) {
                try await Self.git(["checkout", "--detach", "--force", sha], in: directory, op: "checkout")
                try await Self.git(["clean", "-fdx"], in: directory, op: "clean")
                return
            }
            // Not a checkout: whatever is there is a leftover.
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // `--force`: a checkout deleted behind git's back is still registered.
            try await Self.git(
                ["worktree", "add", "--force", "--detach", directory.path, sha], in: repository, op: "worktree add"
            )
        }
        return directory
    }

    /// Removes `id`'s checkout, if any, and its registration in the repository.
    public func remove(_ id: ShipReviewID) async {
        let directory = directory(for: id)
        try? await serialized(id) {
            await Self.removeCheckout(directory, prune: false)
        }
    }

    /// Removes every checkout under `root` that none of `live` owns, and
    /// prunes the registrations they leave in their repositories.
    public func pruneLeftovers(keeping live: Set<ShipReviewID>) async {
        let kept = Set(live.map { directory(for: $0).lastPathComponent })
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries where !kept.contains(entry.lastPathComponent) {
            await Self.removeCheckout(entry, prune: true)
        }
    }

    // MARK: - Helpers

    /// Runs `body` after every operation queued for `id` before it.
    private func serialized(_ id: ShipReviewID, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tails[id]
        let task = Task<Void, any Error> {
            await previous?.value
            try await body()
        }
        let tail = Task<Void, Never> { _ = try? await task.value }
        tails[id] = tail
        defer {
            if tails[id] == tail { tails[id] = nil }
        }
        try await task.value
    }

    private nonisolated static func removeCheckout(_ directory: URL, prune: Bool) async {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let commonDir = commonGitDirectory(of: directory)
        if let commonDir, !prune {
            do {
                try await git(["worktree", "remove", "--force", directory.path], in: commonDir, op: "worktree remove")
            } catch {
                scratchLogger.error("Could not remove review checkout: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            scratchLogger.error("Could not delete review checkout: \(error.localizedDescription, privacy: .public)")
        }
        if let commonDir, prune {
            try? await git(["worktree", "prune"], in: commonDir, op: "worktree prune")
        }
    }

    /// A linked worktree whose repository still knows it.
    private nonisolated static func isCheckout(_ directory: URL) -> Bool {
        guard let commonDir = commonGitDirectory(of: directory) else { return false }
        return FileManager.default.fileExists(atPath: commonDir.path)
    }

    /// The repository's git directory, read from the linked worktree's
    /// `.git` file: `gitdir: <common>/worktrees/<name>`.
    private nonisolated static func commonGitDirectory(of directory: URL) -> URL? {
        guard let contents = try? String(contentsOf: directory.appendingPathComponent(".git"), encoding: .utf8),
              contents.hasPrefix("gitdir: ")
        else { return nil }
        let gitDir = URL(fileURLWithPath: contents.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines))
        guard FileManager.default.fileExists(atPath: gitDir.path) else { return nil }
        return gitDir.deletingLastPathComponent().deletingLastPathComponent()
    }

    private nonisolated static func git(_ args: [String], in directory: URL, op: String) async throws {
        let result = try await Process.git(args, cwd: directory, timeout: 300)
        try GitService.assertSuccess(result, op: op)
    }
}
