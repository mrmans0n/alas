import Foundation

/// Generates the pi-mcp-adapter project override (`.pi/mcp.json`) from the
/// project's configured MCP servers. Managed files carry a `"$alas"` marker;
/// unmanaged files are never touched. The built-in alas server is never
/// written here — its env is per-session, and the CLI covers it.
enum PiMCPConfigWriter {
    enum Outcome: Equatable { case wrote, unchanged, refusedUnmanaged, removedManaged, noServers, failed }

    static let markerKey = "$alas"

    /// `servers` must already be fully resolved (e.g. via
    /// `MCPAttachmentPlanner.plan(...).wireServers`) — `${WORKTREE_DIR}` /
    /// `${PROJECT_DIR}` templates are not interpolated here.
    static func sync(
        worktreeURL: URL,
        servers: [ACPMCPServer],
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
            switch server {
            case let .stdio(name, command, args, env):
                var entry: [String: Any] = ["command": command, "args": args]
                if !env.isEmpty {
                    entry["env"] = Dictionary(env.map { ($0.name, $0.value) }) { _, last in last }
                }
                mcpServers[name] = entry
            case let .http(name, url, headers), let .sse(name, url, headers):
                var entry: [String: Any] = ["url": url]
                if !headers.isEmpty {
                    entry["headers"] = Dictionary(headers.map { ($0.name, $0.value) }) { _, last in last }
                }
                mcpServers[name] = entry
            }
        }
        let payload: [String: Any] = [
            markerKey: ["managed": true, "fingerprint": fingerprint],
            "mcpServers": mcpServers,
        ]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        // Create the file with 0600 *before* any token-bearing content is
        // written, so there is never a window where a world/group-readable
        // file holds MCP server tokens. A non-atomic write into an
        // already-created file truncates in place and does not reset the
        // mode bits picked at creation; the trailing `setAttributes` call
        // re-asserts 0600 defensively in case that assumption ever changes.
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: fileURL)
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
