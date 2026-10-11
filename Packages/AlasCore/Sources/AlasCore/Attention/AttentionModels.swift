import Foundation

public struct AttentionWorktreeIdentity: Codable, Hashable, Sendable {
    public enum Location: Codable, Hashable, Sendable {
        case local
        case ssh(String)
    }

    public let projectID: String
    public let location: Location
    public let lineageID: String?
    public let legacyPath: String?

    public init(projectID: String, location: Location, lineageID: String?, legacyPath: String?) {
        self.projectID = projectID
        self.location = location
        self.lineageID = lineageID
        self.legacyPath = legacyPath
    }
}

extension AttentionWorktreeIdentity {
    public var storageKey: String {
        [projectID, String(describing: location), lineageID ?? legacyPath ?? "missing"].joined(separator: ":")
    }
}

public struct AttentionWorktreeDisplaySnapshot: Codable, Equatable, Sendable {
    public let projectName: String
    public let branch: String
    public let path: String
    public let host: String?

    public init(projectName: String, branch: String, path: String, host: String?) {
        self.projectName = projectName
        self.branch = branch
        self.path = path
        self.host = host
    }
}

public struct AttentionSourceKey: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum AttentionKind: String, Codable, Sendable {
    case agentAwaiting, agentPermission, runScriptFailure, gitOperation
    case conflicts, reviewReply, failedChecks, actionableFeedback
    case reviewSyncBlocked, hostDisconnected, agentFinished, agentReady
    case agentLimited, agentFailed
}

extension AttentionKind {
    /// A condition can be worth recording without requiring the user's intervention.
    public var requiresAction: Bool {
        switch self {
        case .agentAwaiting, .agentPermission, .runScriptFailure, .conflicts, .hostDisconnected, .agentFailed:
            true
        case .agentReady, .gitOperation, .reviewReply, .failedChecks, .actionableFeedback,
             .reviewSyncBlocked, .agentFinished, .agentLimited:
            false
        }
    }

    public func historicalTitle(from title: String) -> String {
        switch self {
        case .agentAwaiting:
            title.replacingOccurrences(of: " is waiting for input", with: " waited for input")
        case .agentPermission:
            title.replacingOccurrences(of: " needs permission", with: " needed permission")
        case .runScriptFailure:
            title.replacingOccurrences(of: " failed", with: " failed")
        case .gitOperation:
            title.replacingOccurrences(of: " is in progress", with: " was in progress")
        case .hostDisconnected:
            title.replacingOccurrences(of: " is unreachable", with: " was unreachable")
        case .conflicts:
            title
                .replacingOccurrences(of: " unresolved conflicts", with: " conflicts required resolution")
                .replacingOccurrences(of: " unresolved conflict", with: " conflict required resolution")
        case .actionableFeedback:
            title.replacingOccurrences(of: " needs action", with: " required action")
        case .reviewSyncBlocked:
            title.replacingOccurrences(of: " is ahead", with: " was ahead")
        case .reviewReply, .failedChecks, .agentFinished, .agentReady, .agentLimited, .agentFailed:
            title
        }
    }
}

public enum AttentionJumpTarget: Codable, Equatable, Sendable {
    case session(sessionID: String)
    case runScriptFailure(failureID: String)
    case conflicts(path: String?)
    case gitOperation
    case reviewRequest(number: Int?)
    case reviewComment(sessionID: String, commentID: String)
    case remoteWorktree
    case none
}

public struct AttentionSignal: Codable, Equatable, Sendable {
    public let sourceKey: AttentionSourceKey
    public let fingerprint: String
    public let owner: AttentionWorktreeIdentity
    public let kind: AttentionKind
    public let title: String
    public let body: String?
    public let jumpTarget: AttentionJumpTarget
    public let display: AttentionWorktreeDisplaySnapshot

    public init(sourceKey: AttentionSourceKey, fingerprint: String, owner: AttentionWorktreeIdentity, kind: AttentionKind, title: String, body: String?, jumpTarget: AttentionJumpTarget, display: AttentionWorktreeDisplaySnapshot) {
        self.sourceKey = sourceKey
        self.fingerprint = fingerprint
        self.owner = owner
        self.kind = kind
        self.title = title
        self.body = body
        self.jumpTarget = jumpTarget
        self.display = display
    }
}

public struct AttentionHistoryEvent: Codable, Equatable, Sendable {
    public let sourceKey: AttentionSourceKey
    public let fingerprint: String
    public let owner: AttentionWorktreeIdentity
    public let kind: AttentionKind
    public let title: String
    public let body: String?
    public let jumpTarget: AttentionJumpTarget
    public let display: AttentionWorktreeDisplaySnapshot
    public let requiresAction: Bool

