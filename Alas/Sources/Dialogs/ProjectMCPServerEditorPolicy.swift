import Foundation

/// Pure presentation policy for editing a project's MCP server definitions.
/// It deliberately permits URL templates because their final values are only
/// available when an ACP session is created for a specific worktree.
enum ProjectMCPServerEditorPolicy {
    static func canSave(_ servers: [ProjectMCPServer]) -> Bool {
        let validationAllowsTemplates = ProjectMCPValidation.validate(servers).allSatisfy { issue in
            guard case let .invalidURL(serverName) = issue else { return false }
            return servers.contains { server in
                server.name.trimmingCharacters(in: .whitespacesAndNewlines) == serverName
                    && hasStructurallyValidTemplateURL(server.transport)
            }
        }
        guard validationAllowsTemplates else { return false }

        return servers.allSatisfy { server in
            switch server.transport {
            case let .http(url, _), let .sse(url, _):
                guard !isStandaloneTemplate(url) else { return true }
                let validationURL = templateVariables(in: url).isEmpty
                    ? url
                    : replacingTemplateVariables(in: url)
                return isValidHTTPURL(validationURL)
            case .stdio:
                return true
            }
        }
    }

    static func templateVariables(in value: String) -> [String] {
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(value.startIndex..., in: value)
        var variables: [String] = []
        var seen = Set<String>()
        for match in expression.matches(in: value, range: range) {
            guard let variableRange = Range(match.range(at: 1), in: value) else { continue }
            let variable = String(value[variableRange])
            if seen.insert(variable).inserted {
                variables.append(variable)
            }
        }
        return variables
    }

    static func templateVariables(in server: ProjectMCPServer) -> [String] {
        let values: [String]
        switch server.transport {
        case let .stdio(command, args, environment):
            values = [command] + args + environment.map(\.value)
        case let .http(url, headers), let .sse(url, headers):
            values = [url] + headers.map(\.value)
        }
        return templateVariables(in: values)
    }

    static func templateVariables(in values: [String]) -> [String] {
        var variables: [String] = []
        var seen = Set<String>()
        for value in values {
            for variable in templateVariables(in: value) where seen.insert(variable).inserted {
                variables.append(variable)
            }
        }
        return variables
    }

    static func transportLabel(for transport: ProjectMCPTransport) -> String {
        switch transport {
        case .stdio: "Stdio"
        case .http: "HTTP"
        case .sse: "Legacy SSE"
        }
    }

    static func summary(for server: ProjectMCPServer) -> String {
        switch server.transport {
        case let .stdio(command, _, _):
            return command
        case let .http(url, _), let .sse(url, _):
            return safeRemoteSummary(url)
        }
    }

    static func safeRemoteSummary(_ value: String) -> String {
        let withoutUserInfo = strippingUserInfo(from: value)
        let withoutFragment = withoutUserInfo.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""

        guard var components = URLComponents(string: withoutQuery) else {
            return withoutQuery
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? withoutQuery
    }

    private static func hasStructurallyValidTemplateURL(_ transport: ProjectMCPTransport) -> Bool {
        switch transport {
        case let .http(url, _), let .sse(url, _):
            guard !templateVariables(in: url).isEmpty else { return false }
            guard !isStandaloneTemplate(url) else { return true }
            return isValidHTTPURL(replacingTemplateVariables(in: url))
        case .stdio:
            return false
        }
    }

    private static func isStandaloneTemplate(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let pattern = #"^\$\{[A-Za-z_][A-Za-z0-9_]*\}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacingTemplateVariables(in value: String) -> String {
        let pattern = #"\$\{[A-Za-z_][A-Za-z0-9_]*\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "mcp"
        )
    }

    private static func isValidHTTPURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed,
              !value.contains(where: \.isWhitespace),
              let url = URL(string: value),
              let host = url.host,
              !host.isEmpty else { return false }
        return url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
    }

    private static func strippingUserInfo(from value: String) -> String {
        guard let schemeRange = value.range(of: "://") else { return value }
        let authorityStart = schemeRange.upperBound
        let authorityEnd = value[authorityStart...].firstIndex(of: "/") ?? value.endIndex
        let authority = value[authorityStart..<authorityEnd]
        guard let userInfoEnd = authority.lastIndex(of: "@") else { return value }

        return String(value[..<authorityStart])
            + String(authority[authority.index(after: userInfoEnd)...])
            + String(value[authorityEnd...])
    }
}

enum ProjectMCPConfigImporter {
    static func servers(
        from text: String,
        excluding existing: [ProjectMCPServer] = []
    ) -> [ProjectMCPServer] {
        guard let rawServers = rawServers(from: text) else { return [] }
        var names = Set(existing.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })

        return rawServers.compactMap { rawName, value in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !names.contains(name),
                  let config = value as? [String: Any],
                  config["disabled"] as? Bool != true,
                  let transport = transport(from: config) else { return nil }

            let server = ProjectMCPServer(id: UUID().uuidString, name: name, transport: transport)
            guard ProjectMCPServerEditorPolicy.canSave([server]) else { return nil }
            names.insert(name)
            return server
        }
    }

    private static func rawServers(from text: String) -> [String: Any]? {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = original
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")

        for candidate in [original, "{\(original)}", normalized, "{\(normalized)}"] {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = object["mcpServers"] as? [String: Any] else { continue }
            return servers
        }
        return nil
    }

    private static func transport(from config: [String: Any]) -> ProjectMCPTransport? {
        let kind = (config["type"] as? String)?.lowercased()
            ?? (config["command"] != nil ? "stdio" : config["url"] != nil ? "http" : nil)

        switch kind {
        case "stdio":
            guard let command = config["command"] as? String,
                  let args = stringArray(config["args"]),
                  let environment = keyValues(config["env"]) else { return nil }
            return .stdio(command: command, args: args, environment: environment)
        case "http", "sse":
            guard let url = config["url"] as? String,
                  let headers = keyValues(config["headers"]) else { return nil }
            return kind == "http" ? .http(url: url, headers: headers) : .sse(url: url, headers: headers)
        default:
            return nil
        }
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        value == nil ? [] : value as? [String]
    }

    private static func keyValues(_ value: Any?) -> [MCPKeyValue]? {
        guard let value else { return [] }
        guard let dictionary = value as? [String: Any],
              dictionary.values.allSatisfy({ $0 is String }) else { return nil }
        return dictionary.keys.sorted().compactMap { key in
            guard let value = dictionary[key] as? String else { return nil }
            return MCPKeyValue(id: UUID().uuidString, name: key, value: value)
        }
    }
}
