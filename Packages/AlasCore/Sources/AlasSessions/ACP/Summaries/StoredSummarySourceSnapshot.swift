import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

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
