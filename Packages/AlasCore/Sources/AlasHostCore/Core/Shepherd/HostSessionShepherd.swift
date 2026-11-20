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
    /// What the Mac's shepherd popover shows beyond the pill; nil from hosts
    /// before it was sent.
    public var detail: Detail?

    public init(
        badge: String, number: String?, tooltip: String, resumable: Bool? = nil,
        phaseLine: String? = nil, autoFix: Bool? = nil, autoMerge: Bool? = nil, detail: Detail? = nil
    ) {
        self.badge = badge
        self.number = number
        self.tooltip = tooltip
        self.resumable = resumable
        self.phaseLine = phaseLine
        self.autoFix = autoFix
        self.autoMerge = autoMerge
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case badge, number, tooltip, resumable, phaseLine, autoFix, autoMerge, detail
    }

    /// A `detail` this Mac can't read is dropped rather than losing the shepherd.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        badge = try c.decode(String.self, forKey: .badge)
        number = try c.decodeIfPresent(String.self, forKey: .number)
        tooltip = try c.decode(String.self, forKey: .tooltip)
        resumable = try c.decodeIfPresent(Bool.self, forKey: .resumable)
        phaseLine = try c.decodeIfPresent(String.self, forKey: .phaseLine)
        autoFix = try c.decodeIfPresent(Bool.self, forKey: .autoFix)
        autoMerge = try c.decodeIfPresent(Bool.self, forKey: .autoMerge)
        detail = (try? c.decodeIfPresent(Detail.self, forKey: .detail)) ?? nil
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
            var shepherd = HostSessionShepherd(stackPresentation(stackRecord, stack), resumable: stackRecord.phase.isResumable)
            shepherd.detail = stackDetail(stackRecord, stack)
            return shepherd
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
            shepherd.detail = reviewDetail(record, request: request)
            return shepherd
        }
        return stackRecord.map {
            var shepherd = HostSessionShepherd(stackPresentation($0, stack), resumable: false)
            shepherd.detail = stackDetail($0, stack)
            return shepherd
        }
    }

    private static func reviewDetail(_ record: ShepherdRecord, request: ReviewRequest?) -> Detail {
        let kind = record.id.providerKind
        let openThreads = request?.threads.filter(\.isActionable)
        return Detail(
            title: request?.title,
            url: request?.url ?? record.remote.reviewRequestURL(number: record.id.requestNumber),
            branch: "\(record.branch) → \(record.baseBranch)",
            headSHA: (request?.headSHA ?? record.lastSeenHeadSHA).map { String($0.prefix(7)) },
            provider: kind.displayName,
            requestLabel: kind.reviewRequestLabel,
            checks: request?.checks.map { Check(name: $0.name, bucket: $0.bucket.rawValue, url: $0.detailURL) },
            openThreads: openThreads?.count,
            trustedThreads: openThreads?.filter { $0.headAuthorTrust == .trusted }.count,
            fixAttempts: record.fixAttempts,
            fixAttemptBudget: record.fixAttemptBudget
        )
    }

    @MainActor
    private static func stackDetail(_ record: StackShepherdRecord, _ stack: StackShepherd) -> Detail {
        let kind = record.remote.kind
        let requests = stack.requests[record.id] ?? [:]
        let gatePasses = stack.gatePasses[record.id] ?? false
        let entries = StackShepherdPolicy.statusEntries(of: record, stack: nil, now: Date())
            .compactMap { entry -> StackEntry? in
                guard let number = entry.requestNumber, let shepherd = entry.shepherd else { return nil }
                let request = requests[number]
                let presentation = ShepherdPresentation.make(
                    record: shepherd, request: request, mergeGatePasses: gatePasses && !shepherd.phase.isTerminal
                )
                return StackEntry(
                    position: entry.position, number: "\(kind.reviewRequestNumberPrefix)\(number)", title: entry.title,
                    badge: presentation.badge.rawValue, phaseLine: presentation.phaseLine,
                    url: request?.url ?? record.remote.reviewRequestURL(number: number)
                )
            }
        return Detail(
            title: nil, url: nil, branch: record.id.stackName, headSHA: nil,
            provider: kind.displayName, requestLabel: kind.reviewRequestLabel,
            checks: nil, openThreads: nil, trustedThreads: nil,
            fixAttempts: record.fixAttempts, fixAttemptBudget: record.fixAttemptBudget,
            stackEntries: entries.sorted { $0.position > $1.position }
        )
    }

    @MainActor
    private static func stackPresentation(_ record: StackShepherdRecord, _ stack: StackShepherd) -> ShepherdPresentation {
        ShepherdPresentation.make(
            stack: record, requests: stack.requests[record.id] ?? [:], gatePasses: stack.gatePasses[record.id] ?? false
        )
    }
}

extension HostSessionShepherd {
    /// The request's header, checks and threads, or a stack's entries.
    public struct Detail: Codable, Equatable, Sendable {
        /// The request title; nil without a snapshot of this request.
        public var title: String?
        public var url: URL?
        /// "feature → main" for a request; the stack name for a stack.
        public var branch: String?
        /// 7 characters.
        public var headSHA: String?
        public var provider: String
        public var requestLabel: String
        /// Nil until a snapshot of this request exists; empty when it has no checks.
        public var checks: [Check]?
        public var openThreads: Int?
        public var trustedThreads: Int?
        public var fixAttempts: Int
        public var fixAttemptBudget: Int
        /// Stacks only, highest position first.
        public var stackEntries: [StackEntry]?

        public init(
            title: String? = nil, url: URL? = nil, branch: String? = nil, headSHA: String? = nil,
            provider: String, requestLabel: String, checks: [Check]? = nil, openThreads: Int? = nil,
            trustedThreads: Int? = nil, fixAttempts: Int, fixAttemptBudget: Int, stackEntries: [StackEntry]? = nil
        ) {
            self.title = title
            self.url = url
            self.branch = branch
            self.headSHA = headSHA
            self.provider = provider
            self.requestLabel = requestLabel
            self.checks = checks
            self.openThreads = openThreads
            self.trustedThreads = trustedThreads
            self.fixAttempts = fixAttempts
            self.fixAttemptBudget = fixAttemptBudget
            self.stackEntries = stackEntries
        }
    }

    public struct Check: Codable, Equatable, Sendable {
        public var name: String
        /// A `ReviewCheckBucket` raw value.
        public var bucket: String
        public var url: URL?

        public init(name: String, bucket: String, url: URL? = nil) {
            self.name = name
            self.bucket = bucket
            self.url = url
        }
    }

    public struct StackEntry: Codable, Equatable, Sendable {
        public var position: Int
        public var number: String
        public var title: String
        /// A `ShepherdBadgeState` raw value.
        public var badge: String
        public var phaseLine: String
        public var url: URL?

        public init(position: Int, number: String, title: String, badge: String, phaseLine: String, url: URL? = nil) {
            self.position = position
            self.number = number
            self.title = title
            self.badge = badge
            self.phaseLine = phaseLine
            self.url = url
        }
    }
}
