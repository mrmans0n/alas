import Foundation

/// Describes whether a diffed file can be opened in a normal file panel.
enum DiffOpenFileAvailability: Equatable {
    case available
    case unavailable(reason: String)

    /// True when the file can be opened by the editor path. Remote worktrees are
    /// loaded over SSH, so local filesystem existence is not a useful gate.
    static func isAvailable(worktreePath: URL, relativePath: String) -> Bool {
        if worktreePath.isRemoteAlasPath { return true }
        let absolute = worktreePath.appendingPathComponent(relativePath)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: absolute.path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }
}
