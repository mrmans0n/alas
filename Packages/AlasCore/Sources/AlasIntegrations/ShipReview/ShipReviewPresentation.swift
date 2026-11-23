import Foundation

/// The review line under a shepherded ship, with the links it offers.
public struct ShipReviewLine: Equatable, Sendable {
    public enum Tone: String, Sendable {
        case running, clean, findings, stopped
    }

    public let tone: Tone
    public let text: String
    public let actions: [ShipReviewLineAction]

    public init(tone: Tone, text: String, actions: [ShipReviewLineAction]) {
        self.tone = tone
        self.text = text
        self.actions = actions
    }
}

public enum ShipReviewLineAction: String, Equatable, Sendable {
    case openSession, openReview, retry, shipAnyway, sendToSession, allow, reviewNow
}

public enum ShipReviewPresentation {
    /// The line for the record's current head, or nil when there is nothing to say.
    /// `reviewerName` is the reviewer agent's display name ("Codex");
    /// `providerName` the code host's ("GitHub").
    public static func line(_ r: ShipReviewRecord, reviewerName: String, providerName: String) -> ShipReviewLine? {
        guard r.enabled else { return nil }
        switch r.phase {
        case let .reviewing(headSHA, _):
            return ShipReviewLine(tone: .running, text: "\(reviewerName) is reviewing \(short(headSHA))…", actions: [.openSession])
        case let .awaitingFix(headSHA):
            let count = r.currentRound?.openFindingIDs.count ?? 0
            return ShipReviewLine(
                tone: .findings,
                text: "\(reviewerName) review: \(findings(count)) on \(short(headSHA)), sent to this session",
                actions: [.openReview]
            )
        case let .pushing(headSHA):
            return cleanLine(r, headSHA: headSHA, reviewerName: reviewerName)
        case let .stopped(stop):
            return ShipReviewLine(tone: .stopped, text: stopMessage(stop, maxRounds: r.maxRounds), actions: actions(for: stop))
        case .idle:
            if let head = r.unreviewedRemoteHead {
                return ShipReviewLine(tone: .stopped, text: "\(short(head)) reached \(providerName) without a review", actions: [.allow])
            }
            guard let round = r.currentRound else { return nil }
            return cleanLine(r, headSHA: round.headSHA, reviewerName: reviewerName)
        }
    }

    /// The stop's message; `maxRounds` is the record's round cap.
    public static func stopMessage(_ stop: ShipReviewStop, maxRounds: Int) -> String {
        switch stop {
        case let .roundsExhausted(openFindings):
            "\(maxRounds) review rounds spent, \(findings(openFindings)) still open. Nothing was pushed."
        case let .findingsWithAutoFixOff(count):
            "\(findings(count)). Auto-fix is off, so nothing was pushed."
        case let .reviewerFailed(reason):
            "Review didn't finish: \(reason). Nothing was pushed."
        case let .instructionsUnreadable(reason):
            "Couldn't read \(reason). Nothing was pushed."
        case let .noProgress(openFindings):
            "The session ended its turn without a fix, \(findings(openFindings)) still open. Nothing was pushed."
        case let .pushFailed(reason):
            "Push failed: \(reason)"
        }
    }

    private static func actions(for stop: ShipReviewStop) -> [ShipReviewLineAction] {
        switch stop {
        case .roundsExhausted, .noProgress: [.openReview, .shipAnyway]
        case .findingsWithAutoFixOff: [.openReview, .sendToSession]
        case .reviewerFailed, .instructionsUnreadable: [.retry, .shipAnyway]
        case .pushFailed: [.retry]
        }
    }

    /// "reviewed before the push" only for a head whose latest round came back clean.
    private static func cleanLine(_ r: ShipReviewRecord, headSHA: String, reviewerName: String) -> ShipReviewLine? {
        guard let round = r.rounds.last(where: { $0.headSHA == headSHA && $0.reviewedAt != nil }),
              round.isClean,
              r.passedSHAs.contains(headSHA)
        else { return nil }
        return ShipReviewLine(tone: .clean, text: "\(reviewerName) reviewed \(short(headSHA)) before the push", actions: [.openReview])
    }

    private static func findings(_ count: Int) -> String {
        count == 1 ? "1 finding" : "\(count) findings"
    }

    private static func short(_ sha: String) -> String {
        String(sha.prefix(7))
    }
}
