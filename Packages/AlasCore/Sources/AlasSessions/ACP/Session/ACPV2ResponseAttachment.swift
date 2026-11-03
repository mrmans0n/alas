import Foundation
import AlasACP
import AlasPlatform

/// Holds concrete attachment authority, never reconstructed from ledger history.
public struct ACPV2ResponseAttachment: Sendable {
    public enum Reconciliation: Equatable, Sendable { case eligible, unavailable, observationLost }
    private enum Client: Sendable { case stdio(ACPStdioClient), broker(ACPBrokerClient) }
    private let client: Client
    private let localSessionId: String?
    let identity: ACPV2InboundReceiptOwner.Attachment

    @MainActor
    public init(stdioClient: ACPStdioClient) throws {
        identity = try .init(stdioClient: stdioClient)
        client = .stdio(stdioClient)
        localSessionId = nil
    }

    @MainActor
    public init(brokerClient: ACPBrokerClient, opened: ACPBrokerOpenResult) throws {
        identity = try .init(brokerClient: brokerClient, opened: opened)
        client = .broker(brokerClient)
        localSessionId = opened.snapshot.metadata.alasSessionId
    }

    func accepts(_ stream: ACPV2InboundLedgerStream) -> Bool {
        guard localSessionId.map({ $0.utf8.elementsEqual(stream.sessionId.utf8) }) ?? true else { return false }
        switch (identity.source, stream.source) {
        case (.stdio(let a), .stdio(let b)): return a == b
        case (.broker(let a, let ag), .broker(let b, let bg)):
            return a.rawValue.utf8.elementsEqual(b.rawValue.utf8) && ag == bg
        default: return false
        }
    }

    /// Positive eligibility is an observation. Exact transport origin checks
    /// remain authoritative if a request changes before write claim.
    public func reconcile(_ record: ACPV2InboundLedgerRecord, in stream: ACPV2InboundLedgerStream,
        delivery: ACPV2InboundDelivery? = nil) async -> Reconciliation {
        guard record.streamID == stream.id, accepts(stream) else { return .unavailable }
        switch (client, record.source, stream.source) {
        case (.stdio(let client), .stdio, .stdio):
            guard let delivery, case .stdio = delivery.source, delivery.receiptID == record.receiptID,
                  delivery.connectionID == record.connectionID, delivery.frame == record.frame else { return .unavailable }
            return client.canRespondToV2Request(delivery) ? .eligible : .unavailable
        case (.broker(let client), .broker(let provenance, let pending), .broker(let broker, let generation)):
            guard provenance.brokerID.rawValue.utf8.elementsEqual(broker.rawValue.utf8), provenance.generation == generation,
                  let pending else { return .unavailable }
            do {
                let view = try await client.currentRawPendingRequests()
                guard view.connectionID == identity.connectionID, view.generation == generation,
                      view.brokerID.rawValue.utf8.elementsEqual(broker.rawValue.utf8) else { return .observationLost }
                guard let requestID = try record.decodeHeader().id else { return .unavailable }
                let origins = try view.requests.filter { candidate in
                    guard let bytes = candidate.rawFrame?.bytes, let id = try ACPV2InboundDelivery.decodeHeader(from: bytes).id else { return false }
                    return responseIDsEqual(id, requestID)
                }
                // Distinct pending keys must not grant two reply authorities
                // for one wire ID. Completed origins are absent from this view.
                guard origins.count == 1, let candidate = origins.first else { return .unavailable }
                return candidate.requestId.utf8.elementsEqual(pending.utf8) && candidate.originCursor == provenance.cursor
                    && candidate.rawFrame?.bytes == record.frame ? .eligible : .unavailable
            } catch { return .observationLost }
        default: return .unavailable
        }
    }

    func handoff(intent: ACPV2ResponseIntent, attempt: ACPV2ResponseAttempt,
        delivery: ACPV2InboundDelivery?) async throws -> ACPV2ResponseEvidence {
        switch client {
        case .stdio(let client):
            guard let delivery else { throw ACPV2ResponseOwner.Failure.unavailable }
            return .stdio(try await client.respondToV2Request(delivery, expectedConnectionID: identity.connectionID,
                operationKey: attempt.operationKey, frame: intent.frame))
        case .broker(let client):
            guard case .broker(let provenance, let pending) = intent.request.source, let pending else {
                throw ACPV2ResponseOwner.Failure.unavailable
            }
            return .broker(try await client.respondToRawRequestExact(expectedConnectionID: identity.connectionID,
                params: .init(brokerId: provenance.brokerID, generation: provenance.generation, pendingRequestId: pending,
                    originCursor: provenance.cursor, operationKey: .init(rawValue: attempt.operationKey.rawValue), frame: .init(bytes: intent.frame))))
        }
    }
}
