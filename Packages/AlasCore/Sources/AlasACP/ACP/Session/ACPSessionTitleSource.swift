import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ACPSessionTitleSource: String, Codable, Sendable {
    case placeholder
    /// Legacy rows used this source for both prompt fallbacks and provider titles.
    /// Treat them as authoritative until a provider or user explicitly renames them.
    case generated
    case fallback
    case local
    case provider
    case manual
}

public struct ACPGoalState: Equatable, Hashable, Sendable {
    public let objective: String
    public let status: String?
    public let tokenBudget: Int?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let tokensUsed: Int?
    public let timeUsedSeconds: Double?
    public let iterations: Int?
    public let lastReason: String?

    public init(
        objective: String,
        status: String?,
        tokenBudget: Int?,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        tokensUsed: Int? = nil,
        timeUsedSeconds: Double? = nil,
        iterations: Int? = nil,
        lastReason: String? = nil
    ) {
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.iterations = iterations
        self.lastReason = lastReason
    }
}

public struct ACPRetryStatus: Equatable, Sendable {
    public let turnId: String?
    public let detail: String?

    public init(turnId: String?, detail: String?) {
        self.turnId = turnId
        self.detail = detail
    }
}

public enum ACPConnectionRecoveryState: Equatable, Sendable {
    case disconnected
    case waiting(attempt: Int, maxAttempts: Int, retryAt: Date)
    case reconnecting(attempt: Int?, maxAttempts: Int?)
    case exhausted(attempts: Int?)
}

/// A tool call the read-only gate rejected in a `/btw` side session.
/// `messageIndex` is the transcript length when it was blocked, which places
/// it in a turn.
public struct ACPBlockedToolCall: Equatable, Sendable {
    public let title: String
    public let messageIndex: Int

    public init(title: String, messageIndex: Int) {
        self.title = title
        self.messageIndex = messageIndex
    }
}
