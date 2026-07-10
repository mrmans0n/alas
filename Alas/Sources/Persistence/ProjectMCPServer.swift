import Foundation

struct MCPKeyValue: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var value: String
}

enum ProjectMCPTransport: Codable, Equatable {
    case stdio(command: String, args: [String], environment: [MCPKeyValue])
    case http(url: String, headers: [MCPKeyValue])
    case sse(url: String, headers: [MCPKeyValue])

    private enum Kind: String, Codable {
        case stdio
        case http
        case sse
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case command
        case args
        case environment
        case url
        case headers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .stdio:
            self = .stdio(
                command: try container.decode(String.self, forKey: .command),
                args: try container.decode([String].self, forKey: .args),
                environment: try container.decode([MCPKeyValue].self, forKey: .environment)
            )
        case .http:
            self = .http(
                url: try container.decode(String.self, forKey: .url),
                headers: try container.decode([MCPKeyValue].self, forKey: .headers)
            )
        case .sse:
            self = .sse(
                url: try container.decode(String.self, forKey: .url),
                headers: try container.decode([MCPKeyValue].self, forKey: .headers)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stdio(command, args, environment):
            try container.encode(Kind.stdio, forKey: .kind)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encode(environment, forKey: .environment)
        case let .http(url, headers):
            try container.encode(Kind.http, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        case let .sse(url, headers):
            try container.encode(Kind.sse, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        }
    }
}

struct ProjectMCPServer: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var transport: ProjectMCPTransport

    static func stdio(name: String, command: String) -> ProjectMCPServer {
        ProjectMCPServer(
            id: UUID().uuidString,
            name: name,
            transport: .stdio(command: command, args: [], environment: [])
        )
    }

    func withFreshId() -> ProjectMCPServer {
        ProjectMCPServer(id: UUID().uuidString, name: name, transport: transport)
    }
}

enum ProjectMCPValidationIssue: Equatable {
    case emptyServerName(serverId: String)
    case duplicateServerName(String)
    case emptyCommand(serverName: String)
    case invalidURL(serverName: String)
    case invalidEnvironmentName(serverName: String, name: String)
    case duplicateEnvironmentName(serverName: String, name: String)
    case emptyHeaderName(serverName: String)
    case duplicateHeaderName(serverName: String, name: String)
}

enum ProjectMCPValidation {
    static func validate(_ servers: [ProjectMCPServer]) -> [ProjectMCPValidationIssue] {
        var issues: [ProjectMCPValidationIssue] = []
        var serverNames = Set<String>()

        for server in servers {
            let serverName = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if serverName.isEmpty {
                issues.append(.emptyServerName(serverId: server.id))
            } else if !serverNames.insert(serverName).inserted {
                issues.append(.duplicateServerName(serverName))
            }

            switch server.transport {
            case let .stdio(command, _, environment):
                if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.emptyCommand(serverName: serverName))
                }
                validateEnvironment(environment, serverName: serverName, issues: &issues)
            case let .http(url, headers), let .sse(url, headers):
                if !isValidHTTPURL(url) {
                    issues.append(.invalidURL(serverName: serverName))
                }
                validateHeaders(headers, serverName: serverName, issues: &issues)
            }
        }

        return issues
    }

    private static func validateEnvironment(
        _ environment: [MCPKeyValue],
        serverName: String,
        issues: inout [ProjectMCPValidationIssue]
    ) {
        var names = Set<String>()
        for entry in environment {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidEnvironmentName(name) else {
                issues.append(.invalidEnvironmentName(serverName: serverName, name: name))
                continue
            }
            if !names.insert(name).inserted {
                issues.append(.duplicateEnvironmentName(serverName: serverName, name: name))
            }
        }
    }

    private static func validateHeaders(
        _ headers: [MCPKeyValue],
        serverName: String,
        issues: inout [ProjectMCPValidationIssue]
    ) {
        var names = Set<String>()
        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                issues.append(.emptyHeaderName(serverName: serverName))
                continue
            }
            if !names.insert(name.lowercased()).inserted {
                issues.append(.duplicateHeaderName(serverName: serverName, name: name))
            }
        }
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        name.range(
            of: "^[A-Za-z_][A-Za-z0-9_]*$",
            options: .regularExpression
        ) != nil
    }

    private static func isValidHTTPURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return false
        }
        return url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
    }
}
