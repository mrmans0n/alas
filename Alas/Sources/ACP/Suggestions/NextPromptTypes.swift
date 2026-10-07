import Foundation
import os

/// Stream with `log stream --level debug --predicate 'category == "next-prompt"'`.
let nextPromptLogger = Logger(subsystem: "io.nlopez.alas", category: "next-prompt")

struct NextPromptTurn: Equatable, Sendable {
    let user: String
    let assistant: String
}

struct NextPromptCompletedTurn: Equatable, Sendable {
    let sessionID: String
    let incarnation: UUID
    let promptID: Int
    let userMessageID: UUID
    let transcriptRevision: UInt64
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
