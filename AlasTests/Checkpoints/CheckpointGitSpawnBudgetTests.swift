import Foundation
import Testing
@testable import Alas

/// Pins how many git processes each checkpoint operation spawns. Git stays
/// real; the runner only counts. Lower a budget when a change removes spawns,
/// and justify any increase.
struct CheckpointGitSpawnBudgetTests {
    @Test(arguments: [(true, 14), (false, 13)])
    func snapshotSpawnBudget(retainingPayloads: Bool, budget: Int) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }

        _ = try await fixture.snapshotter.snapshot(target: fixture.repo.target, retainingPayloads: retainingPayloads)

        #expect(fixture.git.drain().count == budget)
    }

    @Test func capturePreviewAndRestoreSpawnBudgets() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }

        let checkpoint = try await fixture.service.createManual(target: fixture.repo.target, label: "Saved")
        #expect(fixture.git.drain().count == 27)

        for path in Fixture.paths { try fixture.repo.write("later \(path)\n", to: path) }
        let preview = try await fixture.service.restorePreview(target: fixture.repo.target, id: checkpoint.id, coordination: .clear)
        #expect(preview.blocker == nil)
        #expect(fixture.git.drain().count == 15)

        let result = try await fixture.service.restore(target: fixture.repo.target, preview: preview,
                                                       selectedGroupIDs: preview.selectedGroupIDs, coordination: .clear)
        #expect(result.restoredPaths == Fixture.paths)
        #expect(fixture.git.drain().count == 64)
    }

    /// Three committed files, each modified only in the worktree, so every
    /// candidate has a HEAD and an index entry with the same object.
    private struct Fixture {
        static let paths = ["a.txt", "b.txt", "c.txt"]
        let repo: CheckpointTestRepository
        let storeRoot: URL
        let git: CountingCheckpointGitRunner
        let snapshotter: WorktreeStateSnapshotter
        let service: WorktreeCheckpointService

        static func make() async throws -> Self {
            let repo = try await CheckpointTestRepository.makeFromTemplate()
            for path in paths { try repo.write("baseline \(path)\n", to: path) }
            try await repo.commitAll("baseline")
            for path in paths { try repo.write("saved \(path)\n", to: path) }
            let storeRoot = URL(fileURLWithPath: "/private/tmp/checkpoint-budget-store-\(UUID().uuidString)")
            let git = CountingCheckpointGitRunner()
            let snapshotter = WorktreeStateSnapshotter(git: git)
            return .init(repo: repo, storeRoot: storeRoot, git: git, snapshotter: snapshotter,
                         service: WorktreeCheckpointService(store: .init(root: storeRoot), snapshotter: snapshotter))
        }

        func remove() {
            repo.remove()
            try? FileManager.default.removeItem(at: storeRoot)
        }
    }
}

/// Forwards every call to the live runner and records each spawned argv.
final class CountingCheckpointGitRunner: CheckpointGitRunning, @unchecked Sendable {
    private let live = LiveCheckpointGitRunner()
    private let lock = NSLock()
    private var commands: [[String]] = []

    /// Returns the commands recorded since the last drain.
    func drain() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        let drained = commands
        commands = []
        return drained
    }

    private func record(_ args: [String]) {
        lock.lock()
        commands.append(args)
        lock.unlock()
    }

    func run(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResult {
        record(args)
        return try await live.run(args, cwd: cwd, environment: environment)
    }

    func runData(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResultData {
        record(args)
        return try await live.runData(args, cwd: cwd, environment: environment)
    }

    func blobSizes(oids: [String], cwd: URL) async throws -> [String: Int64] {
        if !oids.isEmpty { record(["cat-file", "--batch-check"]) }
        return try await live.blobSizes(oids: oids, cwd: cwd)
    }

    func blobContents(oids: [String], cwd: URL) async throws -> [String: Data] {
        if !oids.isEmpty { record(["cat-file", "--batch"]) }
        return try await live.blobContents(oids: oids, cwd: cwd)
    }

    func blobReferences(oids: [String], cwd: URL) async throws -> [String: CheckpointBlobReference] {
        if !oids.isEmpty { record(["cat-file", "--batch"]) }
        return try await live.blobReferences(oids: oids, cwd: cwd)
    }
}
