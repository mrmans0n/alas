import CryptoKit
import Foundation
import Observation

enum ApprovalDecision: Equatable { case allow, decline }
struct ApprovalIssuedResponse {
    let body: Data
    let deviceID: String
}
enum ApprovalFailure: Error, Equatable {
    case invalid, unauthorized, disabled, expired, conflict, throttled, capacity
    var retryAfterSeconds: Int? { self == .throttled ? 2 : nil }
}

@MainActor @Observable final class RemotePairingApprovalCoordinator {
    struct Entry: Identifiable {
        let id: String
        var payload: ApprovalPayload
        var phase: ApprovalPhase
    }

    private struct Record {
        var entry: Entry
        var lastRequest: ApprovalEnvelope?
        var lastReply: ApprovalEnvelope?
        var lastStatusAt: Int64?
        var terminalAt: Int64?
        var redeemRequest: ApprovalEnvelope?
        var redeemResponse: ApprovalIssuedResponse?
        var redeemDeadline: Int64?
    }

    var entries: [Entry] { records.values.map(\.entry).sorted { $0.id < $1.id } }
    private var records: [String: Record] = [:]
    private var enabled = false
    private var admissions: [Int64] = []
    private var submissions: [String: [Int64]] = [:]
    private var declinedUntil: [String: Int64] = [:]
    private let localPeer: () -> ApprovalPeer
    private let signer: any ApprovalSigning
    private let now: () -> Date
    @ObservationIgnored var onCancelRedeeming: ((String) -> Void)?
    @ObservationIgnored var onReleaseAttempt: ((String) -> Void)?

    init(localPeer: @escaping () -> ApprovalPeer, signer: any ApprovalSigning,
         now: @escaping () -> Date = Date.init) {
        self.localPeer = localPeer
        self.signer = signer
        self.now = now
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { cancelAll() }
    }

    func challenge(requester: ApprovalPeer, attemptNonce: String) throws -> ApprovalEnvelope {
        expire()
        guard enabled else { throw ApprovalFailure.disabled }
        let time = milliseconds
        let receiver = localPeer()
        guard receiver.publicKey == signer.publicKey else { throw ApprovalFailure.unauthorized }
        let payload = ApprovalPayload(
            operation: .challenge, requestID: UUID().uuidString, requester: requester,
            receiver: receiver, attemptNonce: attemptNonce, operationNonce: Self.nonce(),
            challenge: Self.nonce(), expiresAtMilliseconds: time + 30_000,
            phase: .challenged, counterCode: nil, responseDigest: nil)
        guard !ApprovalWire.bytes(payload, reply: true).isEmpty else { throw ApprovalFailure.invalid }
        guard declinedUntil[requester.publicKey] == nil else { throw ApprovalFailure.throttled }
        if let existing = records.values.first(where: {
            $0.entry.payload.requester.publicKey == requester.publicKey && !Self.isTerminal($0.entry.phase)
        }) {
            guard existing.entry.phase == .challenged,
                  existing.entry.payload.requester == requester,
                  existing.entry.payload.receiver == receiver,
                  existing.entry.payload.attemptNonce == attemptNonce
            else { throw ApprovalFailure.conflict }
            return try signed(existing.entry.payload)
        }
        // Charge anonymous challenge admission, before a caller can rotate keys.
        guard admissions.count < 10 else { throw ApprovalFailure.throttled }
        guard records.values.filter({ $0.entry.phase == .challenged }).count < 32
        else { throw ApprovalFailure.capacity }
        let reply = try signed(payload)
        records[payload.requestID] = Record(entry: Entry(id: payload.requestID, payload: payload, phase: .challenged))
        admissions.append(time)
        return reply
    }

