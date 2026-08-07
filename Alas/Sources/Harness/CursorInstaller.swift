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
        let canonical = canonicalCommandsByEvent()
        guard !canonical.isEmpty else { return .notInstalled }
        do {
            let json = try JSONHookSettingsFile.load(at: settingsURL)
            let hooks = json["hooks"] as? [String: Any] ?? [:]
            var actual: [String: Set<String>] = Dictionary(
                uniqueKeysWithValues: canonical.keys.map { ($0, Set<String>()) }
            )
            for (event, cmds) in JSONHookSettingsFile.managedCommandsByEventFlat(in: hooks) {
                actual[event, default: []].formUnion(cmds)
            }
            if actual.values.allSatisfy(\.isEmpty) { return .notInstalled }
            // Per-event compare: a stale install with the right commands
            // under the wrong event keys would otherwise be reported as
            // installed.
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
    private static let attached = AlasHookCommand.compositeCommand(
        events: [.attached], agent: .cursor, forwardStdinAsBody: false)
    private static let detached = AlasHookCommand.compositeCommand(
        events: [.detached], agent: .cursor, forwardStdinAsBody: false)

    private func hooksByEvent() -> [String: [[String: Any]]] {
        [
            "sessionStart": [flatEntry(command: Self.attached)],
            "sessionEnd": [flatEntry(command: Self.detached)],
            "beforeSubmitPrompt": [flatEntry(command: Self.busy)],
            "afterAgentResponse": [flatEntry(command: Self.awaitingInputAndNotify)],
            "stop": [flatEntry(command: Self.idleAndNotify)],
        ]
    }

    private func flatEntry(command: String, timeout: Int = 10) -> [String: Any] {
        ["command": command, "timeout": timeout]
    }

    private func canonicalCommandsByEvent() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (event, entries) in hooksByEvent() {
            result[event] = Set(entries.compactMap { $0["command"] as? String })
        }
        return result
    }
}
