import Foundation

/// Generates the pi-mcp-adapter project override (`.pi/mcp.json`) from the
/// project's configured MCP servers. Managed files carry a `"$alas"` marker;
/// unmanaged files are never touched. The built-in alas server is never
/// written here — its env is per-session, and the CLI covers it.
enum PiMCPConfigWriter {
    enum Outcome: Equatable { case wrote, unchanged, refusedUnmanaged, removedManaged, noServers }

    static let markerKey = "$alas"

    static func sync(
        worktreeURL: URL,
        servers: [ProjectMCPServer],
        fingerprint: String
    ) throws -> Outcome {
        let dir = worktreeURL.appendingPathComponent(".pi", isDirectory: true)
        let fileURL = dir.appendingPathComponent("mcp.json")
        let existing = readExisting(fileURL)

        switch existing {
        case .unmanaged:
            return .refusedUnmanaged
        case .managed(let existingFingerprint):
            if servers.isEmpty {
                try FileManager.default.removeItem(at: fileURL)
                return .removedManaged
            }
            if existingFingerprint == fingerprint { return .unchanged }
        case .absent:
            if servers.isEmpty { return .noServers }
        }

        var mcpServers: [String: Any] = [:]
        for server in servers {
            switch server.transport {
            case let .stdio(command, args, environment):
                var entry: [String: Any] = ["command": command, "args": args]
                if !environment.isEmpty {
                    entry["env"] = Dictionary(environment.map { ($0.name, $0.value) }) { _, last in last }
                }
                mcpServers[server.name] = entry
            case let .http(url, headers), let .sse(url, headers):
                var entry: [String: Any] = ["url": url]
                if !headers.isEmpty {
                    entry["headers"] = Dictionary(headers.map { ($0.name, $0.value) }) { _, last in last }
                }
                mcpServers[server.name] = entry
            }
        }
        let payload: [String: Any] = [
            markerKey: ["managed": true, "fingerprint": fingerprint],
            "mcpServers": mcpServers,
        ]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return .wrote
    }

    private enum Existing { case absent, unmanaged, managed(fingerprint: String?) }

    private static func readExisting(_ url: URL) -> Existing {
        guard let data = try? Data(contentsOf: url) else { return .absent }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let marker = json[markerKey] as? [String: Any],
              marker["managed"] as? Bool == true
        else { return .unmanaged }
        return .managed(fingerprint: marker["fingerprint"] as? String)
    }
}
