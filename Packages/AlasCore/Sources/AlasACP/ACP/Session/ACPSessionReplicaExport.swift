import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct ACPSessionReplicaExport: Sendable {
    public struct Receipt: Sendable {
        public let kind: String
        public let key: String
        public let serial: Int64

        public init(kind: String, key: String, serial: Int64) {
            self.kind = kind
            self.key = key
            self.serial = serial
        }
    }
    public let batchId: String
    public let entries: [RemoteSessionReplicaEntry]
    public let receipts: [Receipt]

    public init(batchId: String, entries: [RemoteSessionReplicaEntry], receipts: [Receipt]) {
        self.batchId = batchId
        self.entries = entries
        self.receipts = receipts
    }
}

public struct ACPSessionReplicaImportGuard: Sendable {
    public let sessionId: String
    public let expectedLocalFence: ACPSessionLeaseFence?

    public init(sessionId: String, expectedLocalFence: ACPSessionLeaseFence?) {
        self.sessionId = sessionId
        self.expectedLocalFence = expectedLocalFence
    }
}

package struct ReplicaMetadata: Codable {
    package let title: String
    package let titleSource: ACPSessionTitleSource
    package let origin: ACPSessionOrigin
    package let contextRecoveryPending: Bool
    package let mcpPreamblePending: String?
    package let mcpPreambleSent: Bool
    package let usageLimit: ACPUsageLimit?
    /// Optional so metadata from a Mac that predates the marker still decodes.
    package let directTurnInFlight: Bool?
    package let authStatus: ACPAuthStatus?
    package let currentModel: String?
    package let currentMode: String?
    package let configOptionValues: [String: ACPConfigValue]
    package let nativeSubagentsDisabled: Bool?
    /// Optional so metadata from a Mac that predates session instructions
    /// still decodes. Applying nil keeps the stored value: the column is
    /// write-once, so nil only means the publisher did not know the field.
    package let sessionInstructions: String?
    /// Optional and applied like `sessionInstructions`.
    package let sessionHooks: String?
    package let promptSuggestions: [ACPPromptSuggestion]?
    package let autoRun: Bool
    package let createdAt: Int64
    package let updatedAt: Int64

    package init(_ row: ACPSessionRow) {
        title = row.title
        titleSource = row.titleSource
        origin = row.origin
        contextRecoveryPending = row.contextRecoveryPending
        mcpPreamblePending = row.mcpPreamblePending
        mcpPreambleSent = row.mcpPreambleSent
        usageLimit = row.usageLimit
        directTurnInFlight = row.directTurnInFlight
        authStatus = row.authStatus
        currentModel = row.currentModel
        currentMode = row.currentMode
        configOptionValues = row.configOptionValues
        nativeSubagentsDisabled = row.nativeSubagentsDisabled
        sessionInstructions = row.sessionInstructions
        sessionHooks = row.sessionHooks
        promptSuggestions = row.promptSuggestions
        autoRun = row.autoRun
        createdAt = row.createdAt
        updatedAt = row.updatedAt
    }
}

package struct ReplicaReference: Codable {
    package let recordId: String?
    package let agentId: String
    package let remoteSessionId: String?

    public init(recordId: String?, agentId: String, remoteSessionId: String?) {
        self.recordId = recordId
        self.agentId = agentId
        self.remoteSessionId = remoteSessionId
    }
}
package struct ReplicaMessage: Codable {
    package let kind: String
    package let seq: Int64
    package let payload: Data
    package let createdAt: Int64
    package let subagentSessionId: String?
    package let delegatedReference: ReplicaReference?

    public init(kind: String, seq: Int64, payload: Data, createdAt: Int64, subagentSessionId: String?, delegatedReference: ReplicaReference?) {
        self.kind = kind
        self.seq = seq
        self.payload = payload
        self.createdAt = createdAt
        self.subagentSessionId = subagentSessionId
        self.delegatedReference = delegatedReference
    }
}
package struct ReplicaQueue: Codable {
    package let payload: Data
    package let delegatedReferences: [String: ReplicaReference]

    public init(payload: Data, delegatedReferences: [String: ReplicaReference]) {
        self.payload = payload
        self.delegatedReferences = delegatedReferences
    }
}
package struct ReplicaFork: Codable {
    package let source: ReplicaReference
    package let sourceBoundarySequence: Int64
    package let inheritedMessageCount: Int
    package let phase: ACPSessionForkCreationPhase
    package let mechanism: ACPSessionForkMechanism?
    package let contextDeliveryPending: Bool
    package let via: String?
    package let forkPoint: ACPSessionForkPoint?
    package let nativeRemoteHistoryStart: Int?

    public init(source: ReplicaReference, sourceBoundarySequence: Int64, inheritedMessageCount: Int, phase: ACPSessionForkCreationPhase, mechanism: ACPSessionForkMechanism?, contextDeliveryPending: Bool, via: String?, forkPoint: ACPSessionForkPoint? = nil, nativeRemoteHistoryStart: Int? = nil) {
        self.source = source
        self.sourceBoundarySequence = sourceBoundarySequence
        self.inheritedMessageCount = inheritedMessageCount
        self.phase = phase
        self.mechanism = mechanism
        self.contextDeliveryPending = contextDeliveryPending
        self.via = via
        self.forkPoint = forkPoint
        self.nativeRemoteHistoryStart = nativeRemoteHistoryStart
    }

    private enum CodingKeys: String, CodingKey {
        case source, sourceBoundarySequence, inheritedMessageCount, phase, mechanism, contextDeliveryPending, via
        case forkPoint, nativeRemoteHistoryStart
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(ReplicaReference.self, forKey: .source)
        sourceBoundarySequence = try c.decode(Int64.self, forKey: .sourceBoundarySequence)
        inheritedMessageCount = try c.decode(Int.self, forKey: .inheritedMessageCount)
        phase = try c.decode(ACPSessionForkCreationPhase.self, forKey: .phase)
        mechanism = try c.decodeIfPresent(ACPSessionForkMechanism.self, forKey: .mechanism)
        contextDeliveryPending = try c.decode(Bool.self, forKey: .contextDeliveryPending)
        via = try c.decodeIfPresent(String.self, forKey: .via)
        // A fork point a newer build wrote (an outcome or boundary this build
        // doesn't know) drops; the rest of the fork still imports.
        forkPoint = try? c.decodeIfPresent(ACPSessionForkPoint.self, forKey: .forkPoint)
        nativeRemoteHistoryStart = try c.decodeIfPresent(Int.self, forKey: .nativeRemoteHistoryStart)
    }
}

public enum ACPSessionReplicaError: Error, Sendable {
    case localWriterActive, invalidPage, missingSession, invalidReference
}
