import Foundation

/// Detects whether pi has the `pi-mcp-adapter` extension installed.
/// `pi install npm:<pkg>` records packages as dependencies in
/// `<agent dir>/npm/package.json` (verified against a live install).
enum PiMCPAdapterInspector {
    enum State: Equatable { case installed, missing, unknown }

    static let packageName = "pi-mcp-adapter"

    static func state(
        agentDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true)
    ) -> State {
        let manifest = agentDir.appendingPathComponent("npm/package.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }
        let dependencies = json["dependencies"] as? [String: Any] ?? [:]
        return dependencies[packageName] != nil ? .installed : .missing
    }
}
