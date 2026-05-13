import Foundation

struct ClaudeInstaller: AgentInstaller, Sendable {
    let agent = AgentKind.claude
    let settingsURL: URL

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        settingsURL: URL? = nil
    ) {
        self.settingsURL = settingsURL ?? homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    func installState() -> InstallState {
        let canonical = canonicalCommands()
        guard !canonical.isEmpty else { return .notInstalled }
        do {
            let json = try JSONHookSettingsFile.load(at: settingsURL)
            let hooks = json["hooks"] as? [String: Any] ?? [:]
            let actual = JSONHookSettingsFile.managedCommands(in: hooks, flat: false)
            if actual.isEmpty { return .notInstalled }
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

    // MARK: - Claude hook map

    private static let busy = AlasHookCommand.compositeCommand(
        events: [.busy], agent: .claude, forwardStdinAsBody: false)
    private static let awaitingInput = AlasHookCommand.compositeCommand(
        events: [.awaitingInput], agent: .claude, forwardStdinAsBody: false)
    private static let awaitingInputAndNotify = AlasHookCommand.compositeCommand(
        events: [.awaitingInput], agent: .claude, forwardStdinAsBody: true)
    private static let idleAndNotify = AlasHookCommand.compositeCommand(
        events: [.idle], agent: .claude, forwardStdinAsBody: true)

    private func hooksByEvent() -> [String: [[String: Any]]] {
        [
            "UserPromptSubmit": [hookGroup(command: Self.busy)],
            "PreToolUse": [
                hookGroup(command: Self.busy, matcher: ""),
                hookGroup(command: Self.awaitingInput, matcher: "AskUserQuestion|ExitPlanMode"),
            ],
            "PostToolUse": [hookGroup(command: Self.busy, matcher: "")],
            "Notification": [hookGroup(command: Self.awaitingInputAndNotify, matcher: "")],
            "Stop": [hookGroup(command: Self.idleAndNotify)],
            "SessionEnd": [hookGroup(command: Self.idleAndNotify, matcher: "")],
        ]
    }

    private func hookGroup(command: String, matcher: String? = nil, timeout: Int = 10) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [["type": "command", "command": command, "timeout": timeout]]
        ]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    private func canonicalCommands() -> Set<String> {
        var cmds = Set<String>()
        for (_, groups) in hooksByEvent() {
            for group in groups {
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                    if let cmd = hook["command"] as? String { cmds.insert(cmd) }
                }
            }
        }
        return cmds
    }
}
