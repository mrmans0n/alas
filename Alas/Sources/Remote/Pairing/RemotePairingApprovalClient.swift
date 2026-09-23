import CryptoKit
import Foundation

struct ApprovalSession: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let payload: ApprovalPayload
    let receiverKey: String
    let origin: String
    var description: String { "ApprovalSession(phase: \(payload.phase.rawValue))" }
    var debugDescription: String { description }
}

enum ApprovalClientResult: Equatable {
    case approved(ApprovalSession), declined, cancelled, expired, failed(ApprovalFailure)
}

/// One instance owns one attempt, including the exact in-flight request needed
/// to recover a lost reply before cancellation can use its rotated challenge.
@MainActor
final class RemotePairingApprovalClient {
    static let maxReplyBytes = 16 * 1024
    private let fetch: RemotePeerPairer.Fetch
    private let signer: any ApprovalSigning
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private(set) var session: ApprovalSession?
    var onSessionChange: ((ApprovalSession) -> Void)?
    private struct Exchange {
        let request: URLRequest
        let envelope: ApprovalEnvelope
    }
    private var pending: Exchange?

    init(fetch: @escaping RemotePeerPairer.Fetch, signer: any ApprovalSigning,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.fetch = fetch
        self.signer = signer
        self.now = now
        self.sleep = sleep
    }

    static func live(signer: any ApprovalSigning) -> RemotePairingApprovalClient {
        .init(fetch: { try await boundedFetch($0, maxBytes: maxReplyBytes) }, signer: signer)
    }

    func request(localPeer: ApprovalPeer, target: RemoteDiscoveredInstanceResolver.ResolvedPeer,
                 expectedServerID: String) async -> ApprovalClientResult {
        guard session == nil else { return .failed(.conflict) }
        guard target.serverID == expectedServerID, expectedServerID != localPeer.serverID,
              localPeer.publicKey == signer.publicKey else { return .failed(.unauthorized) }
        guard target.pairingApprovalVersion == 1 else { return .failed(.disabled) }
        do {
            try Task.checkCancellation()
            try await establish(localPeer: localPeer, target: target, expectedServerID: expectedServerID)
            _ = try await perform(.submit)
            while let session {
                try Task.checkCancellation()
                guard milliseconds < session.payload.expiresAtMilliseconds else { return .expired }
                switch session.payload.phase {
                case .approved: return .approved(session)
                case .declined: return .declined
                case .cancelled: return .cancelled
                case .expired: return .expired
                case .pending:
                    try await sleep(.seconds(2))
                    try Task.checkCancellation()
                    guard milliseconds < session.payload.expiresAtMilliseconds else { return .expired }
                    _ = try await pollAuthenticatedSession()
                default: throw ApprovalFailure.conflict
                }
            }
            return .failed(.invalid)
        } catch {
            // An unstructured task does not inherit the caller's cancelled
            // status, so the bounded cleanup requests can still reach the peer.
            if let session { await cancel(session: session) }
            if error is CancellationError || Task.isCancelled { return .cancelled }
            return .failed(error as? ApprovalFailure ?? .invalid)
        }
    }

    func redeem(session: ApprovalSession, advertisement: RemotePeerAdvertisement) async -> RemotePeerPairer.Outcome {
        guard let current = self.session, current == session, current.payload.phase == .approved,
              milliseconds < current.payload.expiresAtMilliseconds,
              advertisement.serverId == current.payload.requester.serverID,
              advertisement.publicKey == current.payload.requester.publicKey,
              advertisement.name == current.payload.requester.name,
              advertisement.origins == current.payload.requester.origins,
              advertisement.counterCode?.isEmpty == false else { return .identityUnproven }
        do {
            try Task.checkCancellation()
            let envelope = try signed(.redeem, counterCode: advertisement.counterCode)
            struct Body: Encodable {
                let approval: ApprovalEnvelope
                let deviceName: String
                let peer: RemotePeerAdvertisement
            }
            let body = try JSONEncoder().encode(Body(approval: envelope, deviceName: advertisement.name, peer: advertisement))
            let exchange = Exchange(request: try makeRequest(origin: current.origin, path: "/pair", body: body), envelope: envelope)
            pending = exchange
            let data = try await exchangeReply(exchange)
            let pair = try verifiedPair(data, exchange: exchange)
            try Task.checkCancellation()
            return .paired(token: pair.token, serverId: pair.serverId, name: pair.name,
                           publicKey: current.receiverKey, origin: current.origin)
        } catch {
            await cancel(session: session)
            return error is ApprovalFailure ? .identityUnproven : .unreachable
        }
    }

