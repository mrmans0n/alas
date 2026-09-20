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

    func pair(origins: [String], code: String, deviceName: String,
              advertisement: RemotePeerAdvertisement?) async -> Outcome {
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
