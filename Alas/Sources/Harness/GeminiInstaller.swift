import Foundation

struct GeminiInstaller: AgentInstaller, Sendable {
    let agent = AgentKind.gemini
    let settingsURL: URL

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        settingsURL: URL? = nil
    ) {
        self.settingsURL = settingsURL ?? homeDirectoryURL
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    func installState() -> InstallState {
        let canonical = canonicalPlacementsByEvent()
        guard !canonical.isEmpty else { return .notInstalled }
        do {
            let json = try JSONHookSettingsFile.load(at: settingsURL)
            let hooks = json["hooks"] as? [String: Any] ?? [:]
            let actual = managedPlacementsByEvent(in: hooks)
            if actual.values.allSatisfy(\.isEmpty) { return .notInstalled }
            return actual == canonical ? .installed : .outdated
        } catch {
            return .notInstalled
        }
    }

    func install() async throws {
        var json = try JSONHookSettingsFile.load(at: settingsURL)
        let existing = json["hooks"] as? [String: Any] ?? [:]
        var hooks = JSONHookSettingsFile.pruneManaged(from: existing)
        for (event, entries) in hooksByEvent() {
            var current = hooks[event] as? [[String: Any]] ?? []
            current.append(contentsOf: entries)
            hooks[event] = current
        }
        json["hooks"] = hooks
        try JSONHookSettingsFile.write(json, to: settingsURL)
    }

    func uninstall() throws {
        var json = try JSONHookSettingsFile.load(at: settingsURL)
        let existing = json["hooks"] as? [String: Any] ?? [:]
        json["hooks"] = JSONHookSettingsFile.pruneManaged(from: existing)
        try JSONHookSettingsFile.write(json, to: settingsURL)
    }

    private static let attached = AlasHookCommand.compositeCommand(
        events: [.attached], agent: .gemini, forwardStdinAsBody: false, stdoutResponse: "{}")
    private static let detached = AlasHookCommand.compositeCommand(
        events: [.detached], agent: .gemini, forwardStdinAsBody: false, stdoutResponse: "{}")
    private static let busy = AlasHookCommand.compositeCommand(
        events: [.busy], agent: .gemini, forwardStdinAsBody: false, stdoutResponse: "{}")
    private static let idleAndNotify = AlasHookCommand.compositeCommand(
        events: [.idle], agent: .gemini, forwardStdinAsBody: true, stdoutResponse: "{}")

    private func hooksByEvent() -> [String: [[String: Any]]] {
        [
            "SessionStart": [hookGroup(command: Self.attached)],
            "SessionEnd": [hookGroup(command: Self.detached)],
            "BeforeAgent": [hookGroup(command: Self.busy)],
            "AfterTool": [hookGroup(command: Self.busy)],
            "AfterAgent": [hookGroup(command: Self.idleAndNotify)],
        ]
    }

    private func hookGroup(command: String, timeout: Int = 10) -> [String: Any] {
        [
            "hooks": [["type": "command", "command": command, "timeout": timeout]]
        ]
    }

    private struct Placement: Hashable {
        let command: String
    }

    private func canonicalPlacementsByEvent() -> [String: Set<Placement>] {
        var result: [String: Set<Placement>] = [:]
        for (event, groups) in hooksByEvent() {
            var placements = Set<Placement>()
            for group in groups {
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                    if let cmd = hook["command"] as? String {
                        placements.insert(Placement(command: cmd))
                    }
                }
            }
            result[event] = placements
        }
        return result
    }

    private func managedPlacementsByEvent(in hooks: [String: Any]) -> [String: Set<Placement>] {
        var result: [String: Set<Placement>] = [:]
        for event in canonicalPlacementsByEvent().keys { result[event] = [] }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var placements = Set<Placement>()
            for group in groups {
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                    if let cmd = hook["command"] as? String,
                       AlasHookCommand.isManagedCommand(cmd)
                    {
                        placements.insert(Placement(command: cmd))
                    }
                }
            }
            if placements.isEmpty { continue }
            result[event, default: []].formUnion(placements)
        }
        return result
    }
}