    func receive(_ envelope: ApprovalEnvelope) throws -> ApprovalEnvelope {
        expire()
        guard enabled else { throw ApprovalFailure.disabled }
        let payload = envelope.payload
        guard var record = records[payload.requestID] else { throw ApprovalFailure.invalid }
        let stored = record.entry.payload
        guard payload.requester == stored.requester, payload.receiver == stored.receiver,
              payload.attemptNonce == stored.attemptNonce,
              ApprovalWire.verify(envelope, expectedKey: stored.requester.publicKey, reply: false)
        else { throw ApprovalFailure.unauthorized }

        if record.lastRequest == envelope, let cached = record.lastReply {
            // Local decisions and expiry invalidate the cached phase, not the retry's authority.
            if cached.payload.phase == record.entry.phase { return cached }
            let reply = try signed(Self.payload(stored, operation: payload.operation,
                                                nonce: payload.operationNonce, phase: record.entry.phase))
            record.entry.payload = reply.payload
            record.lastReply = reply
            records[payload.requestID] = record
            return reply
        }

        // A cached redeem reply remains a cancellation capability for its own
        // attempt even if a status poll subsequently rotated the challenge.
        let cancellingRedeem = payload.operation == .cancel && payload.phase == .redeeming
            && record.redeemRequest?.payload.challenge == payload.challenge
            && record.redeemResponse != nil
        guard payload.challenge == stored.challenge || cancellingRedeem else { throw ApprovalFailure.conflict }
        guard payload.expiresAtMilliseconds == stored.expiresAtMilliseconds,
              payload.phase == stored.phase || cancellingRedeem,
              payload.counterCode == nil, payload.responseDigest == nil
        else { throw ApprovalFailure.invalid }
        let time = milliseconds
        switch payload.operation {
        case .submit:
            switch record.entry.phase {
            case .challenged:
                guard records.values.filter({ $0.entry.phase == .pending }).count < 3
                else { throw ApprovalFailure.capacity }
                guard (submissions[stored.requester.publicKey]?.count ?? 0) < 5
                else { throw ApprovalFailure.throttled }
                guard submissions.values.reduce(0, { $0 + $1.count }) < 10
                else { throw ApprovalFailure.throttled }
                guard declinedUntil[stored.requester.publicKey] == nil else { throw ApprovalFailure.throttled }
                record.entry.phase = .pending
                record.entry.payload = Self.payload(stored, operation: .submit, nonce: payload.operationNonce,
                                                    phase: .pending, deadline: time + 120_000)
            case .pending, .approved:
                break // An authenticated duplicate does not extend authorization or count twice.
            case .expired:
                throw ApprovalFailure.expired
            case .redeeming, .paired, .declined, .cancelled, .failed:
                throw ApprovalFailure.conflict
            }
        case .status:
            if let last = record.lastStatusAt, time - last < 1_000 { throw ApprovalFailure.throttled }
            record.lastStatusAt = time
        case .cancel:
            switch record.entry.phase {
            case .challenged, .pending, .approved, .redeeming:
                record.entry.phase = .cancelled
                record.terminalAt = time
            case .paired where record.redeemResponse != nil:
                record.entry.phase = .cancelled
                record.terminalAt = time
            case .paired, .declined, .cancelled, .expired, .failed:
                break
            }
        case .challenge, .redeem:
            throw ApprovalFailure.invalid
        }

        // Sign before publishing any state. A failed signer cannot consume a challenge.
        let response = Self.payload(record.entry.payload, operation: payload.operation,
                                    nonce: payload.operationNonce, phase: record.entry.phase,
                                    challenge: Self.nonce())
        let reply = try signed(response)
        if payload.operation == .submit && stored.phase == .challenged {
            submissions[stored.requester.publicKey, default: []].append(time)
        }
        record.entry.payload = response
        record.lastRequest = envelope
        record.lastReply = reply
        records[payload.requestID] = record
        if record.entry.phase == .cancelled { invalidateRedeem(requestID: payload.requestID) }
        trimTerminalRecords(at: time)
        return reply
    }