    func cancel(session: ApprovalSession) async {
        await Task { @MainActor in
            guard self.session?.payload.requestID == session.payload.requestID else { return }
            // The receiver may have processed an operation whose reply never
            // arrived. Repeating that exact signed operation recovers authority.
            if let pending = self.pending {
                guard (try? await self.exchangeReply(pending)) != nil else { return }
            }
            _ = try? await self.perform(.cancel)
        }.value
    }

    private func establish(localPeer: ApprovalPeer, target: RemoteDiscoveredInstanceResolver.ResolvedPeer,
                           expectedServerID: String) async throws {
        let attemptNonce = RemoteIdentityCrypto.randomChallenge()
        let body = try JSONEncoder().encode(RemotePairingApprovalHTTP.ChallengeRequest(requester: localPeer, attemptNonce: attemptNonce))
        var failure = ApprovalFailure.invalid
        for origin in target.origins.prefix(RemotePairingLink.maxOrigins) {
            try Task.checkCancellation()
            guard RemotePairingLink.normalizeOrigin(origin) == origin else { continue }
            do {
                let request = try makeRequest(origin: origin, path: "/peer-approval/v1/challenge", body: body)
                let data = try await fetchReply(request)
                guard let envelope = try? JSONDecoder().decode(ApprovalEnvelope.self, from: data) else {
                    throw ApprovalFailure.unauthorized
                }
                let p = envelope.payload
                guard p.operation == .challenge, p.phase == .challenged,
                      p.requester == localPeer, p.receiver.serverID == expectedServerID,
                      p.attemptNonce == attemptNonce, p.counterCode == nil, p.responseDigest == nil,
                      p.expiresAtMilliseconds > milliseconds,
                      p.expiresAtMilliseconds <= milliseconds + 30_000,
                      ApprovalWire.verify(envelope, expectedKey: p.receiver.publicKey, reply: true)
                else { throw ApprovalFailure.unauthorized }
                update(envelope.payload, origin: origin, receiverKey: p.receiver.publicKey)
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let error = error as? ApprovalFailure { failure = error }
            }
        }
        throw failure
    }

    private func pollAuthenticatedSession() async throws -> ApprovalEnvelope {
        try await perform(.status)
    }

    private func perform(_ operation: ApprovalOperation) async throws -> ApprovalEnvelope {
        guard let session else { throw ApprovalFailure.invalid }
        let envelope = try signed(operation)
        let request = try makeRequest(origin: session.origin, path: "/peer-approval/v1/\(operation.rawValue)",
                                      body: JSONEncoder().encode(envelope))
        let exchange = Exchange(request: request, envelope: envelope)
        pending = exchange
        let data = try await exchangeReply(exchange)
        return try JSONDecoder().decode(ApprovalEnvelope.self, from: data)
    }

    private func signed(_ operation: ApprovalOperation, counterCode: String? = nil) throws -> ApprovalEnvelope {
        guard let p = session?.payload else { throw ApprovalFailure.invalid }
        let payload = ApprovalPayload(operation: operation, requestID: p.requestID, requester: p.requester,
            receiver: p.receiver, attemptNonce: p.attemptNonce, operationNonce: RemoteIdentityCrypto.randomChallenge(),
            challenge: p.challenge, expiresAtMilliseconds: p.expiresAtMilliseconds, phase: p.phase,
            counterCode: counterCode, responseDigest: nil)
        guard let signature = signer.signApproval(payload, reply: false) else { throw ApprovalFailure.unauthorized }
        return ApprovalEnvelope(payload: payload, signature: signature)
    }

