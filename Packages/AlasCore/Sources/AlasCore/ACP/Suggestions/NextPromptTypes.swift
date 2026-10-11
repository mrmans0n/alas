import Foundation
import os

/// Stream with `log stream --level debug --predicate 'category == "next-prompt"'`.
public let nextPromptLogger = Logger(subsystem: "io.nlopez.alas", category: "next-prompt")

/// Records why a completed turn cannot be offered yet. Composer updates recheck
/// eligibility constantly, so only a changed reason reaches the persisted log.
@MainActor
public enum NextPromptIneligibility: Sendable {
    private static var last: (incarnation: UUID, promptID: Int, reason: String)?

    public static func log(_ turn: NextPromptCompletedTurn, _ reason: String) {
        if let last, last.incarnation == turn.incarnation, last.promptID == turn.promptID,
           last.reason == reason { return }
        last = (turn.incarnation, turn.promptID, reason)
        nextPromptLogger.notice("prompt \(turn.promptID) ineligible: \(reason, privacy: .public)")
    }
}

public struct NextPromptTurn: Equatable, Sendable {
    public let user: String
    public let assistant: String

    public init(user: String, assistant: String) {
        self.user = user
        self.assistant = assistant
    }
}

public struct NextPromptCompletedTurn: Equatable, Sendable {
    public let sessionID: String
    public let incarnation: UUID
    public let promptID: Int
    public let userMessageID: UUID
    public let transcriptRevision: UInt64

    public init(sessionID: String, incarnation: UUID, promptID: Int, userMessageID: UUID, transcriptRevision: UInt64) {
        self.sessionID = sessionID
        self.incarnation = incarnation
        self.promptID = promptID
        self.userMessageID = userMessageID
        self.transcriptRevision = transcriptRevision
    }
}

public struct NextPromptRequestID: Equatable, Sendable {
    public let sessionID: String
    public let incarnation: UUID
    public let promptID: Int
    public let transcriptRevision: UInt64
    public let draftRevision: Int
    public let composerEpoch: UInt64
    public let settingsGeneration: UInt64
    public let modelGeneration: UInt64

    public init(sessionID: String, incarnation: UUID, promptID: Int, transcriptRevision: UInt64, draftRevision: Int, composerEpoch: UInt64, settingsGeneration: UInt64, modelGeneration: UInt64) {
        self.sessionID = sessionID
        self.incarnation = incarnation
        self.promptID = promptID
        self.transcriptRevision = transcriptRevision
        self.draftRevision = draftRevision
        self.composerEpoch = composerEpoch
        self.settingsGeneration = settingsGeneration
        self.modelGeneration = modelGeneration
    }
}

public struct NextPromptRequest: Sendable {
    public let id: NextPromptRequestID
    public let turns: [NextPromptTurn]

    public init(id: NextPromptRequestID, turns: [NextPromptTurn]) {
        self.id = id
        self.turns = turns
    }
}
