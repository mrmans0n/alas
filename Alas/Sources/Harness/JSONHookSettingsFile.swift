import Foundation

enum JSONHookSettingsFile {
    static func load(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSONHookSettingsFileError.invalidRoot
        }
        return json
    }

    static func write(_ json: [String: Any], to url: URL) throws {
        let dir = url.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func pruneManaged(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            // Strip managed entries from each group's inner `hooks` array
            // (drop the group only if it becomes empty). The previous
            // whole-group filter would also delete a user's third-party
            // command that happened to share a group with an Alas entry.
            var kept: [[String: Any]] = []
            for var group in groups {
                if let inner = group["hooks"] as? [[String: Any]] {
                    let keptInner = inner.filter { hook in
                        guard let cmd = hook["command"] as? String else { return true }
                        return !AlasHookCommand.isManagedCommand(cmd)
                    }
                    if keptInner.isEmpty { continue }
                    group["hooks"] = keptInner
                }
                kept.append(group)
            }
            if !kept.isEmpty {
                result[event] = kept
            }
        }
        return result
    }

    static func pruneManagedFlat(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let filtered = entries.filter { entry in
                guard let cmd = entry["command"] as? String else { return true }
                return !AlasHookCommand.isManagedCommand(cmd)
            }
            if !filtered.isEmpty {
                result[event] = filtered
            }
        }
        return result
    }

    /// Returns the set of Alas-managed commands present under each event key
    /// in a flat-format hooks tree (Codex / Cursor: `event → [{command,…}]`).
    /// Comparing per-event sets catches stale installs where a command lives
    /// under the wrong event key, which a flat-across-events set compare
    /// would mis-report as installed.
    static func managedCommandsByEventFlat(in hooks: [String: Any]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            var cmds = Set<String>()
            for entry in entries {
                if let cmd = entry["command"] as? String, AlasHookCommand.isManagedCommand(cmd) {
                    cmds.insert(cmd)
                }
            }
            if !cmds.isEmpty { result[event] = cmds }
        }
        return result
    }
}

enum JSONHookSettingsFileError: Error, LocalizedError {
    case invalidRoot

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "Settings file is not a JSON object."
        }
    }
}
