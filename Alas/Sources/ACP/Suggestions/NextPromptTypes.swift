import Foundation

struct NextPromptTurn: Equatable, Sendable {
    let user: String
    let assistant: String
}

struct NextPromptRequestID: Equatable, Sendable {
    let sessionID: String
    let incarnation: UUID
    let promptID: Int
    let transcriptRevision: UInt64
    let draftRevision: Int
    let composerEpoch: UInt64
    let settingsGeneration: UInt64
    let modelGeneration: UInt64
}

struct NextPromptRequest: Sendable {
    let id: NextPromptRequestID
    let turns: [NextPromptTurn]
}

struct NextPromptChatMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case system
        case user
    }

    let role: Role
    let content: String
}
