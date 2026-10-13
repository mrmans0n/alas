import Foundation

/// Badge state shared by the ACP toolbar button and the Changes drawer. The
/// app maps tones to colors (working: warn, ready: add, attention: del,
/// merged: purple, none: no badge).
public enum ShepherdBadgeTone: Equatable, Sendable {
    case none, working, ready, attention, merged
}

public struct ShepherdPresentation: Equatable, Sendable {
    public let tone: ShepherdBadgeTone
    /// "#2041 · fixing unit-tests"
    public let tooltip: String
    /// The phase part of the tooltip, without the number.
    public let phaseLine: String

    public init(tone: ShepherdBadgeTone, tooltip: String, phaseLine: String) {
        self.tone = tone
        self.tooltip = tooltip
        self.phaseLine = phaseLine
    }

    /// `mergeGatePasses` should come from `ShepherdPolicy.mergeGatePasses`
    /// so the badge agrees with what the policy would do.
    public static func make(record: ShepherdRecord?, request: ReviewRequest?, mergeGatePasses: Bool) -> ShepherdPresentation {
        guard let record else {
            let line = "not shepherded"
            let tooltip = request.map { "\($0.provider.reviewRequestNumberPrefix)\($0.number) · \(line)" }
                ?? "Not shepherded"
            return ShepherdPresentation(tone: .none, tooltip: tooltip, phaseLine: line)
        }
        let (tone, line) = state(record: record, request: request, mergeGatePasses: mergeGatePasses)
        let number = "\(record.id.providerKind.reviewRequestNumberPrefix)\(record.id.requestNumber)"
        return ShepherdPresentation(tone: tone, tooltip: "\(number) · \(line)", phaseLine: line)
    }

    private static func state(
        record: ShepherdRecord,
        request: ReviewRequest?,
        mergeGatePasses: Bool
    ) -> (ShepherdBadgeTone, String) {
        switch record.phase {
        case .merged: return (.merged, "merged")
        case .closed: return (.none, "closed")
        case .escalated(let reason): return (.attention, "needs attention: \(text(for: reason))")
        case .paused: return (.attention, "paused: provider sign-in failed")
        case .fixing: return (.working, fixingLine(record: record, request: request))
        case .awaitingPush: return (.working, "waiting for a push")
        case .merging: return (.working, "merging")
        case .queued: return (.working, "in merge queue")
        case .watching: break
        }
        if mergeGatePasses { return (.ready, "ready to merge") }
        guard let request else { return (.working, "watching") }
        if request.checks.contains(where: { $0.bucket == .pending }) { return (.working, "checks running") }
        let problems = ShepherdPolicy.problems(in: request)
        guard !problems.isEmpty else { return (.working, "watching") }
        let what = summary(
            hasConflict: problems.hasConflict,
            checkNames: problems.failingChecks.map(\.name),
            threadCount: problems.threads.count
        )
        return record.autoFix ? (.working, "needs a fix: \(what)") : (.attention, "auto-fix off: \(what)")
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
