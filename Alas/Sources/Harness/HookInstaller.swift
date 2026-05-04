import Foundation

enum HookInstaller {
    /// Returns the on-disk install path for a wrapper script after copying.
    /// - Parameters:
    ///   - kind: The harness kind to install.
    ///   - bundle: The bundle to search for bundled scripts. Defaults to `Bundle.main`.
    ///             Pass a specific bundle in tests so the test bundle can locate resources.
    static func installWrapper(for kind: HarnessKind, bundle: Bundle = .main) throws -> URL {
        let destDir = (NSString("~/.alas/hooks") as NSString).expandingTildeInPath
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let scriptName: String
        switch kind {
        case .claudeCode: scriptName = "claude-code.sh"
        case .codex:      scriptName = "codex-cli.sh"
        case .aider:      scriptName = "aider.sh"
        }
        guard let bundled = bundle.url(forResource: scriptName.replacingOccurrences(of: ".sh", with: ""),
                                       withExtension: "sh") else {
            throw NSError(domain: "HookInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled hook script missing: \(scriptName)"])
        }
        let dest = URL(fileURLWithPath: destDir).appendingPathComponent(scriptName)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: bundled, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }

    /// Install the Claude Code Stop hook into ~/.claude/settings.json.
    /// Idempotent — does nothing if a hook with the same path already exists.
    static func installClaudeCodeStopHook(scriptPath: URL) throws -> Bool {
        let settingsPath = (NSString("~/.claude/settings.json") as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: settingsPath)
        try FileManager.default.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var json: [String: Any]
        // Distinguish "file doesn't exist yet" (start fresh) from "file
        // exists but couldn't be parsed" (refuse to overwrite — would
        // destroy unrelated user settings if the JSON was just transiently
        // truncated or manually edited into something invalid).
        if FileManager.default.fileExists(atPath: settingsPath) {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(
                    domain: "HookInstaller", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "~/.claude/settings.json exists but isn't a JSON object — refusing to overwrite. Fix or remove the file and try again."]
                )
            }
            json = obj
        } else {
            json = [:]
        }
        var hooks = (json["hooks"] as? [String: Any]) ?? [:]
        var stop = (hooks["Stop"] as? [[String: Any]]) ?? []
        let entry: [String: Any] = [
            "matcher": "*",
            "hooks": [["type": "command", "command": scriptPath.path]]
        ]
        let alreadyInstalled = stop.contains { dict in
            (dict["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == scriptPath.path } ?? false
        }
        if !alreadyInstalled {
            stop.append(entry)
            hooks["Stop"] = stop
            json["hooks"] = hooks
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return true
        }
        return false
    }

    /// For Codex / Aider, the install is "PATH the script and call it from the user's
    /// own integration"; we just expose the wrapper path via `installWrapper` and let
    /// the user wire it. Return the script path so settings UI can display it.
    static func wrapperPath(for kind: HarnessKind) -> URL {
        let destDir = (NSString("~/.alas/hooks") as NSString).expandingTildeInPath
        let name: String
        switch kind {
        case .claudeCode: name = "claude-code.sh"
        case .codex:      name = "codex-cli.sh"
        case .aider:      name = "aider.sh"
        }
        return URL(fileURLWithPath: destDir).appendingPathComponent(name)
    }
}
