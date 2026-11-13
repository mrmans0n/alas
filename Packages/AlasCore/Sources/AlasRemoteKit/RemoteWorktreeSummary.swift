import Foundation

public struct RemoteWorktreeSummary: Codable, Equatable, Sendable {
    public let projectName: String
    public let worktreeName: String
    public let branch: String
    public let path: String
    public let metricsAvailable: Bool
    public let comparisonRef: String?
    public let commitCount: Int
    public let changedFileCount: Int
    public let addedLines: Int
    public let deletedLines: Int
    public let conflictCount: Int
    /// Ordering inputs for a peer's sidebar, so it can follow the owning
    /// Mac's own worktree ordering. Nil from an older peer that predates them.
    public var isMain: Bool? = nil
    public var createdAt: Double? = nil
    public var lastActivity: Double? = nil
    /// True for a folder project, which has no git and so no Changes. Sent
    /// only when true; nil (git, or an older host) keeps today's behavior.
    public var isFolder: Bool? = nil

    public init(projectName: String, worktreeName: String, branch: String, path: String, metricsAvailable: Bool, comparisonRef: String?, commitCount: Int, changedFileCount: Int, addedLines: Int, deletedLines: Int, conflictCount: Int, isMain: Bool? = nil, createdAt: Double? = nil, lastActivity: Double? = nil, isFolder: Bool? = nil) {
        self.projectName = projectName
        self.worktreeName = worktreeName
        self.branch = branch
        self.path = path
        self.metricsAvailable = metricsAvailable
        self.comparisonRef = comparisonRef
        self.commitCount = commitCount
        self.changedFileCount = changedFileCount
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.conflictCount = conflictCount
        self.isMain = isMain
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.isFolder = isFolder
    }
}
