import Foundation
import AlasIntegrations

/// A session's shepherd pill as a host session summary carries it. `badge`
/// is a `ShepherdBadgeState` raw value; one this Mac doesn't know shows no pill.
public struct HostSessionShepherd: Codable, Equatable, Sendable {
    public var badge: String
    public var number: String?
    public var tooltip: String
    /// Escalated or paused, so Resume acts; an attention badge alone may be a
    /// failing request with auto-fix off. Nil from hosts before
    /// `host.shepherds.v1`.
    public var resumable: Bool?
    /// A pull request shepherd's drawer state; nil for a stack and from
    /// hosts before `host.shepherds.toggles.v1`.
    public var phaseLine: String?
    public var autoFix: Bool?
    public var autoMerge: Bool?

    public init(
        badge: String, number: String?, tooltip: String, resumable: Bool? = nil,
        phaseLine: String? = nil, autoFix: Bool? = nil, autoMerge: Bool? = nil
    ) {
        self.badge = badge
        self.number = number
        self.tooltip = tooltip
        self.resumable = resumable
        self.phaseLine = phaseLine
        self.autoFix = autoFix
        self.autoMerge = autoMerge
    }

    /// The pill's badge; nil for one this Mac doesn't know, which shows no pill.
    public var badgeState: ShepherdBadgeState? { ShepherdBadgeState(rawValue: badge) }

    public init(_ presentation: ShepherdPresentation, resumable: Bool) {
        self.init(
            badge: presentation.badge.rawValue, number: presentation.number, tooltip: presentation.tooltip,
            resumable: resumable, phaseLine: presentation.phaseLine
        )
    }

    /// The presentation it was made from; nil for a badge this Mac doesn't know.
    public var presentation: ShepherdPresentation? {
        badgeState.map { ShepherdPresentation(badge: $0, number: number, tooltip: tooltip, phaseLine: phaseLine ?? tooltip) }
    }

    /// The session's live stack record, else its PR record, else its finished
    /// stack record. Nil without any: a read-only peer offers no Ship.
    @MainActor
    public static func make(sessionID: String, review: ReviewShepherd, stack: StackShepherd) -> HostSessionShepherd? {
        let stackRecord = stack.record(forSession: sessionID)
        if let stackRecord, !stackRecord.isFinished {
            return HostSessionShepherd(stackPresentation(stackRecord, stack), resumable: stackRecord.phase.isResumable)
        }
        if let record = review.record(forSession: sessionID) {
            // A snapshot of another request on the worktree's branch doesn't describe this record.
            let request = review.snapshots[record.id]?.reviewRequest
                .flatMap { ShepherdRecordID(worktreeID: record.id.worktreeID, request: $0) == record.id ? $0 : nil }
            var shepherd = HostSessionShepherd(ShepherdPresentation.make(
                record: record, request: request, mergeGatePasses: review.gatePasses[record.id] ?? false
            ), resumable: record.phase.isResumable)
            shepherd.autoFix = record.autoFix
            shepherd.autoMerge = record.autoMerge
            return shepherd
        }
        return stackRecord.map { HostSessionShepherd(stackPresentation($0, stack), resumable: false) }
    }

    @MainActor
    private static func stackPresentation(_ record: StackShepherdRecord, _ stack: StackShepherd) -> ShepherdPresentation {
        ShepherdPresentation.make(
            stack: record, requests: stack.requests[record.id] ?? [:], gatePasses: stack.gatePasses[record.id] ?? false
        )
    }
}
