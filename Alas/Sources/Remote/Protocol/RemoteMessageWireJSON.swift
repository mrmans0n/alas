import Foundation

/// One transcript message as sent to the web client. `text` carries the
/// human-visible body for simple kinds; `json` carries a structured blob
/// for tool calls / file edits / plans the web client renders specially.
struct RemoteWireMessage: Codable, Equatable, Sendable {
    let stableId: String
    let kind: String          // "user" | "agent" | "thought" | "toolCall" | "fileEdit" | "plan" | "systemNotice"
    let text: String?
    let json: String?         // JSON string for structured kinds; nil otherwise
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

struct RemoteSessionSummary: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let agentId: String
    let status: String       // "idle" | "streaming" | "awaitingPermission" | "awaitingInput"
    let canDrive: Bool       // this remote-host instance currently holds the writer lease
    let worktree: RemoteWorktreeSummary?

    init(
        id: String,
        title: String,
        agentId: String,
        status: String,
        canDrive: Bool,
        worktree: RemoteWorktreeSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.agentId = agentId
        self.status = status
        self.canDrive = canDrive
        self.worktree = worktree
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
