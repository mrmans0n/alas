import Foundation

struct AttentionWorktreeIdentity: Codable, Hashable, Sendable {
    enum Location: Codable, Hashable, Sendable {
        case local
        case ssh(String)
    }

    let projectID: String
    let location: Location
    let lineageID: String?
    let legacyPath: String?
}

extension AttentionWorktreeIdentity {
    var storageKey: String {
        [projectID, String(describing: location), lineageID ?? legacyPath ?? "missing"].joined(separator: ":")
    }
}

struct AttentionWorktreeDisplaySnapshot: Codable, Equatable, Sendable {
    let projectName: String
    let branch: String
    let path: String
    let host: String?
}

struct AttentionSourceKey: Codable, Hashable, Sendable {
    let rawValue: String
}

enum AttentionKind: String, Codable, Sendable {
    case agentAwaiting, agentPermission, runScriptFailure, gitOperation
    case conflicts, reviewReply, failedChecks, actionableFeedback
    case reviewSyncBlocked, hostDisconnected, agentFinished
}

extension AttentionKind {
    func historicalTitle(from title: String) -> String {
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
        case .reviewReply, .failedChecks, .agentFinished:
            title
        }
    }
}

enum AttentionJumpTarget: Codable, Equatable, Sendable {
    case session(sessionID: String)
    case runScriptFailure(failureID: String)
    case conflicts(path: String?)
    case gitOperation
    case reviewRequest(number: Int?)
    case reviewComment(sessionID: String, commentID: String)
    case remoteWorktree
    case none
}

struct AttentionSignal: Codable, Equatable, Sendable {
    let sourceKey: AttentionSourceKey
    let fingerprint: String
    let owner: AttentionWorktreeIdentity
    let kind: AttentionKind
    let title: String
    let body: String?
    let jumpTarget: AttentionJumpTarget
    let display: AttentionWorktreeDisplaySnapshot
}

struct AttentionHistoryEvent: Codable, Equatable, Sendable {
    let sourceKey: AttentionSourceKey
    let fingerprint: String
    let owner: AttentionWorktreeIdentity
    let kind: AttentionKind
    let title: String
    let body: String?
    let jumpTarget: AttentionJumpTarget
    let display: AttentionWorktreeDisplaySnapshot
    let requiresAction: Bool

    init(
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

struct AttentionEvent: Codable, Equatable, Sendable {
    let id: UUID
    let sourceKey: AttentionSourceKey
    let fingerprint: String
    let owner: AttentionWorktreeIdentity
    let kind: AttentionKind
    let title: String
    let body: String?
    let jumpTarget: AttentionJumpTarget
    let display: AttentionWorktreeDisplaySnapshot
    let occurredAt: Date
    let requiresAction: Bool

    init(id: UUID = UUID(), signal: AttentionSignal, occurredAt: Date) {
        self.id = id
        sourceKey = signal.sourceKey
        fingerprint = signal.fingerprint
        owner = signal.owner
        kind = signal.kind
        title = signal.title
        body = signal.body
        jumpTarget = signal.jumpTarget
        display = signal.display
        self.occurredAt = occurredAt
        requiresAction = true
    }

    init(id: UUID = UUID(), history: AttentionHistoryEvent, occurredAt: Date) {
        self.id = id
        sourceKey = history.sourceKey
        fingerprint = history.fingerprint
        owner = history.owner
        kind = history.kind
        title = history.title
        body = history.body
        jumpTarget = history.jumpTarget
        display = history.display
        self.occurredAt = occurredAt
        requiresAction = history.requiresAction
    }
}

struct AttentionAcknowledgment: Codable, Equatable, Sendable {
    let eventID: UUID
    let acknowledgedAt: Date
}

enum AttentionObservation: Sendable {
    case active(AttentionSignal)
    case inactive(sourceKey: AttentionSourceKey)
}

extension AttentionObservation {
    var activeSignal: AttentionSignal? {
        guard case .active(let signal) = self else { return nil }
        return signal
    }
}

struct AttentionStoredObservation: Codable, Equatable, Sendable {
    let isActive: Bool
    let fingerprint: String?
    let eventID: UUID?
}

struct AttentionDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var events: [AttentionEvent]
    var acknowledgments: [UUID: AttentionAcknowledgment]
    var observations: [AttentionSourceKey: AttentionStoredObservation]
    var aliases: [AttentionWorktreeIdentity: AttentionWorktreeIdentity]

    init(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        events = try container.decodeIfPresent([AttentionEvent].self, forKey: .events) ?? []
        acknowledgments = try container.decodeIfPresent([UUID: AttentionAcknowledgment].self, forKey: .acknowledgments) ?? [:]
        observations = try container.decodeIfPresent([AttentionSourceKey: AttentionStoredObservation].self, forKey: .observations) ?? [:]
        aliases = try container.decodeIfPresent([AttentionWorktreeIdentity: AttentionWorktreeIdentity].self, forKey: .aliases) ?? [:]
    }
}
