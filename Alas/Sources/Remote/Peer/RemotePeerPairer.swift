import Foundation

/// Redeems a pairing code on another Mac, trying each origin in order the way
/// `hub-links.js` does: a network failure moves on, a 401 means the code is
/// dead everywhere, a 403 means that Mac refuses peers or this address.
struct RemotePeerPairer {
    enum Outcome: Equatable, Sendable {
        case paired(token: String, serverId: String?, name: String?, origin: String)
        case expiredCode
        case originRejected
        case unreachable
    }

    // Not `@Sendable`: tests inject closures that record into plain classes,
    // and every caller is on the main actor.
    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)

    let fetch: Fetch
    let timeout: TimeInterval

    init(fetch: @escaping Fetch, timeout: TimeInterval = 4) {
        self.fetch = fetch
        self.timeout = timeout
    }

    static var live: RemotePeerPairer {
        RemotePeerPairer(fetch: { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        })
    }

    /// Runs on the caller's executor: this type holds a non-Sendable `fetch`,
    /// so a main-actor owner calling a `@concurrent` `pair` would have to send
    /// itself across executors. Inheriting the caller's isolation keeps the
    /// value where it already lives; a nonisolated caller still gets `nil` and
    /// runs exactly as before.
    func pair(origins: [String], code: String, deviceName: String,
              advertisement: RemotePeerAdvertisement?,
              isolation: isolated (any Actor)? = #isolation) async -> Outcome {
        struct Body: Encodable {
            let code: String
            let deviceName: String
            let peer: RemotePeerAdvertisement?
        }
        struct Reply: Decodable {
            let token: String
            let serverId: String?
            let name: String?
        }
        let body = try? JSONEncoder().encode(Body(code: code, deviceName: deviceName, peer: advertisement))
        for origin in origins {
            // Origins reach this type from two directions: a link the user
            // pasted, and a peer's self-reported advertisement, which is
            // attacker-controlled. Normalizing here means neither path can
            // dial a non-http(s) scheme or smuggle a path, query or userinfo
            // into the request target.
            guard let normalized = RemotePairingLink.normalizeOrigin(origin),
                  let url = URL(string: normalized + "/pair") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.httpBody = body
            // No Content-Type on purpose: same "simple request" shape as the web client.
            guard let (data, http) = try? await fetch(request) else { continue }
            switch http.statusCode {
            case 200:
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { continue }
                return .paired(token: reply.token, serverId: reply.serverId, name: reply.name, origin: normalized)
            case 401:
                return .expiredCode
            case 403:
                return .originRejected
            default:
                continue
            }
        }
        return .unreachable
    }
}

extension RemotePeerPairer.Outcome: CustomStringConvertible {
    /// Swift's synthesized description of an enum prints its associated
    /// values, so interpolating a `.paired` outcome anywhere — a log line, an
    /// error message, a test failure — would put a live bearer token into the
    /// string. Redact it at the type, so no caller has to remember.
    var description: String {
        switch self {
        case .paired(_, let serverId, let name, let origin):
            return "paired(token: <redacted>, serverId: \(serverId ?? "nil"), name: \(name ?? "nil"), origin: \(origin))"
        case .expiredCode:
            return "expiredCode"
        case .originRejected:
            return "originRejected"
        case .unreachable:
            return "unreachable"
        }
    }
}
