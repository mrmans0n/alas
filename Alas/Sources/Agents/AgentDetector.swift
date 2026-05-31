import Foundation

enum AgentDetector {
    /// For each agent in `agents`, decide whether it's installed. The
    /// same rule applies to `binaryOverride` and `binary`:
    ///   - path-shaped values (`/foo`, `./foo`, `~/foo`, anything
    ///     containing `/`) are stat-checked directly after tilde expansion;
    ///   - bare command names (`claude`, `claude-beta`) are looked up in
    ///     the colon-separated `path`. `AgentRunner.runPrompt` invokes
    ///     via `/usr/bin/env` with the augmented PATH, so a bare command
    ///     name here is genuinely runnable as long as PATH resolves it.
    /// Returns the set of installed agent ids.
    static func scan(
        path: String,
        agents: [AgentDefinition]
    ) async -> Set<String> {
        let dirs = executableSearchDirectories(path: path)
        var found: Set<String> = []
        for agent in agents {
            let effective: String = {
                if let trimmed = agent.binaryOverride?.trimmingCharacters(in: .whitespaces),
                   !trimmed.isEmpty {
                    return trimmed
                }
                return agent.binary
            }()
            guard !effective.isEmpty else { continue }
            if looksLikePath(effective) {
                if isExecutable(atPath: expandTilde(effective)) {
                    found.insert(agent.id)
                }
            } else if isExecutable(named: effective, in: dirs) {
                found.insert(agent.id)
            }
        }
        return found
    }

    static func executableSearchDirectories(path: String) -> [String] {
        var seen: Set<String> = []
        var dirs: [String] = []
        for raw in path.split(separator: ":", omittingEmptySubsequences: true) {
            let dir = String(raw)
            guard dir.hasPrefix("/"), seen.insert(dir).inserted else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            dirs.append(dir)
        }
        return dirs
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
