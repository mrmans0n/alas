import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct ACPSessionLease: Equatable, Sendable {
    public let sessionId: String
    public let ownerInstance: String
    public let pid: Int64
    public let heartbeatAt: Int64
    public let status: String   // "idle" | "busy"
    public let token: String

    public init(sessionId: String, ownerInstance: String, pid: Int64, heartbeatAt: Int64, status: String, token: String) {
        self.sessionId = sessionId
        self.ownerInstance = ownerInstance
        self.pid = pid
        self.heartbeatAt = heartbeatAt
        self.status = status
        self.token = token
    }
}

public struct ACPSessionLeaseFence: Equatable, Sendable {
    public let sessionId: String
    public let ownerInstance: String
    public let token: String

    public init(sessionId: String, ownerInstance: String, token: String) {
        self.sessionId = sessionId
        self.ownerInstance = ownerInstance
        self.token = token
    }
}

public enum ACPSessionOrigin: String, Codable, Equatable, Sendable {
    case alasCreated
    case agentImported
    case agentForked
}

public struct ACPSessionRow: Equatable, Sendable {
    public let id: String
    public let agentId: String
    public var title: String
    public var titleSource: ACPSessionTitleSource = .placeholder
    public var remoteSessionId: String? = nil
    public var origin: ACPSessionOrigin = .alasCreated
    public var contextRecoveryPending: Bool = false
    /// Local locator for an unbound context-recovery process. Cleared only
    /// when native binding and the durable conversation identity agree.
    public var recoveryProcId: String? = nil
    public var mcpPreamblePending: String? = nil
    public var mcpPreambleSent: Bool = false
    /// Written only by `setGoalDraft`; upserts keep the stored value.
    public var goalDraft: String = ""
    /// Written only by `setUsageLimit`; upserts keep the stored value.
    public var usageLimit: ACPUsageLimit? = nil
    /// Written only by `setDirectTurnInFlight`; upserts keep the stored value.
    public var directTurnInFlight: Bool = false
    public var authStatus: ACPAuthStatus? = nil
    public var currentModel: String?
    public var currentMode: String?
    public var configOptionValues: [String: ACPConfigValue] = [:]
    /// Native-delegation policy captured when Alas created the session.
    /// Written once: later upserts never change a stored value, so every
    /// reconnect or restore applies the policy the session started with.
    /// `nil` for sessions created before the policy existed (allowed).
    public var nativeSubagentsDisabled: Bool? = nil
    /// Session instructions captured when Alas created the session, sent on
    /// every session request (`ACPSessionInstructionsPolicy`). Written once
    /// like `nativeSubagentsDisabled`, so editing the agent's default never
    /// changes a session that already exists. `nil` means none.
    public var sessionInstructions: String? = nil
    /// Claude session hooks captured when Alas created the session, as
    /// normalized JSON (`ACPClaudeSessionHooksPolicy`). Written once, like
    /// `sessionInstructions`. `nil` means none.
    public var sessionHooks: String? = nil
    /// Slash commands and skills the agent advertised, persisted so their
    /// pills and chips survive an app restart and reach mirror sessions
    /// before any attach happens (see `migrate_to_v20`).
    public var promptSuggestions: [ACPPromptSuggestion]? = nil
    /// Parent of a hidden side-question session. Written once at insert:
    /// later upserts keep the stored value, and only
    /// `promoteEphemeralSession` clears it (see `migrate_to_v21`).
    public var ephemeralParentId: String? = nil
    public var ephemeralCleanupPending: Bool = false
    public var autoRun: Bool
    public var helperProcStdoutOffset: Int64? = nil
    public var helperProcStderrOffset: Int64? = nil
    public var acpBrokerId: String? = nil
    /// Original persisted context JSON; unknown/malformed values remain evidence.
    public var acpBrokerWireContextJSON: String? = nil
    public var acpBrokerGeneration: Int64? = nil
    public var acpBrokerAcknowledgedCursor: Int64 = 0
    public let createdAt: Int64
    public var updatedAt: Int64
    public var lastOpenedAt: Int64
    public var archived: Bool

