import Foundation

/// One explicit reply attempt. Retrying preserves the operation key and bytes.
public struct ACPBrokerRespondExactParams: Codable, Equatable, Sendable {
    public let wireContext: ACPBrokerWireContext
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let pendingRequestId: String
    public let originCursor: ACPBrokerEventCursor
    public let operationKey: ACPBrokerOperationKey
    public let frame: ACPBrokerRawJSONPayload

    public init(brokerId: ACPBrokerID, generation: ACPBrokerGeneration, pendingRequestId: String,
        originCursor: ACPBrokerEventCursor, operationKey: ACPBrokerOperationKey, frame: ACPBrokerRawJSONPayload) {
        wireContext = .rawV2
        self.brokerId = brokerId
        self.generation = generation
        self.pendingRequestId = pendingRequestId
        self.originCursor = originCursor
        self.operationKey = operationKey
        self.frame = frame
    }
}

public enum ACPBrokerRawReplyStatus: String, Codable, Equatable, Sendable {
    case inFlight, written, writeUncertain
}

/// Written means the local pipe write and flush completed, not adapter receipt.
public struct ACPBrokerRawReplyResult: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let pendingRequestId: String
    public let originCursor: ACPBrokerEventCursor
    public let operationKey: ACPBrokerOperationKey
    public let status: ACPBrokerRawReplyStatus

    public init(params: ACPBrokerRespondExactParams, status: ACPBrokerRawReplyStatus) {
        brokerId = params.brokerId
        generation = params.generation
        pendingRequestId = params.pendingRequestId
        originCursor = params.originCursor
        operationKey = params.operationKey
        self.status = status
    }

    public func matches(_ params: ACPBrokerRespondExactParams) -> Bool {
        brokerId.rawValue.utf8.elementsEqual(params.brokerId.rawValue.utf8) && generation == params.generation
            && pendingRequestId.utf8.elementsEqual(params.pendingRequestId.utf8) && originCursor == params.originCursor
            && operationKey.rawValue.utf8.elementsEqual(params.operationKey.rawValue.utf8)
    }
}

public enum ACPBrokerRawReplyRejection: Int, Codable, Equatable, Sendable {
    case invalid = -32077, staleOrigin = -32078, conflict = -32079, unavailable = -32080
}

public enum ACPBrokerRawReplyError: Error, Equatable, Sendable {
    /// The rejected call did not start a new adapter write. Prior attempts may exist.
    case rejected(ACPBrokerRawReplyRejection)
    /// No trustworthy terminal write evidence was returned. Do not resend with a new key.
    case uncertain(String)
}
