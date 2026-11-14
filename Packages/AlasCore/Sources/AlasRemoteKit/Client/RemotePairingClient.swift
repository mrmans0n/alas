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
        configuration.timeoutIntervalForResource = timeout * 2
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
        let signature: String?
    }

    /// Stops at the first 401 to protect the host's redemption budget; a 403
    /// moves on to the next origin. Loopback origins are the phone itself.
    ///
    /// `publicKey` is set only when the host signed this attempt's challenge
    /// with it, so the phone never pins a key nobody proved. A reply without
    /// a key pairs unpinned, as on the Mac. A reply claiming a key it cannot
    /// back disqualifies its origin and the next one is tried, as on the Mac;
    /// but its code is spent, so when no later origin proves a key the phone
    /// keeps that token unpinned rather than failing: that is the trust a
    /// keyless reply already gets, and an existing pin is never dropped.
    public func pair(origins: [String], code: String, deviceName: String) async throws(RemotePairingError) -> RemotePairingResult {
        let challenge = RemoteIdentityCrypto.randomChallenge()
        let body = try? JSONEncoder().encode(["code": code, "deviceName": deviceName, "challenge": challenge])
        var denied = false
        var unproven: RemotePairingResult?
        for origin in origins where !Self.isLoopback(origin) {
            if Task.isCancelled { throw .unreachable }
            guard let url = URL(string: origin + "/pair") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            guard let (data, response) = try? await transport(request) else {
                if Task.isCancelled { throw .unreachable }
                continue
            }
            switch response.statusCode {
            case 401:
                // An unproven origin already spent the code, so this 401 is expected.
                if let unproven { return unproven }
                throw .codeRejected
            case 403: denied = true
            case 200..<300:
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.token.isEmpty else { continue }
                let proven = Self.provenKey(reply, challenge: challenge)
                let result = RemotePairingResult(
                    origin: origin, token: reply.token, serverId: reply.serverId,
                    name: reply.name, publicKey: proven)
                if reply.publicKey == nil || proven != nil { return result }
                if unproven == nil { unproven = result }
            default: continue
            }
        }
        if let unproven { return unproven }
        throw denied ? .originNotAllowed : .unreachable
    }

    private static func provenKey(_ reply: Reply, challenge: String) -> String? {
        guard let key = reply.publicKey, let serverId = reply.serverId, !serverId.isEmpty,
              let signature = reply.signature,
              RemoteIdentityCrypto.verify(
                  RemoteIdentityProof(challenge: challenge, publicKey: key, signature: signature),
                  serverId: serverId, expectedPublicKey: key, challenge: challenge)
        else { return nil }
        return key
    }

    static func isLoopback(_ origin: String) -> Bool {
        guard let host = URLComponents(string: origin)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
