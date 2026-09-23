import CryptoKit
import Foundation
import Observation

enum ApprovalDecision: Equatable { case allow, decline }
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

        guard payload.challenge == stored.challenge else { throw ApprovalFailure.conflict }
        guard payload.expiresAtMilliseconds == stored.expiresAtMilliseconds,
              payload.phase == stored.phase,
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
        trimTerminalRecords(at: time)
        return reply
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
            case .redeeming, .paired, .declined, .cancelled, .expired, .failed:
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
            case .paired, .declined, .cancelled, .expired, .failed:
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
        records = records.filter { _, record in
            record.terminalAt.map { time - $0 < 120_000 } ?? true
        }
        let terminals = records.values.filter { $0.terminalAt != nil }.sorted {
            ($0.terminalAt!, $0.entry.id) < ($1.terminalAt!, $1.entry.id)
        }
        for record in terminals.prefix(max(0, terminals.count - 64)) {
            records.removeValue(forKey: record.entry.id)
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
