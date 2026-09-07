import Foundation

enum WorktreeStatus: String, Codable {
    case clean, dirty, running
}

struct Worktree: Identifiable, Equatable, Codable {
    let id: String           // stable id derived from absolute path
    let projectId: String
    var name: String         // display name (usually the branch)
    var branch: String
    var path: URL
    /// Nil for legacy or synthetic rows whose identity has not been read from Git.
    var isMainWorktree: Bool?
    var status: WorktreeStatus
    var lastActivity: Date
    var createdAt: Date
    /// Random identity persisted inside this concrete worktree's Git administrative directory.
    var lineageID: String?
    var addedLines: Int = 0
    var deletedLines: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, projectId, name, branch, path, isMainWorktree, status,
             lastActivity, createdAt, lineageID, addedLines, deletedLines
    }

    init(
        id: String,
        projectId: String,
        name: String,
        branch: String,
        path: URL,
        isMainWorktree: Bool? = nil,
        status: WorktreeStatus,
        lastActivity: Date,
        createdAt: Date? = nil,
        lineageID: String? = nil,
        addedLines: Int = 0,
        deletedLines: Int = 0
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.branch = branch
        self.path = path
        self.isMainWorktree = isMainWorktree
        self.status = status
        self.lastActivity = lastActivity
        self.createdAt = createdAt ?? lastActivity
        self.lineageID = lineageID
        self.addedLines = addedLines
        self.deletedLines = deletedLines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectId = try c.decode(String.self, forKey: .projectId)
        name = try c.decode(String.self, forKey: .name)
        branch = try c.decode(String.self, forKey: .branch)
        path = try c.decode(URL.self, forKey: .path)
        isMainWorktree = try c.decodeIfPresent(Bool.self, forKey: .isMainWorktree)
        status = try c.decode(WorktreeStatus.self, forKey: .status)
        lastActivity = try c.decode(Date.self, forKey: .lastActivity)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? lastActivity
        lineageID = try? c.decode(String.self, forKey: .lineageID)
        addedLines = (try? c.decode(Int.self, forKey: .addedLines)) ?? 0
        deletedLines = (try? c.decode(Int.self, forKey: .deletedLines)) ?? 0
    }

    static func makeId(path: URL) -> String {
        path.standardizedFileURL.path
    }
}

struct ChangedFile: Identifiable, Equatable, Codable {
    var id: String { "\(stage.rawValue):\(path)" }
    let path: String
    let status: String   // "A" | "M" | "D" | "R" | "U" (unmerged)
    let stage: ChangeStage
    let add: Int
    let del: Int
    let renameFrom: String?
    /// Non-nil when this file is in a git unmerged (conflicted) state.
    /// Nil for all clean changes. Defaulted for Codable back-compat.
    var conflict: ConflictKind? = nil
}

enum ChangeStage: String, Codable {
    case staged
    case unstaged
}

enum FileVisibility: String, Equatable, Codable {
    case tracked
    case untracked
    case ignored
    case excluded
}

enum DirectoryChildrenState: String, Equatable, Codable {
    case loaded
    case notLoaded
    case loading
    case failed
}

struct FileTreeNode: Identifiable, Equatable, Codable {
    var id: String { "\(kind.rawValue):\(path)" }
    let name: String
    let path: String          // relative to repo root
    let kind: Kind
    var children: [FileTreeNode]?
    var badge: String?        // "A"|"M"|"D"|"R" if status non-empty
    var visibility: FileVisibility = .tracked
    var childrenState: DirectoryChildrenState = .loaded
    var isSubmodule: Bool = false

    enum Kind: String, Codable { case dir, file }

