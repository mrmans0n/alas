import Foundation

extension Notification.Name {
    /// Posted with the worktree ID as `object` after its reviewed snapshot changes.
    public static let alasReviewedSnapshotDidChange = Notification.Name("alasReviewedSnapshotDidChange")
}

/// The working tree as it was when review feedback last went to an agent,
/// so the next review can show only what changed since.
public struct ReviewedWorkingTreeSnapshot: Codable, Equatable, Sendable {
    /// Git tree object holding the working tree, untracked files included.
    public let tree: String
    public let capturedAt: Date

    public init(tree: String, capturedAt: Date) {
        self.tree = tree
        self.capturedAt = capturedAt
    }
}

/// The latest reviewed snapshot per worktree. Only the newest one is kept:
/// "since last review" never reaches further back.
public struct ReviewedSnapshotStore {
    private let store: any PersistenceStoreProtocol
    private let url: URL

    public init(store: any PersistenceStoreProtocol = PersistenceStore(), url: URL = Paths.reviewSnapshotsFile) {
        self.store = store
        self.url = url
    }

    public func load(worktreeID: String) throws -> ReviewedWorkingTreeSnapshot? {
        try readSnapshots()[worktreeID]
    }

    public func save(_ snapshot: ReviewedWorkingTreeSnapshot, worktreeID: String) throws {
        var snapshots = try readSnapshots()
        snapshots[worktreeID] = snapshot
        try store.write(snapshots, to: url)
    }

    private func readSnapshots() throws -> [String: ReviewedWorkingTreeSnapshot] {
        try store.readIfExists([String: ReviewedWorkingTreeSnapshot].self, from: url) ?? [:]
    }
}
