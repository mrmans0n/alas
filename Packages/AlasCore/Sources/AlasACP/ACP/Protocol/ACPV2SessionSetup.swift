import Foundation
import AlasCode
import AlasModel

public enum ACPV2SessionSetupError: Error, Equatable, Sendable {
    case invalidInput, unsupportedCapability, invalidResult
}

public struct ACPV2SessionNewParams: Encodable, Sendable {
    public let cwd: String
    public let mcpServers: [ACPMCPServer]
    public init(cwd: String, mcpServers: [ACPMCPServer]) { self.cwd = cwd
    self.mcpServers = mcpServers }

    public func validate(capabilities: ACPV2InitializeResult) throws {
        guard Self.isAbsolutePath(cwd),
              Set(mcpServers.map { Data($0.name.utf8) }).count == mcpServers.count,
              mcpServers.allSatisfy({ !$0.name.isEmpty }) else { throw ACPV2SessionSetupError.invalidInput }
        guard capabilities.capability(at: ["session"]) != nil else { throw ACPV2SessionSetupError.unsupportedCapability }
        for server in mcpServers {
            let transport: String
            switch server {
            case .stdio(_, let command, _, _):
                guard Self.isAbsolutePath(command) else { throw ACPV2SessionSetupError.invalidInput }
                transport = "stdio"
            case .http: transport = "http"
            case .sse: throw ACPV2SessionSetupError.unsupportedCapability
            }
            guard capabilities.capability(at: ["session", "mcp", transport]) != nil else { throw ACPV2SessionSetupError.unsupportedCapability }
        }
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        let prefix = Array(path.utf8.prefix(3))
        let drivePath = prefix.count == 3 && ((65...90).contains(prefix[0]) || (97...122).contains(prefix[0]))
            && prefix[1] == 58 && (prefix[2] == 47 || prefix[2] == 92)
        return path.hasPrefix("/") || path.hasPrefix("\\\\") || drivePath
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: Keys.self)
        try fields.encode(cwd, forKey: .cwd)
        var servers = fields.nestedUnkeyedContainer(forKey: .mcpServers)
        for server in mcpServers {
            var item = servers.nestedContainer(keyedBy: ServerKeys.self)
            try item.encode(server.name, forKey: .name)
            switch server {
            case .stdio(_, let command, let args, let env):
                try item.encode("stdio", forKey: .type)
                try item.encode(command, forKey: .command)
                try item.encode(args, forKey: .args)
                try item.encode(env, forKey: .env)
            case .http(_, let url, let headers):
                try item.encode("http", forKey: .type)
                try item.encode(url, forKey: .url)
                try item.encode(headers, forKey: .headers)
            case .sse: throw ACPV2SessionSetupError.unsupportedCapability
            }
        }
    }
    private enum Keys: String, CodingKey { case cwd, mcpServers }
    private enum ServerKeys: String, CodingKey { case type, name, command, args, env, url, headers }
}

/// Setup metadata remains raw until an integration implements its semantics.
public struct ACPV2SessionNewResult: Equatable, Sendable {
    public let sessionId: String
    public let rawBytes: Data
    public let rawValue: LSPJSONValue
    public static func decode(_ bytes: Data) throws -> Self {
        let raw = try LSPJSONValue.decode(from: bytes)
        guard case .object(let fields) = raw, case .string(let id)? = fields["sessionId"], !id.isEmpty else {
            throw ACPV2SessionSetupError.invalidResult
        }
        return .init(sessionId: id, rawBytes: bytes, rawValue: raw)
    }
}
