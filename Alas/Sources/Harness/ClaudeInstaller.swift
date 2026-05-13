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
        let canonical = canonicalCommandsByEvent()
        guard !canonical.isEmpty else { return .notInstalled }
        do {
            let json = try JSONHookSettingsFile.load(at: settingsURL)
            let hooks = json["hooks"] as? [String: Any] ?? [:]
            let actual = managedCommandsByEvent(in: hooks)
            if actual.values.allSatisfy(\.isEmpty) { return .notInstalled }
            // Per-event comparison: Claude reuses the same command across
            // multiple events (busy in UserPromptSubmit/PreToolUse/PostToolUse,
            // idleAndNotify in Stop/SessionEnd), so a flat Set<String> compare
            // can't detect a missing placement when the same command remains
            // elsewhere.
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
            // Scope to input/permission-prompt notification types; an empty
            // matcher would fire on every Claude Notification (status updates,
            // background messages, etc.) and produce false "needs input"
            // notifications. Mirrors the filter the old wrapper script applied.
            "Notification": [hookGroup(command: Self.awaitingInputAndNotify, matcher: "permission_prompt|idle_prompt|elicitation_dialog")],
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

    private func canonicalCommandsByEvent() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (event, groups) in hooksByEvent() {
            var cmds = Set<String>()
            for group in groups {
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                    if let cmd = hook["command"] as? String { cmds.insert(cmd) }
                }
            }
            result[event] = cmds
        }
        return result
    }

    private func managedCommandsByEvent(in hooks: [String: Any]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        // Seed every canonical event so a fully missing placement compares
        // as an empty set (not as a missing key), keeping the equality check
        // tight against `canonicalCommandsByEvent`.
        for event in canonicalCommandsByEvent().keys { result[event] = [] }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var cmds = Set<String>()
            for group in groups {
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                    if let cmd = hook["command"] as? String,
                       AlasHookCommand.isManagedCommand(cmd)
                    {
                        cmds.insert(cmd)
                    }
                }
            }
            if cmds.isEmpty { continue }
            result[event, default: []].formUnion(cmds)
        }
        return result
    }
}
