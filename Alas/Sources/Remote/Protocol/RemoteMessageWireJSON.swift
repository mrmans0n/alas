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

struct RemoteSessionSummary: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let agentId: String
    let status: String        // "idle" | "streaming" | "awaitingPermission"
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