    func redeem(_ envelope: ApprovalEnvelope, issue: () throws -> ApprovalIssuedResponse) throws -> Data {
        expire()
        guard enabled else { throw ApprovalFailure.disabled }
        if let cached = exactAuthenticatedRetry(envelope) { return cached }
        let p = envelope.payload
        guard var record = records[p.requestID] else { throw ApprovalFailure.unauthorized }
        let stored = record.entry.payload
        guard p.operation == .redeem, p.requester == stored.requester, p.receiver == stored.receiver,
              p.attemptNonce == stored.attemptNonce, p.challenge == stored.challenge,
              p.expiresAtMilliseconds == stored.expiresAtMilliseconds, p.phase == stored.phase,
              p.counterCode?.isEmpty == false, p.responseDigest == nil,
              ApprovalWire.verify(envelope, expectedKey: stored.requester.publicKey, reply: false),
              record.entry.phase == .approved else { throw ApprovalFailure.unauthorized }
        record.entry.phase = .redeeming
        record.entry.payload = Self.payload(stored, operation: .redeem, nonce: p.operationNonce, phase: .redeeming)
        record.redeemDeadline = milliseconds + 120_000
        records[p.requestID] = record
        do {
            let response = try issue()
            guard records[p.requestID]?.entry.phase == .redeeming else {
                onCancelRedeeming?(p.requestID)
                throw ApprovalFailure.unauthorized
            }
            records[p.requestID]?.redeemRequest = envelope
            records[p.requestID]?.redeemResponse = response
            return response.body
        } catch {
            records[p.requestID]?.entry.phase = .failed
            records[p.requestID]?.terminalAt = milliseconds
            onCancelRedeeming?(p.requestID)
            throw error
        }
    }

    /// The pair body is hashed as encoded, so JSON key order cannot alter the proof.
    func pairReply(body: Data, for request: ApprovalEnvelope) throws -> Data {
        let p = request.payload
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let payload = ApprovalPayload(operation: .redeem, requestID: p.requestID, requester: p.requester,
            receiver: p.receiver, attemptNonce: p.attemptNonce, operationNonce: p.operationNonce,
            challenge: p.challenge, expiresAtMilliseconds: p.expiresAtMilliseconds,
            phase: .redeeming, counterCode: p.counterCode, responseDigest: digest)
        return try JSONEncoder().encode(ApprovalPairReply(pairBody: body, proof: signed(payload)))
    }

    func complete(requestID: String, succeeded: Bool) {
        expire()
        guard records[requestID]?.entry.phase == .redeeming else { return }
        records[requestID]?.entry.phase = succeeded ? .paired : .failed
        records[requestID]?.terminalAt = milliseconds
        if !succeeded { invalidateRedeem(requestID: requestID) }
    }

    func invalidate(deviceID: String) {
        for id in records.keys where records[id]?.redeemResponse?.deviceID == deviceID {
            records[id]?.entry.phase = .failed
            records[id]?.terminalAt = milliseconds
            invalidateRedeem(requestID: id)
        }
    }

    private func exactAuthenticatedRetry(_ envelope: ApprovalEnvelope) -> Data? {
        guard let record = records[envelope.payload.requestID], record.redeemRequest == envelope,
              record.entry.phase == .redeeming || record.entry.phase == .paired,
              ApprovalWire.verify(envelope, expectedKey: record.entry.payload.requester.publicKey, reply: false)
        else { return nil }
        return record.redeemResponse?.body
    }

    private func invalidateRedeem(requestID: String) {
        records[requestID]?.redeemResponse = nil
        records[requestID]?.redeemRequest = nil
        onCancelRedeeming?(requestID)
    }

    func decide(_ decision: ApprovalDecision, requestID: String) {
        guard var record = records[requestID], record.entry.phase == .pending else { return }
        let time = milliseconds
        guard time < record.entry.payload.expiresAtMilliseconds else {
            record.entry.phase = .expired
            record.terminalAt = record.entry.payload.expiresAtMilliseconds
            records[requestID] = record
            return
        }
        guard enabled else { return }
        switch decision {
        case .allow:
            record.entry.phase = .approved
        case .decline:
            record.entry.phase = .declined
            record.terminalAt = time
            declinedUntil[record.entry.payload.requester.publicKey] = time + 60_000
        }
        records[requestID] = record
        trimTerminalRecords(at: time)
    }

