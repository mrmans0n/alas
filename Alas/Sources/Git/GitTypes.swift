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
    var status: WorktreeStatus
    var lastActivity: Date
    var addedLines: Int = 0
    var deletedLines: Int = 0

    static func makeId(path: URL) -> String {
        path.standardizedFileURL.path
    }
}

struct ChangedFile: Identifiable, Equatable, Codable {
    var id: String { "\(stage.rawValue):\(path)" }
    let path: String
    let status: String   // "A" | "M" | "D" | "R"
    let stage: ChangeStage
    let add: Int
    let del: Int
    let renameFrom: String?
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
}
