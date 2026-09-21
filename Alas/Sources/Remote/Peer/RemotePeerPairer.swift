import Foundation

/// Redeems a pairing code on another Mac, trying each origin in order the way
/// `hub-links.js` does: a network failure moves on, and so does a 401 (code
/// unrecognized here) or 403 (peers refused here) — either can be answered by
/// a stale address that has been reassigned to an unrelated Alas instance, so
/// neither is trusted as a final answer until every origin has been tried.
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
        RemotePeerPairer(fetch: { try await boundedFetch($0, maxBytes: maxReplyBytes) })
    }

    /// Upper bound on a `/pair` reply's body. A legitimate one is a token
    /// plus a couple of short strings — well under 1 KB — so this is a
    /// generous but strict ceiling: the origins this dials are
    /// attacker-controlled (they travel with a peer's own advertisement,
    /// redialed automatically for a reciprocal pair-back), and
    /// `URLSession.data(for:)` would otherwise materialize an arbitrarily
    /// large or endlessly streaming response in full before any status or
    /// JSON validation ever runs. The per-request `timeout` alone does not
    /// catch this — it only bounds a stalled connection, not one that
    /// keeps a trickle of bytes coming.
    static let maxReplyBytes = 64 * 1024

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
        // A 401 or 403 only proves what THAT origin thinks: a stale advertised
        // address can have been reassigned to an unrelated Alas instance,
        // which correctly rejects a code it has never seen (401) or simply
        // has federation off (403), while the real target, reachable at a
        // later origin, may still redeem it. So neither is treated as an
        // immediate, global answer; both are remembered and only reported
        // once every origin has had a chance to answer. A 401 wins if both
        // occurred: a dead code is the more fundamental blocker to describe,
        // since fixing a setting on some other Mac would not help either way.
        var sawExpiredCode = false
        var sawOriginRejected = false
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
                sawExpiredCode = true
                continue
            case 403:
                sawOriginRejected = true
                continue
            default:
                continue
            }
        }
        if sawExpiredCode { return .expiredCode }
        if sawOriginRejected { return .originRejected }
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
