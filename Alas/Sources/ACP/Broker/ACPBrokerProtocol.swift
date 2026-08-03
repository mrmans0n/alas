import Foundation

struct ACPBrokerID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ACPBrokerGeneration: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: ACPBrokerGeneration, rhs: ACPBrokerGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ACPBrokerEventCursor: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: ACPBrokerEventCursor, rhs: ACPBrokerEventCursor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ACPBrokerOperationKey: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ACPBrokerAdapterRequestID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ACPBrokerTurnState: Equatable, Sendable {
    case idle
    case sending
    case streaming
    case awaitingInput
    case cancelling
    case completed
    case ambiguous
    case unknown(String)
}

extension ACPBrokerTurnState: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "idle": self = .idle
        case "sending": self = .sending
        case "streaming": self = .streaming
        case "awaitingInput": self = .awaitingInput
        case "cancelling": self = .cancelling
        case "completed": self = .completed
        case "ambiguous": self = .ambiguous
        default: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .idle: try container.encode("idle")
        case .sending: try container.encode("sending")
        case .streaming: try container.encode("streaming")
        case .awaitingInput: try container.encode("awaitingInput")
        case .cancelling: try container.encode("cancelling")
        case .completed: try container.encode("completed")
        case .ambiguous: try container.encode("ambiguous")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

enum ACPBrokerPendingRequestKind: String, Codable, Equatable, Sendable {
    case permission
    case question
    case elicitation
    case file
    case terminal
}

struct ACPBrokerMetadata: Codable, Equatable, Sendable {
    let brokerId: ACPBrokerID
    let generation: ACPBrokerGeneration
    let alasSessionId: String
    let adapterProgram: String
    let adapterArgs: [String]
    let cwd: String
    let envKeys: [String]
    let createdAtMillis: UInt64
}

struct ACPBrokerPendingRequest: Codable, Equatable, Sendable {
    let requestId: String
    let adapterRequestId: ACPBrokerJSONValue
    let kind: ACPBrokerPendingRequestKind
    let payload: ACPBrokerJSONValue
}

struct ACPBrokerRPCOutcome: Codable, Equatable, Sendable {
    let result: ACPBrokerJSONValue?
    let error: JSONRPCError?
}

/// Deliberately carries no `params`. Nothing here reads them — `setSnapshot`
/// uses only the request id, operation key and terminal outcome — and a
/// prompt's params can be hundreds of megabytes, which the broker would then
/// serialize into every attach reply. A broker from an older build still
/// sends the field; `Codable` ignores it.
struct ACPBrokerOperationSnapshot: Codable, Equatable, Sendable {
    let operationKey: ACPBrokerOperationKey
    let adapterRequestId: ACPBrokerAdapterRequestID
    let method: String
    let terminalOutcome: ACPBrokerRPCOutcome?
}

struct ACPBrokerSnapshot: Codable, Equatable, Sendable {
    let metadata: ACPBrokerMetadata
    let initializeResult: ACPBrokerJSONValue?
    let remoteSessionResult: ACPBrokerJSONValue?
    let turnState: ACPBrokerTurnState
    let acknowledgedCursor: ACPBrokerEventCursor
    let journalTail: ACPBrokerEventCursor
    let pendingRequests: [ACPBrokerPendingRequest]
    let operations: [ACPBrokerOperationSnapshot]
}

struct ACPBrokerEvent: Codable, Equatable, Sendable {
    let cursor: ACPBrokerEventCursor
    let kind: ACPBrokerEventKind
}

