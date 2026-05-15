import Foundation

enum CommitAIDetector {
    /// Scan a `PATH`-style colon-separated string for each supported CLI.
    /// Returns the detected tools in `CommitAITool.detectable` order so the
    /// UI list stays stable across calls.
    static func scan(path: String) async -> [CommitAITool] {
        let dirs = path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard !dirs.isEmpty else { return [] }
        var found: [CommitAITool] = []
        for tool in CommitAITool.detectable {
            guard let bin = tool.binary else { continue }
            if isExecutable(named: bin, in: dirs) {
                found.append(tool)
            }
        }
        return found
    }

    /// Scan the running process's `PATH`, augmented with well-known CLI
    /// install directories that the launchd-derived PATH for a GUI app
    /// otherwise omits. Used at app launch and from Settings.
    static func scanCurrentEnvironment() async -> [CommitAITool] {
        return await scan(path: CommitAIPath.augmented())
    }

    private static func isExecutable(named name: String, in dirs: [String]) -> Bool {
        let fm = FileManager.default
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir),
               !isDir.boolValue,
               fm.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }
}
