import CryptoKit
import Foundation
import AlasFoundation

extension ProjectMCPServer {
    /// A digest of the servers' definitions, which changes when a server is
    /// added, removed or edited, for trust and attachment decisions.
    public static func configurationFingerprint(for servers: [ProjectMCPServer]) -> String {
        let definitions = servers.map(FingerprintDefinition.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(definitions)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct FingerprintDefinition: Encodable {
    let name: String
    let transport: FingerprintTransport

    init(_ server: ProjectMCPServer) {
        name = server.name
        transport = .init(server.transport)
    }
}

private struct FingerprintKeyValue: Encodable {
    let name: String
    let value: String

    init(_ value: MCPKeyValue) {
        name = value.name
        self.value = value.value
    }
}

private enum FingerprintTransport: Encodable {
    case stdio(command: String, args: [String], environment: [FingerprintKeyValue])
    case http(url: String, headers: [FingerprintKeyValue])
    case sse(url: String, headers: [FingerprintKeyValue])

    private enum CodingKeys: String, CodingKey {
        case kind
        case command
        case args
        case environment
        case url
        case headers
    }

    init(_ transport: ProjectMCPTransport) {
        switch transport {
        case let .stdio(command, args, environment):
            self = .stdio(command: command, args: args, environment: environment.map(FingerprintKeyValue.init))
        case let .http(url, headers):
            self = .http(url: url, headers: headers.map(FingerprintKeyValue.init))
        case let .sse(url, headers):
            self = .sse(url: url, headers: headers.map(FingerprintKeyValue.init))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stdio(command, args, environment):
            try container.encode(MCPTransportKind.stdio, forKey: .kind)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encode(environment, forKey: .environment)
        case let .http(url, headers):
            try container.encode(MCPTransportKind.http, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        case let .sse(url, headers):
            try container.encode(MCPTransportKind.sse, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        }
    }
}
