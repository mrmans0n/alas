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
            let filtered = groups.filter { group in
                guard let innerHooks = group["hooks"] as? [[String: Any]] else { return true }
                return !innerHooks.contains { hook in
                    guard let cmd = hook["command"] as? String else { return false }
                    return AlasHookCommand.isManagedCommand(cmd)
                }
            }
            if !filtered.isEmpty {
                result[event] = filtered
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

    static func managedCommands(in hooks: [String: Any], flat: Bool) -> Set<String> {
        var commands = Set<String>()
        for (_, value) in hooks {
            if flat {
                guard let entries = value as? [[String: Any]] else { continue }
                for entry in entries {
                    if let cmd = entry["command"] as? String, AlasHookCommand.isManagedCommand(cmd) {
                        commands.insert(cmd)
                    }
                }
            } else {
                guard let groups = value as? [[String: Any]] else { continue }
                for group in groups {
                    guard let innerHooks = group["hooks"] as? [[String: Any]] else { continue }
                    for hook in innerHooks {
                        if let cmd = hook["command"] as? String, AlasHookCommand.isManagedCommand(cmd) {
                            commands.insert(cmd)
                        }
                    }
                }
            }
        }
        return commands
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
