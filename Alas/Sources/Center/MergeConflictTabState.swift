import Foundation

/// Persisted state for a merge-conflict resolution tab. The runtime
/// model (current conflict index, edited buffer, parsed regions) lives
/// in `MergeConflictTabModel` and is re-created on tab re-open.
struct MergeConflictTabState: Codable, Equatable, Identifiable {
    let id: TabID                 // "merge:<worktreeId>:<relativePath>"
    let worktreeId: String
    var projectId: String?
    let relativePath: String
    var title: String             // file's last path component
    /// Whether the BASE section is rendered inline in the RESULT column.
    /// Persists per-tab so the user's preference survives app restarts.
    var showBase: Bool

    init(worktreeId: String, projectId: String? = nil, relativePath: String, title: String, showBase: Bool = false) {
        self.id = projectId.map { "merge-project:\($0):\(worktreeId):\(relativePath)" }
            ?? "merge:\(worktreeId):\(relativePath)"
        self.worktreeId = worktreeId
        self.projectId = projectId
        self.relativePath = relativePath
        self.title = title
        self.showBase = showBase
    }
}
