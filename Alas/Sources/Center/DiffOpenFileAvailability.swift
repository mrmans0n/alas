import Foundation

/// Describes whether a diffed file can be opened in a normal file panel.
enum DiffOpenFileAvailability: Equatable {
    case available
    case unavailable(reason: String)

    /// True when the file exists on disk and is not a directory.
    static func isAvailable(worktreePath: URL, relativePath: String) -> Bool {
        let absolute = worktreePath.appendingPathComponent(relativePath)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: absolute.path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }
}
