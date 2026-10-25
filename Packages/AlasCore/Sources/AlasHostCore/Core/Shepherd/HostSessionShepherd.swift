import Foundation
import AlasIntegrations

/// A session's shepherd pill as a host session summary carries it. `badge`
/// is a `ShepherdBadgeState` raw value; one this Mac doesn't know shows no pill.
public struct HostSessionShepherd: Codable, Equatable, Sendable {
    public var badge: String
    public var number: String?
    public var tooltip: String

    public init(badge: String, number: String?, tooltip: String) {
        self.badge = badge
        self.number = number
        self.tooltip = tooltip
    }

    /// The pill's badge; nil for one this Mac doesn't know, which shows no pill.
    public var badgeState: ShepherdBadgeState? { ShepherdBadgeState(rawValue: badge) }

    public init(_ presentation: ShepherdPresentation) {
        self.init(badge: presentation.badge.rawValue, number: presentation.number, tooltip: presentation.tooltip)
    }

    /// The session's live stack record, else its PR record, else its finished
    /// stack record. Nil without any: a read-only peer offers no Ship.
    @MainActor
    public static func make(sessionID: String, review: ReviewShepherd, stack: StackShepherd) -> HostSessionShepherd? {
        let stackRecord = stack.record(forSession: sessionID)
        if let stackRecord, !stackRecord.isFinished {
            return HostSessionShepherd(stackPresentation(stackRecord, stack))
        }
        if let record = review.record(forSession: sessionID) {
            // A snapshot of another request on the worktree's branch doesn't describe this record.
            let request = review.snapshots[record.id]?.reviewRequest
                .flatMap { ShepherdRecordID(worktreeID: record.id.worktreeID, request: $0) == record.id ? $0 : nil }
            return HostSessionShepherd(ShepherdPresentation.make(
                record: record, request: request, mergeGatePasses: review.gatePasses[record.id] ?? false
            ))
        }
        return stackRecord.map { HostSessionShepherd(stackPresentation($0, stack)) }
    }

    @MainActor
    private static func stackPresentation(_ record: StackShepherdRecord, _ stack: StackShepherd) -> ShepherdPresentation {
        ShepherdPresentation.make(
            stack: record, requests: stack.requests[record.id] ?? [:], gatePasses: stack.gatePasses[record.id] ?? false
        )
    }
}
