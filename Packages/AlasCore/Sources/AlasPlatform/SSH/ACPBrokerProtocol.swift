import Foundation
import AlasFoundation
import AlasModel

public struct ACPBrokerID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ACPBrokerGeneration: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ACPBrokerGeneration, rhs: ACPBrokerGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ACPBrokerEventCursor: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ACPBrokerEventCursor, rhs: ACPBrokerEventCursor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ACPBrokerOperationKey: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ACPBrokerAdapterRequestID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ACPBrokerTurnState: Equatable, Sendable {
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
    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

public enum ACPBrokerPendingRequestKind: String, Codable, Equatable, Sendable {
    case permission
    case question
    case elicitation
    case file
    case terminal
    case plan
    case cursorExtension
}

public struct ACPBrokerMetadata: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let alasSessionId: String
    public let adapterProgram: String
    public let adapterArgs: [String]
    public let cwd: String
    public let envKeys: [String]
    public let createdAtMillis: UInt64

    public init(brokerId: ACPBrokerID, generation: ACPBrokerGeneration, alasSessionId: String, adapterProgram: String, adapterArgs: [String], cwd: String, envKeys: [String], createdAtMillis: UInt64) {
        self.brokerId = brokerId
        self.generation = generation
        self.alasSessionId = alasSessionId
        self.adapterProgram = adapterProgram
        self.adapterArgs = adapterArgs
        self.cwd = cwd
        self.envKeys = envKeys
        self.createdAtMillis = createdAtMillis
    }
}

public struct ACPBrokerPendingRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let adapterRequestId: ACPBrokerJSONValue
    public let kind: ACPBrokerPendingRequestKind
    public let payload: ACPBrokerJSONValue

    public init(requestId: String, adapterRequestId: ACPBrokerJSONValue, kind: ACPBrokerPendingRequestKind, payload: ACPBrokerJSONValue) {
        self.requestId = requestId
        self.adapterRequestId = adapterRequestId
        self.kind = kind
        self.payload = payload
    }
}

public struct ACPBrokerRPCOutcome: Codable, Equatable, Sendable {
    public let result: ACPBrokerJSONValue?
    public let error: JSONRPCError?

    public init(result: ACPBrokerJSONValue?, error: JSONRPCError?) {
        self.result = result
        self.error = error
    }
}

/// Deliberately carries no `params`. Nothing here reads them — `setSnapshot`
/// uses only the request id, operation key and terminal outcome — and a
/// prompt's params can be hundreds of megabytes, which the broker would then
/// serialize into every attach reply. A broker from an older build still
/// sends the field; `Codable` ignores it.
public struct ACPBrokerOperationSnapshot: Codable, Equatable, Sendable {
    public let operationKey: ACPBrokerOperationKey
    public let adapterRequestId: ACPBrokerAdapterRequestID
    public let method: String
    public let terminalOutcome: ACPBrokerRPCOutcome?

    public init(operationKey: ACPBrokerOperationKey, adapterRequestId: ACPBrokerAdapterRequestID, method: String, terminalOutcome: ACPBrokerRPCOutcome?) {
        self.operationKey = operationKey
        self.adapterRequestId = adapterRequestId
        self.method = method
        self.terminalOutcome = terminalOutcome
    }
}

public struct ACPBrokerSnapshot: Codable, Equatable, Sendable {
    public let metadata: ACPBrokerMetadata
    public let initializeResult: ACPBrokerJSONValue?
    public let remoteSessionResult: ACPBrokerJSONValue?
    public let turnState: ACPBrokerTurnState
    public let acknowledgedCursor: ACPBrokerEventCursor
    public let journalTail: ACPBrokerEventCursor
    public let pendingRequests: [ACPBrokerPendingRequest]
    public let operations: [ACPBrokerOperationSnapshot]
    public var cursorTodosByToolCallId: [String: [ACPCursorTodo]]? = nil

    public init(metadata: ACPBrokerMetadata, initializeResult: ACPBrokerJSONValue?, remoteSessionResult: ACPBrokerJSONValue?, turnState: ACPBrokerTurnState, acknowledgedCursor: ACPBrokerEventCursor, journalTail: ACPBrokerEventCursor, pendingRequests: [ACPBrokerPendingRequest], operations: [ACPBrokerOperationSnapshot], cursorTodosByToolCallId: [String: [ACPCursorTodo]]? = nil) {
        self.metadata = metadata
        self.initializeResult = initializeResult
        self.remoteSessionResult = remoteSessionResult
        self.turnState = turnState
        self.acknowledgedCursor = acknowledgedCursor
        self.journalTail = journalTail
        self.pendingRequests = pendingRequests
        self.operations = operations
        self.cursorTodosByToolCallId = cursorTodosByToolCallId
    }
}

public struct ACPBrokerEvent: Codable, Equatable, Sendable {
    public let cursor: ACPBrokerEventCursor
    public let kind: ACPBrokerEventKind

    public init(cursor: ACPBrokerEventCursor, kind: ACPBrokerEventKind) {
        self.cursor = cursor
        self.kind = kind
    }
}

