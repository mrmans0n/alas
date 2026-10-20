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

/// Seam the coordinator uses; `ACPSessionPersistence` conforms.
public protocol SessionSummaryStoring: Sendable {
    func loadSessionSummary(sessionId: String, inputHash: String, modelID: String) async throws -> SessionSummary?
    func saveSessionSummary(sessionId: String, _ stored: StoredSessionSummary) async throws
    func deleteAllSessionSummaries() async throws
}