    /// Recursively drops `.ignored`/`.excluded` nodes, but keeps a directory
    /// if any of its (recursively filtered) children remain visible —
    /// gitignore rules don't un-track a path that's already in the index, so
    /// an ignored directory can still contain tracked descendants reachable
    /// only through it. Operates on the EAGER `children` arrays a tree build
    /// populates for a directory with a visible descendant (see
    /// `GitService.fileTree`'s `hasVisibleDescendant` check); a node whose
    /// `children` is nil (lazy, not-yet-loaded) is treated as having none.
    ///
    /// Shared by `FilesTabView.filteredNodes` (native desktop Files tab) and
    /// `AppState.remoteFileNodes` (remote wire boundary) so both surfaces
    /// keep such a directory reachable, without the data-layer function
    /// depending on a SwiftUI view type.
    nonisolated static func filteredKeepingVisibleDescendants(
        _ nodes: [FileTreeNode]
    ) -> [FileTreeNode] {
        nodes.compactMap { node in
            let offGit = node.visibility == .ignored || node.visibility == .excluded
            if node.kind == .file {
                return offGit ? nil : node
            }
            var copy = node
            let visibleChildren = filteredKeepingVisibleDescendants(node.children ?? [])
            copy.children = visibleChildren
            if offGit && visibleChildren.isEmpty {
                return nil
            }
            return copy
        }
    }
}

/// Classification of a git unmerged (conflicted) file. Mirrors git's
/// porcelain=v2 `u XY` two-letter code where each letter is one of
/// `D`eleted, `A`dded, `U`pdated on each side.
enum ConflictKind: String, Codable, Equatable {
    case bothModified       // UU
    case bothAdded          // AA
    case bothDeleted        // DD
    case addedByUs          // AU
    case addedByThem        // UA
    case deletedByUs        // DU
    case deletedByThem      // UD

    /// Returns nil for `XY` pairs that don't represent a conflict.
    static func fromPorcelainXY(_ xy: String) -> ConflictKind? {
        switch xy {
        case "UU": return .bothModified
        case "AA": return .bothAdded
        case "DD": return .bothDeleted
        case "AU": return .addedByUs
        case "UA": return .addedByThem
        case "DU": return .deletedByUs
        case "UD": return .deletedByThem
        default:   return nil
        }
    }
}

/// The three sides of a conflicted file, plus the on-disk merged
/// buffer with conflict markers. Loaded via `GitService.conflictedFile`.
struct ConflictedFile: Equatable {
    let relativePath: String
    let kind: ConflictKind
    let base: String?      // nil for `bothAdded` (no common ancestor)
    let local: String?     // nil for `deletedByUs`
    let remote: String?    // nil for `deletedByThem`
    let merged: String     // the on-disk file with conflict markers
    let isBinary: Bool
}

/// An in-progress conflict-producing operation. Detected by the presence
/// of marker files inside `.git`: `MERGE_HEAD`, `rebase-merge/`,
/// `CHERRY_PICK_HEAD`, or `REVERT_HEAD`.
enum MergeOperation: Equatable {
    /// Merging another branch into the current one.
    /// - sourceBranch: the branch being merged in (read from MERGE_MSG / MERGE_HEAD ref)
    case merge(sourceBranch: String?)

    /// Rebase in progress. `plan` is the parsed contents of
    /// `.git/rebase-merge/git-rebase-todo` plus `done`.
    case rebase(plan: RebasePlan)

    /// Cherry-picking a single commit. `sha` and the first line of the
    /// commit message are exposed for the operation card.
    case cherryPick(sha: String, summary: String)

    /// Reverting a single commit. `sha` and the first line of the commit
    /// message are exposed for the operation card.
    case revert(sha: String, summary: String)
}

struct RebasePlan: Equatable {
    let ontoBranch: String?    // target ref, read from rebase-merge/onto
    let sourceBranch: String?  // original branch, read from rebase-merge/head-name
    let commits: [RebasePlanCommit]
    var currentIndex: Int? {
        commits.firstIndex(where: { $0.state == .current })
    }
}

struct RebasePlanCommit: Equatable {
    enum State: Equatable { case done, current, pending }
    let sha: String          // short SHA as it appears in the todo file
    let summary: String      // first line of commit message
    let state: State
}

/// Outcome of running an operation that may produce conflicts.
enum MergeResult: Equatable {
    case clean
    case conflict(files: [ChangedFile])
    case error(message: String)
}
