import Foundation
import os

/// Stream with `log stream --level debug --predicate 'category == "next-prompt"'`.
let nextPromptLogger = Logger(subsystem: "io.nlopez.alas", category: "next-prompt")

/// Records why a completed turn cannot be offered yet. Composer updates recheck
/// eligibility constantly, so only a changed reason reaches the persisted log.
@MainActor
enum NextPromptIneligibility {
    private static var last: (incarnation: UUID, promptID: Int, reason: String)?

    static func log(_ turn: NextPromptCompletedTurn, _ reason: String) {
        if let last, last.incarnation == turn.incarnation, last.promptID == turn.promptID,
           last.reason == reason { return }
        last = (turn.incarnation, turn.promptID, reason)
        nextPromptLogger.notice("prompt \(turn.promptID) ineligible: \(reason, privacy: .public)")
    }
}

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
