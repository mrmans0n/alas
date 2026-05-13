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
        let canonical = canonicalPlacementsByEvent()
        guard !canonical.isEmpty else { return .notInstalled }
        do {
            let json = try JSONHookSettingsFile.load(at: settingsURL)
            let hooks = json["hooks"] as? [String: Any] ?? [:]
            let actual = managedPlacementsByEvent(in: hooks)
            if actual.values.allSatisfy(\.isEmpty) { return .notInstalled }
            // Per-event placement compare (matcher + command, not just
            // command). Claude reuses commands across events, AND a stale
            // install can have the right command on an outdated matcher
            // (e.g. an empty "" Notification matcher firing for every
            // notification type instead of just permission/idle/elicitation
            // prompts). Comparing matchers catches both.
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
            // Stop fires when Claude finishes responding — the moment we want
            // to surface the "Claude finished" notification. Intentionally
            // omit SessionEnd: it fires on /clear, /resume, logout, and
            // session close (per Claude's hook docs), so sending idle there
            // produces a false "finished" notification (and a duplicate
            // after the last real Stop) for events that aren't actually
            // response-completion. Process-exit teardown still happens
            // naturally via HarnessService's detector clear.
            "Stop": [hookGroup(command: Self.idleAndNotify)],
        ]
    }

    private func hookGroup(command: String, matcher: String? = nil, timeout: Int = 10) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [["type": "command", "command": command, "timeout": timeout]]
        ]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    private struct Placement: Hashable {
        let matcher: String?
        let command: String
    }

    private func canonicalPlacementsByEvent() -> [String: Set<Placement>] {
        var result: [String: Set<Placement>] = [:]
        for (event, groups) in hooksByEvent() {
            var placements = Set<Placement>()
            for group in groups {
                let matcher = group["matcher"] as? String
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                    if let cmd = hook["command"] as? String {
                        placements.insert(Placement(matcher: matcher, command: cmd))
                    }
                }
            }
            result[event] = placements
        }
        return result
    }

    private func managedPlacementsByEvent(in hooks: [String: Any]) -> [String: Set<Placement>] {
        var result: [String: Set<Placement>] = [:]
        // Seed every canonical event so a fully missing placement compares
        // as an empty set (not as a missing key), keeping the equality check
        // tight against `canonicalPlacementsByEvent`.
        for event in canonicalPlacementsByEvent().keys { result[event] = [] }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var placements = Set<Placement>()
            for group in groups {
                let matcher = group["matcher"] as? String
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] {
                    if let cmd = hook["command"] as? String,
                       AlasHookCommand.isManagedCommand(cmd)
                    {
                        placements.insert(Placement(matcher: matcher, command: cmd))
                    }
                }
            }
            if placements.isEmpty { continue }
            result[event, default: []].formUnion(placements)
        }
        return result
    }
}