enum ACPBrokerEventKind: Equatable, Sendable {
    case initialized(result: ACPBrokerJSONValue)
    case remoteSessionReady(result: ACPBrokerJSONValue)
    case turnStateChanged(state: ACPBrokerTurnState)
    case pendingRequest(ACPBrokerPendingRequest)
    case pendingRequestResolved(requestId: String, response: ACPBrokerRPCOutcome)
    /// No `params` for the same reason as `ACPBrokerOperationSnapshot`: they
    /// are unread, and the replay would otherwise carry a second full copy of
    /// a prompt that the snapshot already carried once.
    case operationStarted(
        operationKey: ACPBrokerOperationKey,
        adapterRequestId: ACPBrokerAdapterRequestID,
        method: String
    )
    case operationCompleted(operationKey: ACPBrokerOperationKey, outcome: ACPBrokerRPCOutcome)
    case adapterNotification(method: String, params: ACPBrokerJSONValue)
    case unknown(type: String, payload: [String: ACPBrokerJSONValue])
}

extension ACPBrokerEventKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case result
        case state
        case request
        case requestId
        case response
        case operationKey
        case adapterRequestId
        case method
        case params
        case outcome
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "initialized":
            self = .initialized(result: try container.decode(ACPBrokerJSONValue.self, forKey: .result))
        case "remoteSessionReady":
            self = .remoteSessionReady(result: try container.decode(ACPBrokerJSONValue.self, forKey: .result))
        case "turnStateChanged":
            self = .turnStateChanged(state: try container.decode(ACPBrokerTurnState.self, forKey: .state))
        case "pendingRequest":
            self = .pendingRequest(try container.decode(ACPBrokerPendingRequest.self, forKey: .request))
        case "pendingRequestResolved":
            self = .pendingRequestResolved(
                requestId: try container.decode(String.self, forKey: .requestId),
                response: try container.decode(ACPBrokerRPCOutcome.self, forKey: .response)
            )
        case "operationStarted":
            self = .operationStarted(
                operationKey: try container.decode(ACPBrokerOperationKey.self, forKey: .operationKey),
                adapterRequestId: try container.decode(ACPBrokerAdapterRequestID.self, forKey: .adapterRequestId),
                method: try container.decode(String.self, forKey: .method)
            )
        case "operationCompleted":
            let outcome = try container.decodeIfPresent(ACPBrokerRPCOutcome.self, forKey: .outcome)
                ?? ACPBrokerRPCOutcome(
                    result: try container.decodeIfPresent(ACPBrokerJSONValue.self, forKey: .result),
                    error: try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
                )
            self = .operationCompleted(
                operationKey: try container.decode(ACPBrokerOperationKey.self, forKey: .operationKey),
                outcome: outcome
            )
        case "adapterNotification":
            self = .adapterNotification(
                method: try container.decode(String.self, forKey: .method),
                params: try container.decode(ACPBrokerJSONValue.self, forKey: .params)
            )
        default:
            let payload = try ACPBrokerJSONValue.object(from: decoder)
            self = .unknown(type: type, payload: payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .initialized(let result):
            try container.encode("initialized", forKey: .type)
            try container.encode(result, forKey: .result)
        case .remoteSessionReady(let result):
            try container.encode("remoteSessionReady", forKey: .type)
            try container.encode(result, forKey: .result)
        case .turnStateChanged(let state):
            try container.encode("turnStateChanged", forKey: .type)
            try container.encode(state, forKey: .state)
        case .pendingRequest(let request):
            try container.encode("pendingRequest", forKey: .type)
            try container.encode(request, forKey: .request)
        case .pendingRequestResolved(let requestId, let response):
            try container.encode("pendingRequestResolved", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(response, forKey: .response)
        case .operationStarted(let operationKey, let adapterRequestId, let method):
            try container.encode("operationStarted", forKey: .type)
            try container.encode(operationKey, forKey: .operationKey)
            try container.encode(adapterRequestId, forKey: .adapterRequestId)
            try container.encode(method, forKey: .method)
        case .operationCompleted(let operationKey, let outcome):
            try container.encode("operationCompleted", forKey: .type)
            try container.encode(operationKey, forKey: .operationKey)
            try container.encode(outcome, forKey: .outcome)
        case .adapterNotification(let method, let params):
            try container.encode("adapterNotification", forKey: .type)
            try container.encode(method, forKey: .method)
            try container.encode(params, forKey: .params)
        case .unknown(let type, let payload):
            try container.encode(type, forKey: .type)
            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in payload where key != "type" {
                try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
            }
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

struct ACPBrokerOpenParams: Codable, Equatable, Sendable {
    let brokerId: ACPBrokerID
    let sessionId: String
    let command: String
    let args: [String]
    let cwd: String
    let env: [String: String]
}

struct ACPBrokerOpenResult: Codable, Equatable, Sendable {
    let snapshot: ACPBrokerSnapshot
    let adopted: Bool
}

struct ACPBrokerAttachParams: Codable, Equatable, Sendable {
    let brokerId: ACPBrokerID
    let generation: ACPBrokerGeneration
    let acknowledgedCursor: ACPBrokerEventCursor
}

struct ACPBrokerAttachResult: Codable, Equatable, Sendable {
    let snapshot: ACPBrokerSnapshot
    let events: [ACPBrokerEvent]
}

struct ACPBrokerSendParams: Codable, Equatable, Sendable {
    let brokerId: ACPBrokerID
    let generation: ACPBrokerGeneration
    let operationKey: ACPBrokerOperationKey
    let method: String
    let params: ACPBrokerJSONValue
}

struct ACPBrokerNotifyParams: Codable, Equatable, Sendable {
    let brokerId: ACPBrokerID
    let generation: ACPBrokerGeneration
    let method: String
    let params: ACPBrokerJSONValue
}

struct ACPBrokerSendResult: Codable, Equatable, Sendable {
    let requestId: ACPBrokerAdapterRequestID
    let replayed: Bool
    let result: ACPBrokerJSONValue?
    let error: JSONRPCError?
    let pending: Bool?

    init(
        requestId: ACPBrokerAdapterRequestID,
        replayed: Bool,
        result: ACPBrokerJSONValue? = nil,
        error: JSONRPCError? = nil,
        pending: Bool? = nil
    ) {
        self.requestId = requestId
        self.replayed = replayed
        self.result = result
        self.error = error
        self.pending = pending
    }
}

struct ACPBrokerRespondParams: Codable, Equatable, Sendable {
    let brokerId: ACPBrokerID
    let generation: ACPBrokerGeneration
    let requestId: ACPBrokerJSONValue
    let operationKey: ACPBrokerOperationKey
    let result: ACPBrokerJSONValue?
    let error: JSONRPCError?

    init(
        brokerId: ACPBrokerID,
        generation: ACPBrokerGeneration,
        requestId: ACPBrokerJSONValue,
        operationKey: ACPBrokerOperationKey,
        result: ACPBrokerJSONValue? = nil,
        error: JSONRPCError? = nil
    ) {
        self.brokerId = brokerId
        self.generation = generation
        self.requestId = requestId
        self.operationKey = operationKey
        self.result = result
        self.error = error
    }
}

struct ACPBrokerSimpleOK: Codable, Equatable, Sendable {
    let ok: Bool
}

struct ACPBrokerAckParams: Codable, Equatable, Sendable {
    let brokerId: ACPBrokerID
    let generation: ACPBrokerGeneration
    let cursor: ACPBrokerEventCursor
}

struct ACPBrokerDetachParams: Codable, Equatable, Sendable {
    let brokerId: ACPBrokerID
    let generation: ACPBrokerGeneration
}

struct ACPBrokerCloseParams: Codable, Equatable, Sendable {
    let brokerId: ACPBrokerID
    let generation: ACPBrokerGeneration
}

struct ACPBrokerListResult: Codable, Equatable, Sendable {
    let brokers: [ACPBrokerSnapshot]
}

enum ACPBrokerJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ACPBrokerJSONValue])
    case object([String: ACPBrokerJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([ACPBrokerJSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: ACPBrokerJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    static func object(from decoder: Decoder) throws -> [String: ACPBrokerJSONValue] {
        try [String: ACPBrokerJSONValue](from: decoder)
    }

    var data: Data {
        get throws {
            try JSONEncoder().encode(self)
        }
    }
}
