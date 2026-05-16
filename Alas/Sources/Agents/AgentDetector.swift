import Foundation

enum AgentDetector {
    /// For each agent in `agents`, decide whether it's installed:
    ///   - if `binaryOverride` is set, the override path must exist and be
    ///     executable
    ///   - otherwise scan the colon-separated `path` for `binary`
    /// Returns the set of installed agent ids.
    static func scan(
        path: String,
        agents: [AgentDefinition]
    ) async -> Set<String> {
        let dirs = path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        var found: Set<String> = []
        for agent in agents {
            if let trimmed = agent.binaryOverride?.trimmingCharacters(in: .whitespaces),
               !trimmed.isEmpty {
                if isExecutable(atPath: trimmed) {
                    found.insert(agent.id)
                }
                continue
            }
            if isExecutable(named: agent.binary, in: dirs) {
                found.insert(agent.id)
            }
        }
        return found
    }

    /// Scan the running process's `PATH`, augmented with well-known CLI
    /// install directories that the launchd-derived PATH for a GUI app
    /// otherwise omits.
    static func scanCurrentEnvironment(agents: [AgentDefinition]) async -> Set<String> {
        return await scan(path: AgentPath.augmented(), agents: agents)
    }

    private static func isExecutable(named name: String, in dirs: [String]) -> Bool {
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if isExecutable(atPath: candidate) { return true }
        }
        return false
    }

    private static func isExecutable(atPath path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir)
            && !isDir.boolValue
            && fm.isExecutableFile(atPath: path)
    }
}
