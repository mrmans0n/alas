import Foundation

/// Detects whether pi has the `pi-mcp-adapter` extension installed.
/// `pi install npm:<pkg>` records packages as dependencies in
/// `<agent dir>/npm/package.json` (verified against a live install). Project
/// local installs live under the worktree's `.pi/npm/package.json`.
enum PiMCPAdapterInspector {
    enum State: Equatable { case installed, missing, unknown }

    static let packageName = "pi-mcp-adapter"

    static func state(
        agentDir: URL? = nil,
        worktreeURL: URL? = nil
    ) -> State {
        let agentDir = agentDir ?? defaultAgentDir()
        var states: [State] = []
        if let worktreeURL {
            states.append(manifestState(worktreeURL.appendingPathComponent(".pi/npm/package.json")))
        }
        states.append(manifestState(agentDir.appendingPathComponent("npm/package.json")))
        if states.contains(.installed) { return .installed }
        if states.contains(.missing) { return .missing }
        return .unknown
    }

    static func defaultAgentDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["PI_CODING_AGENT_DIR"],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true)
    }

    private static func manifestState(_ manifest: URL) -> State {
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }
        let dependencies = json["dependencies"] as? [String: Any] ?? [:]
        return dependencies[packageName] != nil ? .installed : .missing
    }
}
