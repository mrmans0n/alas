import Foundation

/// One transcript message as sent to the web client. `text` carries the
/// human-visible body for simple kinds; `json` carries a structured blob
/// for tool calls / file edits / plans the web client renders specially.
struct RemoteWireMessage: Codable, Equatable, Sendable {
    let stableId: String
    let kind: String          // "user" | "agent" | "thought" | "toolCall" | "fileEdit" | "plan" | "systemNotice"
    let text: String?
    let json: String?         // JSON string for structured kinds; nil otherwise
    let index: Int            // transcript position; the client orders and windows by this
}

/// One queued prompt as sent to the web client. Deliberately carries an image
/// COUNT, never image bytes or URIs — the web client has no authenticated way
/// to fetch attachment data, and a queued bubble only needs to say "there are
/// images here" to render its placeholder. `resourceCount` mirrors the same
/// idea for `.resourceLink`/`.resource` blocks (file mentions): the browser
/// never receives the underlying URI, only a count to render as a chip.
struct RemoteQueuedPrompt: Codable, Equatable, Sendable {
    let id: String          // QueuedPrompt.id, uuidString
    let text: String        // .text blocks, joined
    let imageCount: Int
    let resourceCount: Int
    let status: String      // "pending" | "sending"
    let lastError: String?
}

struct RemoteWorktreeSummary: Codable, Equatable, Sendable {
    let projectName: String
    let worktreeName: String
    let branch: String
    let path: String
    let metricsAvailable: Bool
    let comparisonRef: String?
    let commitCount: Int
    let changedFileCount: Int
    let addedLines: Int
    let deletedLines: Int
    let conflictCount: Int
}

struct RemoteWorktreeOption: Codable, Equatable, Sendable {
    let id: String
    let projectName: String
    let worktreeName: String
    let branch: String
    let path: String
    let metricsAvailable: Bool
    let comparisonRef: String?
    let commitCount: Int
    let changedFileCount: Int
    let addedLines: Int
    let deletedLines: Int
    let conflictCount: Int
}

struct RemoteAgentOption: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}

enum RemoteCreateSessionResult: Equatable, Sendable {
    case success(RemoteSessionSummary)
    case failure(String)
}

struct RemoteSessionSummary: Equatable, Sendable {
    let id: String
    let title: String
    let agentId: String
    let status: String       // "idle" | "streaming" | "awaitingPermission" | "awaitingInput"
    let canDrive: Bool       // this remote-host instance currently holds the writer lease
    let isActive: Bool       // still backed by an open Alas tab
    let projectId: String?
    let updatedAt: Int64
    let worktree: RemoteWorktreeSummary?

    init(
        id: String,
        title: String,
        agentId: String,
        status: String,
        canDrive: Bool,
        isActive: Bool = true,
        projectId: String? = nil,
        updatedAt: Int64 = 0,
        worktree: RemoteWorktreeSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.agentId = agentId
        self.status = status
        self.canDrive = canDrive
        self.isActive = isActive
        self.projectId = projectId
        self.updatedAt = updatedAt
        self.worktree = worktree
    }
}

extension RemoteSessionSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, agentId, status, canDrive, isActive, projectId, updatedAt, worktree
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            agentId: try c.decode(String.self, forKey: .agentId),
            status: try c.decode(String.self, forKey: .status),
            canDrive: try c.decode(Bool.self, forKey: .canDrive),
            isActive: try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true,
            projectId: try c.decodeIfPresent(String.self, forKey: .projectId),
            updatedAt: try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0,
            worktree: try c.decodeIfPresent(RemoteWorktreeSummary.self, forKey: .worktree)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(agentId, forKey: .agentId)
        try c.encode(status, forKey: .status)
        try c.encode(canDrive, forKey: .canDrive)
        try c.encode(isActive, forKey: .isActive)
        try c.encodeIfPresent(projectId, forKey: .projectId)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(worktree, forKey: .worktree)
    }
}

/// A permission request surfaced to the client.
struct RemotePermissionPayload: Codable, Equatable, Sendable {
    let requestId: Int
    let toolName: String
    let options: [RemotePermissionOption]
}

struct RemotePermissionOption: Codable, Equatable, Sendable {
    let optionId: String
    let name: String
    let kind: String
}

/// A question option as sent to the client.
struct RemoteQuestionOption: Codable, Equatable, Sendable {
    let id: String
    let label: String
}

/// A single question surfaced to the client.
struct RemoteQuestion: Codable, Equatable, Sendable {
    let id: String
    let prompt: String
    let options: [RemoteQuestionOption]
    let allowMultiple: Bool
}

/// A question request (one or more questions) surfaced to the client.
struct RemoteQuestionPayload: Codable, Equatable, Sendable {
    let requestId: Int
    let title: String?
    let questions: [RemoteQuestion]
}

/// The client's answer to one question.
struct RemoteQuestionAnswer: Codable, Equatable, Sendable {
    let questionId: String
    let selectedOptionIds: [String]
}

struct RemoteElicitationOption: Codable, Equatable, Sendable {
    let value: String
    let title: String?
    let description: String?
}

struct RemoteElicitationField: Codable, Equatable, Sendable {
    let key: String
    let type: String
    let title: String
    let description: String?
    let required: Bool
    let minLength: Int?
    let maxLength: Int?
    let minimum: Double?
    let maximum: Double?
    let minItems: Int?
    let maxItems: Int?
    let format: String?
    let pattern: String?
    let options: [RemoteElicitationOption]
    let defaultValue: ACPElicitationValue?
}

struct RemoteElicitationPayload: Codable, Equatable, Sendable {
    let requestId: String
    let title: String?
    let message: String
    let mode: String
    let fields: [RemoteElicitationField]
    let elicitationId: String?
    let url: String?
}