    private func exchangeReply(_ exchange: Exchange) async throws -> Data {
        for attempt in 0..<2 {
            let data: Data
            do { data = try await fetchReply(exchange.request) }
            catch {
                if error is CancellationError || Task.isCancelled || error is ApprovalFailure || attempt == 1 { throw error }
                continue
            }
            if exchange.envelope.payload.operation == .redeem {
                _ = try verifiedPair(data, exchange: exchange)
            } else {
                guard let reply = try? JSONDecoder().decode(ApprovalEnvelope.self, from: data) else {
                    throw ApprovalFailure.unauthorized
                }
                try verify(reply, request: exchange.envelope)
                guard reply.payload.counterCode == nil, reply.payload.responseDigest == nil,
                      reply.payload.challenge != exchange.envelope.payload.challenge else { throw ApprovalFailure.unauthorized }
                if exchange.envelope.payload.operation == .submit {
                    guard reply.payload.expiresAtMilliseconds > milliseconds,
                          reply.payload.expiresAtMilliseconds <= milliseconds + 120_000 else { throw ApprovalFailure.expired }
                } else if reply.payload.expiresAtMilliseconds != exchange.envelope.payload.expiresAtMilliseconds {
                    throw ApprovalFailure.unauthorized
                }
                update(reply.payload)
            }
            pending = nil
            return data
        }
        throw ApprovalFailure.invalid
    }

    private struct PairBody: Decodable {
        let token: String
        let serverId: String
        let name: String
        let publicKey: String
    }

    private func verifiedPair(_ data: Data, exchange: Exchange) throws -> PairBody {
        guard let reply = try? JSONDecoder().decode(ApprovalPairReply.self, from: data) else { throw ApprovalFailure.unauthorized }
        try verify(reply.proof, request: exchange.envelope)
        let p = reply.proof.payload
        let digest = SHA256.hash(data: reply.pairBody).map { String(format: "%02x", $0) }.joined()
        guard p.phase == .redeeming, p.responseDigest == digest,
              p.counterCode == exchange.envelope.payload.counterCode,
              p.challenge == exchange.envelope.payload.challenge,
              p.expiresAtMilliseconds == exchange.envelope.payload.expiresAtMilliseconds,
              let pair = try? JSONDecoder().decode(PairBody.self, from: reply.pairBody),
              !pair.token.isEmpty, pair.serverId == p.receiver.serverID,
              pair.publicKey == p.receiver.publicKey, pair.name == p.receiver.name
        else { throw ApprovalFailure.unauthorized }
        update(p)
        return pair
    }

    private func verify(_ reply: ApprovalEnvelope, request: ApprovalEnvelope) throws {
        let p = reply.payload, q = request.payload
        guard let session, p.operation == q.operation, p.requestID == q.requestID,
              p.requester == q.requester, p.receiver == q.receiver, p.attemptNonce == q.attemptNonce,
              p.operationNonce == q.operationNonce,
              ApprovalWire.verify(reply, expectedKey: session.receiverKey, reply: true)
        else { throw ApprovalFailure.unauthorized }
    }

    private func update(_ payload: ApprovalPayload, origin: String? = nil, receiverKey: String? = nil) {
        guard let origin = origin ?? session?.origin, let key = receiverKey ?? session?.receiverKey else { return }
        let value = ApprovalSession(payload: payload, receiverKey: key, origin: origin)
        session = value
        onSessionChange?(value)
    }

    private func makeRequest(origin: String, path: String, body: Data) throws -> URLRequest {
        guard body.count <= Self.maxReplyBytes, let url = URL(string: origin + path) else { throw ApprovalFailure.invalid }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.httpBody = body
        return request
    }

    private func fetchReply(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await fetch(request)
        guard data.count <= Self.maxReplyBytes else { throw ApprovalFailure.invalid }
        switch response.statusCode {
        case 200: return data
        case 401: throw ApprovalFailure.unauthorized
        case 403: throw ApprovalFailure.disabled
        case 409: throw ApprovalFailure.conflict
        case 410: throw ApprovalFailure.expired
        case 429: throw ApprovalFailure.throttled
        default: throw ApprovalFailure.invalid
        }
    }

    private var milliseconds: Int64 { Int64(now().timeIntervalSince1970 * 1_000) }
}
