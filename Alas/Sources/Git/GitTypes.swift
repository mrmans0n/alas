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
    var id: String { path }
    let path: String
    let status: String   // "A" | "M" | "D" | "R"
    let add: Int
    let del: Int
    let renameFrom: String?
}

struct FileTreeNode: Identifiable, Equatable, Codable {
    var id: String { path }
    let name: String
    let path: String          // relative to repo root
    let kind: Kind
    var children: [FileTreeNode]?
    var badge: String?        // "A"|"M"|"D"|"R" if status non-empty

    enum Kind: String, Codable { case dir, file }
}
