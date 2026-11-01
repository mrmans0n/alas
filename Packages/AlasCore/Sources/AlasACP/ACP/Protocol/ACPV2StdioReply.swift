import Foundation
import AlasFoundation

public struct ACPV2ReplyOperationKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8) }
    public func hash(into hasher: inout Hasher) { hasher.combine(Data(rawValue.utf8)) }
}

public enum ACPV2StdioReplyStatus: Equatable, Sendable {
    case queued, inFlight, written, writeUncertain, notWritten
}

/// Connection-local facts. Even written proves neither adapter receipt nor
/// execution and never grants authority to answer through another connection.
public struct ACPV2StdioReplyResult: Equatable, Sendable {
    public let connectionID: UUID
    public let receiptID: UUID
    public let requestID: JSONRPCID
    public let operationKey: ACPV2ReplyOperationKey
    public let status: ACPV2StdioReplyStatus

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.connectionID == rhs.connectionID && lhs.receiptID == rhs.receiptID
            && StdioReplyID(lhs.requestID) == StdioReplyID(rhs.requestID)
            && lhs.operationKey == rhs.operationKey && lhs.status == rhs.status
    }
}

public enum ACPV2StdioReplyError: Error, Equatable, Sendable {
    case unsupported, invalidOrigin, invalidFrame, invalidOperationKey, conflict, invalidated
}

private enum StdioReplyID: Hashable {
    case number(Int)
    case string(Data)
    init(_ id: JSONRPCID) {
        switch id {
        case .number(let value): self = .number(value)
        case .string(let value): self = .string(Data(value.utf8))
        }
    }
}

/// Owns metadata only for actual captures. It never parses method payloads,
/// consumes receipts or persists/reconstructs request authority.
final class ACPV2StdioReplyState: @unchecked Sendable {
    private struct Origin {
        let receiptID: UUID
        let connectionID: UUID
        let id: JSONRPCID
        var reserved: ACPV2ReplyOperationKey?
    }
    private enum Slot { case active(UUID), ambiguous }
    private typealias Waiter = CheckedContinuation<ACPV2StdioReplyResult, Error>
    private final class Attempt {
        let origin: Origin
        let key: ACPV2ReplyOperationKey
        let frame: Data
        let caller: UUID
        var status: ACPV2StdioReplyStatus = .queued
        var waiter: Waiter?
        init(origin: Origin, key: ACPV2ReplyOperationKey, frame: Data, caller: UUID, waiter: Waiter) {
            self.origin = origin
            self.key = key
            self.frame = frame
            self.caller = caller
            self.waiter = waiter
        }
        func proof(_ status: ACPV2StdioReplyStatus? = nil) -> ACPV2StdioReplyResult {
            .init(connectionID: origin.connectionID, receiptID: origin.receiptID, requestID: origin.id,
                operationKey: key, status: status ?? self.status)
        }
        func takeWaiter(_ status: ACPV2StdioReplyStatus? = nil) -> Wake? {
            guard let waiter else { return nil }
            self.waiter = nil
            return (waiter, proof(status))
        }
    }
    private typealias Wake = (Waiter, ACPV2StdioReplyResult)
    private let lock = NSLock()
    private var stopped = false
    private var origins: [UUID: Origin] = [:]
    private var slots: [StdioReplyID: Slot] = [:]
    // Retained for this connection's lifetime. Forgetting a terminal attempt
    // could make an identical later call write a second answer.
    private var attempts: [ACPV2ReplyOperationKey: Attempt] = [:]

    func register(_ delivery: ACPV2InboundDelivery, id: JSONRPCID) {
        let wake: Wake? = lock.withLock {
            guard !stopped else { return nil }
            let wire = StdioReplyID(id)
            let origin = Origin(receiptID: delivery.receiptID, connectionID: delivery.connectionID, id: id)
            origins[delivery.receiptID] = origin
            switch slots[wire] {
            case nil: slots[wire] = .active(delivery.receiptID)
            case .active(let old):
                if let key = origins[old]?.reserved, let attempt = attempts[key] {
                    if attempt.status == .inFlight {
                        slots[wire] = .active(delivery.receiptID)
                        return nil
                    }
                    if attempt.status == .queued {
                        attempt.status = .notWritten
                        unreserve(attempt)
                        slots[wire] = .ambiguous
                        return attempt.takeWaiter()
                    }
                }
                slots[wire] = .ambiguous
            case .ambiguous: break
            }
            return nil
        }
        if let wake { wake.0.resume(returning: wake.1) }
    }