    public init(id: String, agentId: String, title: String, titleSource: ACPSessionTitleSource = .placeholder, remoteSessionId: String? = nil, origin: ACPSessionOrigin = .alasCreated, contextRecoveryPending: Bool = false, recoveryProcId: String? = nil, mcpPreamblePending: String? = nil, mcpPreambleSent: Bool = false, usageLimit: ACPUsageLimit? = nil, goalDraft: String = "", directTurnInFlight: Bool = false, authStatus: ACPAuthStatus? = nil, currentModel: String? = nil, currentMode: String? = nil, configOptionValues: [String: ACPConfigValue] = [:], nativeSubagentsDisabled: Bool? = nil, sessionInstructions: String? = nil, sessionHooks: String? = nil, promptSuggestions: [ACPPromptSuggestion]? = nil, ephemeralParentId: String? = nil, ephemeralCleanupPending: Bool = false, autoRun: Bool, helperProcStdoutOffset: Int64? = nil, helperProcStderrOffset: Int64? = nil, acpBrokerId: String? = nil, acpBrokerGeneration: Int64? = nil, acpBrokerWireContextJSON: String? = nil, acpBrokerAcknowledgedCursor: Int64 = 0, createdAt: Int64, updatedAt: Int64, lastOpenedAt: Int64, archived: Bool) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.titleSource = titleSource
        self.remoteSessionId = remoteSessionId
        self.origin = origin
        self.contextRecoveryPending = contextRecoveryPending
        self.recoveryProcId = recoveryProcId
        self.mcpPreamblePending = mcpPreamblePending
        self.mcpPreambleSent = mcpPreambleSent
        self.usageLimit = usageLimit
        self.goalDraft = goalDraft
        self.directTurnInFlight = directTurnInFlight
        self.authStatus = authStatus
        self.currentModel = currentModel
        self.currentMode = currentMode
        self.configOptionValues = configOptionValues
        self.nativeSubagentsDisabled = nativeSubagentsDisabled
        self.sessionInstructions = sessionInstructions
        self.sessionHooks = sessionHooks
        self.promptSuggestions = promptSuggestions
        self.ephemeralParentId = ephemeralParentId
        self.ephemeralCleanupPending = ephemeralCleanupPending
        self.autoRun = autoRun
        self.helperProcStdoutOffset = helperProcStdoutOffset
        self.helperProcStderrOffset = helperProcStderrOffset
        self.acpBrokerId = acpBrokerId
        self.acpBrokerWireContextJSON = acpBrokerWireContextJSON
        self.acpBrokerGeneration = acpBrokerGeneration
        self.acpBrokerAcknowledgedCursor = acpBrokerAcknowledgedCursor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.archived = archived
    }
}

public struct ACPStoredMessage: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let kind: String
    public let seq: Int64
    public let payload: Data
    public let createdAt: Int64

    public init(id: String, sessionId: String, kind: String, seq: Int64, payload: Data, createdAt: Int64) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.seq = seq
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// One row of a native subagent's transcript. `seq` is the child-local
/// index, so a row is identified by (parent session, child session, seq).
public struct ACPStoredSubagentMessage: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let subagentSessionId: String
    public let kind: String
    public let seq: Int64
    public let payload: Data
    public let createdAt: Int64

    public static func rowId(sessionId: String, subagentSessionId: String, seq: Int64) -> String {
        "sub-\(sessionId)-\(subagentSessionId)-\(seq)"
    }

    public init(id: String, sessionId: String, subagentSessionId: String, kind: String, seq: Int64, payload: Data, createdAt: Int64) {
        self.id = id
        self.sessionId = sessionId
        self.subagentSessionId = subagentSessionId
        self.kind = kind
        self.seq = seq
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// Persistence mirror of `SessionSummary`; keeps that type free of `Codable`.
package struct StoredSummaryJSON: Codable {
    let goal: String?
    let completed: [String]
    let blockers: [String]
    let nextAction: String?
    let isPartial: Bool

    package init(_ summary: SessionSummary) {
        goal = summary.goal
        completed = summary.completed
        blockers = summary.blockers
        nextAction = summary.nextAction
        isPartial = summary.isPartial
    }

    package var summary: SessionSummary {
        SessionSummary(goal: goal, completed: completed, blockers: blockers, nextAction: nextAction, isPartial: isPartial)
    }
}