public enum ACPBrokerEventKind: Equatable, Sendable {
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

public struct ACPBrokerOpenParams: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let sessionId: String
    public let command: String
    public let args: [String]
    public let cwd: String
    public let env: [String: String]

    public init(brokerId: ACPBrokerID, sessionId: String, command: String, args: [String], cwd: String, env: [String: String]) {
        self.brokerId = brokerId
        self.sessionId = sessionId
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
    }
}

public struct ACPBrokerOpenResult: Codable, Equatable, Sendable {
    public let snapshot: ACPBrokerSnapshot
    public let adopted: Bool

    public init(snapshot: ACPBrokerSnapshot, adopted: Bool) {
        self.snapshot = snapshot
        self.adopted = adopted
    }
}

public struct ACPBrokerAttachParams: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let acknowledgedCursor: ACPBrokerEventCursor
    public var replayAfterCursor: ACPBrokerEventCursor? = nil
    public var maxReplayBytes: Int? = nil
    public var snapshotOnLastPageOnly: Bool? = nil

    public init(brokerId: ACPBrokerID, generation: ACPBrokerGeneration, acknowledgedCursor: ACPBrokerEventCursor, replayAfterCursor: ACPBrokerEventCursor? = nil, maxReplayBytes: Int? = nil, snapshotOnLastPageOnly: Bool? = nil) {
        self.brokerId = brokerId
        self.generation = generation
        self.acknowledgedCursor = acknowledgedCursor
        self.replayAfterCursor = replayAfterCursor
        self.maxReplayBytes = maxReplayBytes
        self.snapshotOnLastPageOnly = snapshotOnLastPageOnly
    }
}

public struct ACPBrokerAttachResult: Codable, Equatable, Sendable {
    public let snapshot: ACPBrokerSnapshot?
    public let events: [ACPBrokerEvent]
    public var hasMoreEvents: Bool? = nil
    public var pendingRequestIds: [String]? = nil

    public init(snapshot: ACPBrokerSnapshot?, events: [ACPBrokerEvent], hasMoreEvents: Bool? = nil, pendingRequestIds: [String]? = nil) {
        self.snapshot = snapshot
        self.events = events
        self.hasMoreEvents = hasMoreEvents
        self.pendingRequestIds = pendingRequestIds
    }
}

public struct ACPBrokerSendParams: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let operationKey: ACPBrokerOperationKey
    public let method: String
    public let params: ACPBrokerJSONValue

    public init(brokerId: ACPBrokerID, generation: ACPBrokerGeneration, operationKey: ACPBrokerOperationKey, method: String, params: ACPBrokerJSONValue) {
        self.brokerId = brokerId
        self.generation = generation
        self.operationKey = operationKey
        self.method = method
        self.params = params
    }
}

public struct ACPBrokerNotifyParams: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let method: String
    public let params: ACPBrokerJSONValue

    public init(brokerId: ACPBrokerID, generation: ACPBrokerGeneration, method: String, params: ACPBrokerJSONValue) {
        self.brokerId = brokerId
        self.generation = generation
        self.method = method
        self.params = params
    }
}

public struct ACPBrokerSendResult: Codable, Equatable, Sendable {
    public let requestId: ACPBrokerAdapterRequestID
    public let replayed: Bool
    public let result: ACPBrokerJSONValue?
    public let error: JSONRPCError?
    public let pending: Bool?

    public init(
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

public struct ACPBrokerRespondParams: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let requestId: ACPBrokerJSONValue
    public let operationKey: ACPBrokerOperationKey
    public let result: ACPBrokerJSONValue?
    public let error: JSONRPCError?

    public init(
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

public struct ACPBrokerSimpleOK: Codable, Equatable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public struct ACPBrokerAckParams: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let cursor: ACPBrokerEventCursor

    public init(brokerId: ACPBrokerID, generation: ACPBrokerGeneration, cursor: ACPBrokerEventCursor) {
        self.brokerId = brokerId
        self.generation = generation
        self.cursor = cursor
    }
}

public struct ACPBrokerDetachParams: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration

    public init(brokerId: ACPBrokerID, generation: ACPBrokerGeneration) {
        self.brokerId = brokerId
        self.generation = generation
    }
}

public struct ACPBrokerCloseParams: Codable, Equatable, Sendable {
    public let brokerId: ACPBrokerID
    public let generation: ACPBrokerGeneration

    public init(brokerId: ACPBrokerID, generation: ACPBrokerGeneration) {
        self.brokerId = brokerId
        self.generation = generation
    }
}

public struct ACPBrokerListResult: Codable, Equatable, Sendable {
    public let brokers: [ACPBrokerSnapshot]

    public init(brokers: [ACPBrokerSnapshot]) {
        self.brokers = brokers
    }
}

public enum ACPBrokerJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ACPBrokerJSONValue])
    case object([String: ACPBrokerJSONValue])

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

    public static func object(from decoder: Decoder) throws -> [String: ACPBrokerJSONValue] {
        try [String: ACPBrokerJSONValue](from: decoder)
    }

    public var data: Data {
        get throws {
            try JSONEncoder().encode(self)
        }
    }
}
