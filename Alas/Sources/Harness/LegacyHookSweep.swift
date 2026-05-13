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
            // Strip legacy entries from each group's inner `hooks` array
            // instead of dropping the whole group. Otherwise a user's own
            // command sharing a `hooks` array with the legacy wrapper would
            // be deleted on launch.
            var kept: [[String: Any]] = []
            for var group in groups {
                let isLegacyFlat = (group["command"] as? String)?.hasPrefix(alasHooksPrefix) == true
                if isLegacyFlat {
                    changed = true
                    continue
                }
                if let inner = group["hooks"] as? [[String: Any]] {
                    let keptInner = inner.filter { hook in
                        guard let cmd = hook["command"] as? String else { return true }
                        return !cmd.hasPrefix(alasHooksPrefix)
                    }
                    if keptInner.count != inner.count { changed = true }
                    if keptInner.isEmpty { continue }
                    group["hooks"] = keptInner
                }
                kept.append(group)
            }
            if !kept.isEmpty { pruned[event] = kept }
        }

        guard changed else { return }
        json["hooks"] = pruned
        guard let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? output.write(to: settingsURL, options: .atomic)
    }
}