    public init(
        sourceKey: AttentionSourceKey,
        fingerprint: String,
        owner: AttentionWorktreeIdentity,
        kind: AttentionKind,
        title: String,
        body: String?,
        jumpTarget: AttentionJumpTarget,
        display: AttentionWorktreeDisplaySnapshot,
        requiresAction: Bool = false
    ) {
        self.sourceKey = sourceKey
        self.fingerprint = fingerprint
        self.owner = owner
        self.kind = kind
        self.title = title
        self.body = body
        self.jumpTarget = jumpTarget
        self.display = display
        self.requiresAction = requiresAction
    }
}

public struct AttentionEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceKey: AttentionSourceKey
    public let fingerprint: String
    public let owner: AttentionWorktreeIdentity
    public let kind: AttentionKind
    public let title: String
    public let body: String?
    public let jumpTarget: AttentionJumpTarget
    public let display: AttentionWorktreeDisplaySnapshot
    public let occurredAt: Date
    public let requiresAction: Bool

    public init(id: UUID = UUID(), signal: AttentionSignal, occurredAt: Date) {
        self.id = id
        sourceKey = signal.sourceKey
        fingerprint = signal.fingerprint
        owner = signal.owner
        kind = signal.kind
        title = signal.title
        body = Self.persistedBody(signal.body)
        jumpTarget = signal.jumpTarget
        display = signal.display
        self.occurredAt = occurredAt
        requiresAction = signal.kind.requiresAction
    }

    public init(id: UUID = UUID(), history: AttentionHistoryEvent, occurredAt: Date) {
        self.id = id
        sourceKey = history.sourceKey
        fingerprint = history.fingerprint
        owner = history.owner
        kind = history.kind
        title = history.title
        body = Self.persistedBody(history.body)
        jumpTarget = history.jumpTarget
        display = history.display
        self.occurredAt = occurredAt
        requiresAction = history.requiresAction
    }

    public init(
        id: UUID,
        sourceKey: AttentionSourceKey,
        fingerprint: String,
        owner: AttentionWorktreeIdentity,
        kind: AttentionKind,
        title: String,
        body: String?,
        jumpTarget: AttentionJumpTarget,
        display: AttentionWorktreeDisplaySnapshot,
        occurredAt: Date,
        requiresAction: Bool
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.fingerprint = fingerprint
        self.owner = owner
        self.kind = kind
        self.title = title
        self.body = Self.persistedBody(body)
        self.jumpTarget = jumpTarget
        self.display = display
        self.occurredAt = occurredAt
        self.requiresAction = requiresAction
    }

    private static func persistedBody(_ body: String?) -> String? {
        guard let body else { return nil }
        let cappedBytes = body.utf8.prefix(8_192)
        let isTruncated = body.utf8.count > cappedBytes.count
        let preview = String(decoding: cappedBytes, as: UTF8.self)
        return isTruncated ? "\(preview)\n\n[Output truncated]" : preview
    }
}

public struct AttentionAcknowledgment: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let acknowledgedAt: Date

    public init(eventID: UUID, acknowledgedAt: Date) {
        self.eventID = eventID
        self.acknowledgedAt = acknowledgedAt
    }
}

public enum AttentionObservation: Sendable {
    case active(AttentionSignal)
    case inactive(sourceKey: AttentionSourceKey)
}

extension AttentionObservation {
    public var activeSignal: AttentionSignal? {
        guard case .active(let signal) = self else { return nil }
        return signal
    }
}

public struct AttentionStoredObservation: Codable, Equatable, Sendable {
    public let isActive: Bool
    public let fingerprint: String?
    public let eventID: UUID?

    public init(isActive: Bool, fingerprint: String?, eventID: UUID?) {
        self.isActive = isActive
        self.fingerprint = fingerprint
        self.eventID = eventID
    }
}

public struct AttentionDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var events: [AttentionEvent]
    public var acknowledgments: [UUID: AttentionAcknowledgment]
    public var observations: [AttentionSourceKey: AttentionStoredObservation]
    public var aliases: [AttentionWorktreeIdentity: AttentionWorktreeIdentity]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        events: [AttentionEvent] = [],
        acknowledgments: [UUID: AttentionAcknowledgment] = [:],
        observations: [AttentionSourceKey: AttentionStoredObservation] = [:],
        aliases: [AttentionWorktreeIdentity: AttentionWorktreeIdentity] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.events = events
        self.acknowledgments = acknowledgments
        self.observations = observations
        self.aliases = aliases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        events = try container.decodeIfPresent([AttentionEvent].self, forKey: .events) ?? []
        acknowledgments = try container.decodeIfPresent([UUID: AttentionAcknowledgment].self, forKey: .acknowledgments) ?? [:]
        observations = try container.decodeIfPresent([AttentionSourceKey: AttentionStoredObservation].self, forKey: .observations) ?? [:]
        aliases = try container.decodeIfPresent([AttentionWorktreeIdentity: AttentionWorktreeIdentity].self, forKey: .aliases) ?? [:]
    }
}
