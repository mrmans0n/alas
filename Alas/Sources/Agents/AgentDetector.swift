import Foundation

enum AgentDetector {
    /// For each agent in `agents`, decide whether it's installed:
    ///   - if `binaryOverride` is set, the override path must exist and be
    ///     executable (tilde-expanded);
    ///   - else if `binary` looks like a path (`/foo`, `./foo`, `~/foo`),
    ///     resolve it directly the same way;
    ///   - otherwise scan the colon-separated `path` for `binary`.
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
                if isExecutable(atPath: expandTilde(trimmed)) {
                    found.insert(agent.id)
                }
                continue
            }
            // Custom agents can enter absolute or tilde paths in the
            // binary field. Resolve those directly instead of trying to
            // find them on PATH (which would silently fail).
            if looksLikePath(agent.binary) {
                if isExecutable(atPath: expandTilde(agent.binary)) {
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

    private static func looksLikePath(_ s: String) -> Bool {
        s.hasPrefix("/") || s.hasPrefix("~") || s.contains("/")
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
