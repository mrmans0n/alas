import Foundation

struct CursorInstaller: AgentInstaller, Sendable {
    let agent = AgentKind.cursor
    let settingsURL: URL

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        settingsURL: URL? = nil
    ) {
        self.settingsURL = settingsURL ?? homeDirectoryURL
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
    }

    func installState() -> InstallState {
        let canonical = canonicalCommands()
        guard !canonical.isEmpty else { return .notInstalled }
        do {
            let json = try JSONHookSettingsFile.load(at: settingsURL)
            let hooks = json["hooks"] as? [String: Any] ?? [:]
            let actual = JSONHookSettingsFile.managedCommands(in: hooks, flat: true)
            if actual.isEmpty { return .notInstalled }
            return actual == canonical ? .installed : .outdated
        } catch {
            return .notInstalled
        }
    }

    func install() async throws {
        var json = try JSONHookSettingsFile.load(at: settingsURL)
        if json["version"] == nil { json["version"] = 1 }
        let existing = json["hooks"] as? [String: Any] ?? [:]
        var hooks = JSONHookSettingsFile.pruneManagedFlat(from: existing)
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
        json["hooks"] = JSONHookSettingsFile.pruneManagedFlat(from: existing)
        try JSONHookSettingsFile.write(json, to: settingsURL)
    }

    // MARK: - Cursor hook map (flat format, camelCase events)

    private static let busy = AlasHookCommand.compositeCommand(
        events: [.busy], agent: .cursor, forwardStdinAsBody: false)
    private static let awaitingInputAndNotify = AlasHookCommand.compositeCommand(
        events: [.awaitingInput], agent: .cursor, forwardStdinAsBody: true)
    private static let idleAndNotify = AlasHookCommand.compositeCommand(
        events: [.idle], agent: .cursor, forwardStdinAsBody: true)

    private func hooksByEvent() -> [String: [[String: Any]]] {
        [
            "beforeSubmitPrompt": [flatEntry(command: Self.busy)],
            "afterAgentResponse": [flatEntry(command: Self.awaitingInputAndNotify)],
            "stop": [flatEntry(command: Self.idleAndNotify)],
        ]
    }

    private func flatEntry(command: String, timeout: Int = 10) -> [String: Any] {
        ["command": command, "timeout": timeout]
    }

    private func canonicalCommands() -> Set<String> {
        Set(hooksByEvent().values.flatMap { $0.compactMap { $0["command"] as? String } })
    }
}
