import Foundation

/// Pure presentation policy for editing a project's MCP server definitions.
/// It deliberately permits URL templates because their final values are only
/// available when an ACP session is created for a specific worktree.
enum ProjectMCPServerEditorPolicy {
    static func canSave(_ servers: [ProjectMCPServer]) -> Bool {
        ProjectMCPValidation.validate(servers).allSatisfy { issue in
            guard case let .invalidURL(serverName) = issue else { return false }
            return servers.contains { server in
                server.name.trimmingCharacters(in: .whitespacesAndNewlines) == serverName
                    && hasTemplateURL(server.transport)
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
        case let .stdio(command, args, _):
            return ([command] + args).joined(separator: " ")
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

    private static func hasTemplateURL(_ transport: ProjectMCPTransport) -> Bool {
        switch transport {
        case let .http(url, _), let .sse(url, _):
            return !templateVariables(in: url).isEmpty
        case .stdio:
            return false
        }
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
