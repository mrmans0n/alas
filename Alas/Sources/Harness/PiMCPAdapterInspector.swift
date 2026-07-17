import Foundation

/// Detects whether pi has the `pi-mcp-adapter` extension installed.
/// `pi install npm:<pkg>` records packages as dependencies in
/// `<agent dir>/npm/package.json` (verified against a live install). Project
/// local installs live under the worktree's `.pi/npm/package.json`.
enum PiMCPAdapterInspector {
    enum State: Equatable { case installed, missing, unknown }

    static let packageName = "pi-mcp-adapter"

    static func state(
        agentDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true),
        worktreeURL: URL? = nil
    ) -> State {
        var states: [State] = []
        if let worktreeURL {
            states.append(manifestState(worktreeURL.appendingPathComponent(".pi/npm/package.json")))
        }
        states.append(manifestState(agentDir.appendingPathComponent("npm/package.json")))
        if states.contains(.installed) { return .installed }
        if states.contains(.missing) { return .missing }
        return .unknown
    }

    private static func manifestState(_ manifest: URL) -> State {
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }
        let dependencies = json["dependencies"] as? [String: Any] ?? [:]
        return dependencies[packageName] != nil ? .installed : .missing
    }
}
