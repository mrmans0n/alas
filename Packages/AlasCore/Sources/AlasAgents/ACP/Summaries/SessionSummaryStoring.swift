import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct StoredSessionSummary: Equatable, Sendable {
    public let inputHash: String
    public let modelID: String
    public let summary: SessionSummary
    public let createdAt: Int64

    public init(inputHash: String, modelID: String, summary: SessionSummary, createdAt: Int64) {
        self.inputHash = inputHash
        self.modelID = modelID
        self.summary = summary
        self.createdAt = createdAt
    }
}

/// Summary input rebuilt from persisted rows, with no live session.
public struct StoredSummarySourceSnapshot: Sendable {
    public let source: SessionSummarySource
    /// Queue empty, no context recovery pending, no direct turn in flight.
    public let isIdle: Bool
    public let lastSeenAt: Int64?
    public let updatedAt: Int64

    public init(source: SessionSummarySource, isIdle: Bool, lastSeenAt: Int64?, updatedAt: Int64) {
        self.source = source
        self.isIdle = isIdle
        self.lastSeenAt = lastSeenAt
        self.updatedAt = updatedAt
    }
}

/// Seam the coordinator uses; `ACPSessionPersistence` conforms.
public protocol SessionSummaryStoring: Sendable {
    func loadSessionSummary(sessionId: String, inputHash: String, modelID: String) async throws -> SessionSummary?
    func saveSessionSummary(sessionId: String, _ stored: StoredSessionSummary) async throws
    func deleteAllSessionSummaries() async throws
}