    func expire() {
        let time = milliseconds
        for (id, var record) in records {
            switch record.entry.phase {
            case .challenged, .pending, .approved:
                if time >= record.entry.payload.expiresAtMilliseconds {
                    record.entry.phase = .expired
                    record.terminalAt = record.entry.payload.expiresAtMilliseconds
                    records[id] = record
                }
            case .redeeming:
                if let deadline = record.redeemDeadline, time >= deadline {
                    record.entry.phase = .expired
                    record.terminalAt = time
                    records[id] = record
                    invalidateRedeem(requestID: id)
                }
            case .paired:
                if let deadline = record.redeemDeadline, time >= deadline {
                    records[id]?.redeemResponse = nil
                    records[id]?.redeemRequest = nil
                    onReleaseAttempt?(id)
                }
            case .declined, .cancelled, .expired, .failed:
                break
            }
        }
        admissions.removeAll { time - $0 >= 60_000 }
        submissions = submissions.compactMapValues { times in
            let remaining = times.filter { time - $0 < 60_000 }
            return remaining.isEmpty ? nil : remaining
        }
        declinedUntil = declinedUntil.filter { $0.value > time }
        trimTerminalRecords(at: time)
    }

    func cancelAll() {
        let time = milliseconds
        for (id, var record) in records {
            switch record.entry.phase {
            case .challenged, .pending, .approved, .redeeming:
                record.entry.phase = .cancelled
                record.terminalAt = time
                records[id] = record
                invalidateRedeem(requestID: id)
            case .paired, .declined, .cancelled, .expired, .failed:
                records[id]?.redeemResponse = nil
                records[id]?.redeemRequest = nil
                onReleaseAttempt?(id)
                break
            }
        }
        trimTerminalRecords(at: time)
    }

    private var milliseconds: Int64 { Int64((now().timeIntervalSince1970 * 1_000).rounded(.down)) }

    private func signed(_ payload: ApprovalPayload) throws -> ApprovalEnvelope {
        guard signer.publicKey == payload.receiver.publicKey,
              !ApprovalWire.bytes(payload, reply: true).isEmpty,
              let signature = signer.signApproval(payload, reply: true)
        else { throw ApprovalFailure.unauthorized }
        let envelope = ApprovalEnvelope(payload: payload, signature: signature)
        guard ApprovalWire.verify(envelope, expectedKey: payload.receiver.publicKey, reply: true)
        else { throw ApprovalFailure.unauthorized }
        return envelope
    }

    private func trimTerminalRecords(at time: Int64) {
        for (id, record) in records where record.terminalAt.map({ time - $0 >= 120_000 }) ?? false {
            records.removeValue(forKey: id)
            onReleaseAttempt?(id)
        }
        let terminals = records.values.filter { $0.terminalAt != nil }.sorted {
            ($0.terminalAt!, $0.entry.id) < ($1.terminalAt!, $1.entry.id)
        }
        for record in terminals.prefix(max(0, terminals.count - 64)) {
            records.removeValue(forKey: record.entry.id)
            onReleaseAttempt?(record.entry.id)
        }
    }

    private static func isTerminal(_ phase: ApprovalPhase) -> Bool {
        switch phase {
        case .challenged, .pending, .approved, .redeeming: false
        case .paired, .declined, .cancelled, .expired, .failed: true
        }
    }

    private static func nonce() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func payload(_ source: ApprovalPayload, operation: ApprovalOperation,
                                nonce: String, phase: ApprovalPhase,
                                challenge: String? = nil, deadline: Int64? = nil) -> ApprovalPayload {
        ApprovalPayload(operation: operation, requestID: source.requestID, requester: source.requester,
                        receiver: source.receiver, attemptNonce: source.attemptNonce, operationNonce: nonce,
                        challenge: challenge ?? source.challenge,
                        expiresAtMilliseconds: deadline ?? source.expiresAtMilliseconds,
                        phase: phase, counterCode: nil, responseDigest: nil)
    }
}