    func reply(_ delivery: ACPV2InboundDelivery, key: ACPV2ReplyOperationKey, frame: Data,
        writer: any JSONRPCFrameWriting, onFailure: @escaping @Sendable () -> Void) async throws -> ACPV2StdioReplyResult {
        guard !Task.isCancelled else { throw ACPV2StdioReplyError.invalidated }
        if let known = try lock.withLock({ try known(delivery, key: key, frame: frame) }) { return known }
        guard !key.rawValue.isEmpty else { throw ACPV2StdioReplyError.invalidOperationKey }
        let responseID: JSONRPCID
        do { responseID = try ACPRawReply.validateFrame(frame) }
        catch { throw ACPV2StdioReplyError.invalidFrame }
        let caller = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let immediate: ACPV2StdioReplyResult? = try lock.withLock {
                        if let known = try known(delivery, key: key, frame: frame) { return known }
                        guard !stopped, !Task.isCancelled else { throw ACPV2StdioReplyError.invalidated }
                        guard var origin = origins[delivery.receiptID], current(origin),
                              StdioReplyID(origin.id) == StdioReplyID(responseID) else { throw ACPV2StdioReplyError.invalidOrigin }
                        guard origin.reserved == nil else { throw ACPV2StdioReplyError.conflict }
                        origin.reserved = key
                        origins[delivery.receiptID] = origin
                        attempts[key] = Attempt(origin: origin, key: key, frame: frame, caller: caller, waiter: continuation)
                        return nil
                    }
                    if let immediate { continuation.resume(returning: immediate)
                    return }
                    Task {
                        let result = await writer.writeFrame(frame, authorize: { self.authorize(key) })
                        self.finish(key, result: result)
                        if case .writeUncertain = result { onFailure() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { self.cancel(key, caller: caller) }
    }

    // Must be called with the registry lock held.
    private func known(_ delivery: ACPV2InboundDelivery, key: ACPV2ReplyOperationKey, frame: Data) throws -> ACPV2StdioReplyResult? {
        guard let attempt = attempts[key] else { return nil }
        guard attempt.origin.receiptID == delivery.receiptID, attempt.origin.connectionID == delivery.connectionID,
              attempt.frame == frame else { throw ACPV2StdioReplyError.conflict }
        return attempt.proof()
    }
    private func current(_ origin: Origin) -> Bool {
        if case .active(let receipt) = slots[StdioReplyID(origin.id)] { return receipt == origin.receiptID }
        return false
    }
    private func unreserve(_ attempt: Attempt) {
        if origins[attempt.origin.receiptID]?.reserved == attempt.key { origins[attempt.origin.receiptID]?.reserved = nil }
    }
    private func authorize(_ key: ACPV2ReplyOperationKey) -> Bool {
        lock.withLock {
            guard !stopped, let attempt = attempts[key], attempt.status == .queued, current(attempt.origin) else { return false }
            attempt.status = .inFlight
            return true
        }
    }
    private func cancel(_ key: ACPV2ReplyOperationKey, caller: UUID) {
        let wake: Wake? = lock.withLock {
            guard let attempt = attempts[key], attempt.caller == caller else { return nil }
            if attempt.status == .queued {
                attempt.status = .notWritten
                unreserve(attempt)
                return attempt.takeWaiter()
            }
            if attempt.status == .inFlight { return attempt.takeWaiter(.writeUncertain) }
            return nil
        }
        if let wake { wake.0.resume(returning: wake.1) }
    }
    private func finish(_ key: ACPV2ReplyOperationKey, result: JSONRPCFrameWriteResult) {
        let wakes: [Wake] = lock.withLock {
            guard let attempt = attempts[key], attempt.status == .queued || attempt.status == .inFlight else { return [] }
            switch result {
            case .notWritten:
                attempt.status = .notWritten
                unreserve(attempt)
            case .written:
                attempt.status = .written
                if current(attempt.origin) { slots.removeValue(forKey: StdioReplyID(attempt.origin.id)) }
            case .writeUncertain: attempt.status = .writeUncertain
            }
            var wakes = attempt.takeWaiter().map { [$0] } ?? []
            if case .writeUncertain = result { wakes += stopLocked() }
            return wakes
        }
        for wake in wakes { wake.0.resume(returning: wake.1) }
    }
    private func stopLocked() -> [Wake] {
        stopped = true
        var wakes: [Wake] = []
        for attempt in attempts.values {
            if attempt.status == .queued {
                attempt.status = .notWritten
                unreserve(attempt)
                if let wake = attempt.takeWaiter() { wakes.append(wake) }
            } else if attempt.status == .inFlight, let wake = attempt.takeWaiter(.writeUncertain) { wakes.append(wake) }
        }
        return wakes
    }
    func stop() {
        let wakes = lock.withLock { stopLocked() }
        for wake in wakes { wake.0.resume(returning: wake.1) }
    }
}
