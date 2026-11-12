import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Asks the Codex CLI the adapter bundles whether managed requirements
/// disable an MCP server Alas attaches.
///
/// A managed `requirements.toml` can carry an MCP allowlist keyed by server
/// name plus URL or command. Codex drops every other server before it tries
/// to connect and reports nothing over ACP, so the built-in server would only
/// look like one that never said hello. `codex mcp list --json` applies the
/// same requirements and names their source.
public enum CodexMCPRequirementsProbe {
    /// Where the block comes from, e.g. `enterprise-managed requirements
    /// Baseline (…)`, or nil when Codex allows `server`, the agent is not a
    /// local Codex, or the CLI could not answer.
    public static func blockSource(launchSpec: ACPLaunchSpec, server: ACPMCPServer, cwd: String) async -> String? {
        guard launchSpec.agentID == ACPManagedAdapterDescriptor.codex.agentID,
              launchSpec.remoteNodeBinDirectory == nil,
              let cli = codexCLI(adapterCommand: launchSpec.command),
              let overrides = configOverrides(for: server),
              let result = try? await Process.run(
                  "/usr/bin/env",
                  args: ["node", cli.path, "mcp", "list", "--json"] + overrides,
                  cwd: URL(fileURLWithPath: cwd),
                  env: ACPProcessEnvironment.sanitizedForACP(extra: launchSpec.extraEnv),
                  timeout: 10
              ),
              result.exitCode == 0
        else { return nil }
        return blockSource(listJSON: Data(result.stdout.utf8), serverName: server.name)
    }

    /// The Codex CLI in the adapter package that owns `adapterCommand`, the
    /// one the adapter itself runs.
    public static func codexCLI(adapterCommand: String) -> URL? {
        guard adapterCommand.hasPrefix("/") else { return nil }
        var directory = URL(fileURLWithPath: adapterCommand).resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.path != "/" {
            let cli = directory.appendingPathComponent("node_modules/@openai/codex/bin/codex.js")
            if FileManager.default.fileExists(atPath: cli.path) { return cli }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// `-c` overrides that add `server` to the configuration `codex mcp list`
    /// reads, with the fields requirements match on: the URL, or the command
    /// and its arguments. Nil when the name or a value cannot be written as a
    /// TOML override.
    public static func configOverrides(for server: ACPMCPServer) -> [String]? {
        guard BuiltInAlasMCP.normalizedServerName(server.name) == server.name else { return nil }
        let key = "mcp_servers.\(server.name)"
        switch server {
        case let .http(_, url, _), let .sse(_, url, _):
            guard let url = tomlString(url) else { return nil }
            return ["-c", "\(key).url=\(url)"]
        case let .stdio(_, command, args, _):
            let quotedArgs = args.compactMap(tomlString)
            guard let command = tomlString(command), quotedArgs.count == args.count else { return nil }
            return ["-c", "\(key).command=\(command)", "-c", "\(key).args=[\(quotedArgs.joined(separator: ","))]"]
        }
    }

    /// A TOML basic string, or nil for text with control characters.
    private static func tomlString(_ value: String) -> String? {
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Reads `codex mcp list --json`: the source of the requirements that
    /// disable `serverName`, or nil when the server is enabled, missing, or
    /// disabled for another reason (the user turned it off).
    public static func blockSource(listJSON: Data, serverName: String) -> String? {
        guard let servers = try? JSONSerialization.jsonObject(with: listJSON) as? [[String: Any]],
              let entry = servers.first(where: { $0["name"] as? String == serverName }),
              entry["enabled"] as? Bool == false,
              let reason = entry["disabled_reason"] as? String,
              reason.hasPrefix("requirements")
        else { return nil }
        let source = reason.dropFirst("requirements".count).trimmingCharacters(in: .whitespaces)
        guard source.hasPrefix("("), source.hasSuffix(")") else { return reason }
        return String(source.dropFirst().dropLast())
    }
}
