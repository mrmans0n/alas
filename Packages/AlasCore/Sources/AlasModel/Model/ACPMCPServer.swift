import Foundation
import AlasFoundation

public struct ACPMCPKeyValue: Codable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum ACPMCPServer: Codable, Equatable, Sendable {
    case stdio(name: String, command: String, args: [String], env: [ACPMCPKeyValue])
    case http(name: String, url: String, headers: [ACPMCPKeyValue])
    case sse(name: String, url: String, headers: [ACPMCPKeyValue])
    /// A server the client answers itself over the ACP connection
    /// (MCP-over-ACP): the agent sends each MCP message as `mcp/message`
    /// naming `serverId`, an opaque id for this registration.
    case acp(name: String, serverId: String)

    public var name: String {
        switch self {
        case let .stdio(name, _, _, _), let .http(name, _, _), let .sse(name, _, _), let .acp(name, _):
            return name
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case command
        case args
        case env
        case url
        case headers
        case serverId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        let name = try container.decode(String.self, forKey: .name)

        switch type {
        case nil:
            self = .stdio(
                name: name,
                command: try container.decode(String.self, forKey: .command),
                args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
                env: try container.decodeIfPresent([ACPMCPKeyValue].self, forKey: .env) ?? []
            )
        case "http":
            self = .http(
                name: name,
                url: try container.decode(String.self, forKey: .url),
                headers: try container.decodeIfPresent([ACPMCPKeyValue].self, forKey: .headers) ?? []
            )
        case "sse":
            self = .sse(
                name: name,
                url: try container.decode(String.self, forKey: .url),
                headers: try container.decodeIfPresent([ACPMCPKeyValue].self, forKey: .headers) ?? []
            )
        case "acp":
            self = .acp(name: name, serverId: try container.decode(String.self, forKey: .serverId))
        case let .some(type):
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported MCP server type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .stdio(name, command, args, env):
            try container.encode(name, forKey: .name)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encode(env, forKey: .env)
        case let .http(name, url, headers):
            try container.encode("http", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        case let .sse(name, url, headers):
            try container.encode("sse", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        case let .acp(name, serverId):
            try container.encode("acp", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(serverId, forKey: .serverId)
        }
    }
}

public struct ACPMCPServerCapabilities: Codable, Equatable, Sendable {
    public let http: Bool
    public let sse: Bool
    /// The agent takes `type: "acp"` servers (MCP-over-ACP, ACP v1).
    public let acp: Bool

    public init(http: Bool = false, sse: Bool = false, acp: Bool = false) {
        self.http = http
        self.sse = sse
        self.acp = acp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        http = try container.decodeIfPresent(Bool.self, forKey: .http) ?? false
        sse = try container.decodeIfPresent(Bool.self, forKey: .sse) ?? false
        acp = try container.decodeIfPresent(Bool.self, forKey: .acp) ?? false
    }
}
