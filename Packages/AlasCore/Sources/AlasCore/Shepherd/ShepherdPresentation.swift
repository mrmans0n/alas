import Foundation

/// The toolbar pill's state, shared with the Changes drawer and the popover.
/// The app maps each case to an SF Symbol and a theme color.
public enum ShepherdBadgeState: Equatable, Sendable {
    /// No record and no request: the pill offers Ship with agent.
    case noRequest
    /// A request exists but this session does not shepherd it.
    case unshepherded
    /// Checks running, watching, waiting for a push or on reviewers.
    case waiting
    case fixing
    case ready
    case merging
    case queued
    /// Escalated, paused, or failing with auto-fix off.
    case attention
    case merged
    case closed

    /// The pill runs the AI beam while the shepherd is acting on the request.
    public var isActive: Bool {
        switch self {
        case .fixing, .merging: true
        default: false
        }
    }
}

public struct ShepherdPresentation: Equatable, Sendable {
    public let badge: ShepherdBadgeState
    /// "#2041" or "!2041"; nil with neither a record nor a request.
    public let number: String?
    /// "#2041 · fixing unit-tests"
    public let tooltip: String
    /// The phase part of the tooltip, without the number.
    public let phaseLine: String

    public init(badge: ShepherdBadgeState, number: String?, tooltip: String, phaseLine: String) {
        self.badge = badge
        self.number = number
        self.tooltip = tooltip
        self.phaseLine = phaseLine
    }

    /// `mergeGatePasses` should come from `ShepherdPolicy.mergeGatePasses`
    /// so the badge agrees with what the policy would do.
    public static func make(record: ShepherdRecord?, request: ReviewRequest?, mergeGatePasses: Bool) -> ShepherdPresentation {
        guard let record else {
            let line = "not shepherded"
            guard let request else {
                return ShepherdPresentation(badge: .noRequest, number: nil, tooltip: "Ship with agent", phaseLine: line)
            }
            let number = "\(request.provider.reviewRequestNumberPrefix)\(request.number)"
            return ShepherdPresentation(badge: .unshepherded, number: number, tooltip: "\(number) · \(line)", phaseLine: line)
        }
        let (badge, line) = state(record: record, request: request, mergeGatePasses: mergeGatePasses)
        let number = "\(record.id.providerKind.reviewRequestNumberPrefix)\(record.id.requestNumber)"
        return ShepherdPresentation(badge: badge, number: number, tooltip: "\(number) · \(line)", phaseLine: line)
    }

    private static func state(
        record: ShepherdRecord,
        request: ReviewRequest?,
        mergeGatePasses: Bool
    ) -> (ShepherdBadgeState, String) {
        switch record.phase {
        case .merged: return (.merged, "merged")
        case .closed: return (.closed, "closed")
        case .escalated(let reason): return (.attention, "needs attention: \(text(for: reason))")
        case .paused: return (.attention, "paused: provider sign-in failed")
        case .fixing: return (.fixing, fixingLine(record: record, request: request))
        case .awaitingPush: return (.waiting, "waiting for a push")
        case .merging: return (.merging, "merging")
        case .queued: return (.queued, "in merge queue")
        case .watching: break
        }
        if mergeGatePasses { return (.ready, "ready to merge") }
        guard let request else { return (.waiting, "watching") }
        if request.checks.contains(where: { $0.bucket == .pending }) { return (.waiting, "checks running") }
        let problems = ShepherdPolicy.problems(in: request, handled: record.handledThreadRevisions ?? [])
        guard !problems.isEmpty else { return (.waiting, "watching") }
        let what = summary(
            hasConflict: problems.hasConflict,
            checkNames: problems.failingChecks.map(\.name),
            threadCount: problems.threads.count
        )
        return record.autoFix ? (.waiting, "needs a fix: \(what)") : (.attention, "auto-fix off: \(what)")
    }

    private static func fixingLine(record: ShepherdRecord, request: ReviewRequest?) -> String {
        guard let fingerprint = record.lastDispatchedFingerprint else { return "fixing" }
        let names = fingerprint.failingCheckIDs.map { id in
            request?.checks.first(where: { $0.id == id })?.name ?? id
        }
        let what = summary(
            hasConflict: fingerprint.hasConflict,
            checkNames: names,
            threadCount: fingerprint.threadIDs.count
        )
        return what.isEmpty ? "fixing" : "fixing \(what)"
    }

    private static func summary(hasConflict: Bool, checkNames: [String], threadCount: Int) -> String {
        var parts: [String] = []
        if hasConflict { parts.append("merge conflict") }
        parts += checkNames
        if threadCount > 0 { parts.append(threadCount == 1 ? "1 review thread" : "\(threadCount) review threads") }
        return parts.joined(separator: ", ")
    }

    private static func text(for escalation: ShepherdEscalation) -> String {
        switch escalation {
        case .attemptsExhausted: "fix attempts used up"
        case .noProgress: "no progress after a fix turn"
        case .deliveryFailed: "couldn't reach the session"
        case .ownerGone: "session is gone"
        case .authFailed: "provider sign-in failed"
        }
    }
}

/// The one action the Ship popover offers a session that doesn't shepherd a
/// request yet, shared with the `/ship` composer command.
public enum ShepherdShipAction: Equatable, Sendable {
    /// This session already shepherds the request ("#7" or "!7").
    case shepherding(number: String)
    /// Bind this open request to the session, taking it over from another
    /// session if one shepherds it.
    case adopt(ReviewRequest)
    /// Ask the session to open a request on this host.
    case create(CodeHostKind)
    /// Ship can't run now; the reason says why.
    case unavailable(String)

    /// `otherRecord` is a live record another session in the worktree owns;
    /// `request` must be that record's request when there is one.
    public static func resolve(
        record: ShepherdRecord?,
        otherRecord: ShepherdRecord?,
        request: ReviewRequest?,
        snapshot: ReviewLoopSnapshot?,
        isBusy: Bool,
        isLoading: Bool = false
    ) -> ShepherdShipAction {
        if let record {
            return .shepherding(number: "\(record.id.providerKind.reviewRequestNumberPrefix)\(record.id.requestNumber)")
        }
        if otherRecord != nil {
            guard let request else { return .unavailable("Waiting for the PR status") }
            return .adopt(request)
        }
        if let request, request.state == .open { return .adopt(request) }
        if let reason = createUnavailableReason(isBusy: isBusy, snapshot: snapshot, isLoading: isLoading) {
            return .unavailable(reason)
        }
        // A nil remote has a reason above.
        return snapshot?.remote.map { .create($0.kind) } ?? .unavailable("This branch has no GitHub or GitLab remote.")
    }

    /// Why Ship with agent is unavailable, or nil when it can run.
    public static func createUnavailableReason(isBusy: Bool, snapshot: ReviewLoopSnapshot?, isLoading: Bool) -> String? {
        if isBusy { return "Wait for the current turn to finish." }
        guard let snapshot else {
            return isLoading ? "Checking the code host…" : "Couldn't read this branch's code host."
        }
        guard let remote = snapshot.remote else { return "This branch has no GitHub or GitLab remote." }
        let cli = remote.kind == .github ? "gh" : "glab"
        if !snapshot.providerAvailable { return "\(cli) isn't installed. Install it with brew install \(cli)." }
        if !snapshot.providerAuthenticated { return "\(cli) isn't signed in. Run \(cli) auth login." }
        return nil
    }
}
