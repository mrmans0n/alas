import Foundation

public struct RemotePairingResult: Equatable, Sendable {
    public let origin: String
    public let token: String
    public let serverId: String?
    public let name: String?
    public let publicKey: String?

    public init(origin: String, token: String, serverId: String?, name: String?, publicKey: String?) {
        self.origin = origin
        self.token = token
        self.serverId = serverId
        self.name = name
        self.publicKey = publicKey
    }
}

public enum RemotePairingError: Error, Equatable {
    /// The host said 401: wrong or expired code.
    case codeRejected
    /// Every reachable origin said 403.
    case originNotAllowed
    case unreachable
}

/// Redeems a pairing code against a host's advertised origins.
public struct RemotePairingClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    public init(transport: @escaping Transport = RemotePairingClient.urlSession(timeout: 4)) {
        self.transport = transport
    }

    public static func urlSession(timeout: TimeInterval) -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

    private struct Reply: Decodable {
        let token: String
        let serverId: String?
        let name: String?
        let publicKey: String?
    }

    /// Stops at the first 401 to protect the host's redemption budget; a 403
    /// moves on to the next origin. Loopback origins are the phone itself.
    public func pair(origins: [String], code: String, deviceName: String) async throws(RemotePairingError) -> RemotePairingResult {
        let body = try? JSONEncoder().encode(["code": code, "deviceName": deviceName])
        var denied = false
        for origin in origins where !Self.isLoopback(origin) {
            guard let url = URL(string: origin + "/pair") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            guard let (data, response) = try? await transport(request) else { continue }
            switch response.statusCode {
            case 401: throw .codeRejected
            case 403: denied = true
            case 200..<300:
                if let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                    return RemotePairingResult(
                        origin: origin, token: reply.token, serverId: reply.serverId,
                        name: reply.name, publicKey: reply.publicKey)
                }
            default: continue
            }
        }
        throw denied ? .originNotAllowed : .unreachable
    }

    static func isLoopback(_ origin: String) -> Bool {
        guard let host = URLComponents(string: origin)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
