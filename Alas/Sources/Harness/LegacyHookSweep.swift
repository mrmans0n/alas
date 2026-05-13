import Foundation

enum LegacyHookSweep {
    static func sweepAll(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let prefix = homeDirectoryURL.appendingPathComponent(".alas/hooks/").path
        let targets = [
            homeDirectoryURL.appendingPathComponent(".claude/settings.json"),
            homeDirectoryURL.appendingPathComponent(".codex/hooks.json"),
            homeDirectoryURL.appendingPathComponent(".cursor/hooks.json"),
        ]
        for url in targets {
            sweep(settingsURL: url, alasHooksPrefix: prefix)
        }
    }

    static func sweep(settingsURL: URL, alasHooksPrefix: String) {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return }

        var changed = false
        var pruned: [String: Any] = [:]

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                pruned[event] = value
                continue
            }
            let filtered = groups.filter { group in
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    return !innerHooks.contains { ($0["command"] as? String)?.hasPrefix(alasHooksPrefix) == true }
                }
                if let cmd = group["command"] as? String {
                    return !cmd.hasPrefix(alasHooksPrefix)
                }
                return true
            }
            if filtered.count != groups.count { changed = true }
            if !filtered.isEmpty { pruned[event] = filtered }
        }

        guard changed else { return }
        json["hooks"] = pruned
        guard let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? output.write(to: settingsURL, options: .atomic)
    }
}
