import Foundation

/// Snapshot of a destructive discard request awaiting user confirmation.
/// `paths` is computed at request time so the alert reflects what the user
/// saw, even if the worktree watcher refreshes `changes` mid-prompt.
struct PendingDiscard: Equatable {
    enum Target: Equatable {
        case file(path: String)
        case folder(path: String, fileCount: Int)
        case all(fileCount: Int)
    }
    let target: Target
    let paths: [String]

    static func alertTitle(for p: PendingDiscard) -> String {
        switch p.target {
        case .file(let path):
            let basename = (path as NSString).lastPathComponent
            return "Discard changes to \u{201C}\(basename)\u{201D}?"
        case .folder(let path, _):
            return "Discard changes under \u{201C}\(path)/\u{201D}?"
        case .all:
            return "Discard all working tree changes?"
        }
    }

    static func alertMessage(for p: PendingDiscard) -> String {
        switch p.target {
        case .file:
            return "This permanently removes your changes to this file. This cannot be undone."
        case .folder(_, let n):
            return "This permanently removes changes to \(n) \(plural(n)) under this folder. This cannot be undone."
        case .all(let n):
            return "This permanently removes changes to \(n) \(plural(n)) (staged, unstaged, and untracked). This cannot be undone."
        }
    }

    private static func plural(_ n: Int) -> String {
        n == 1 ? "file" : "files"
    }
}
