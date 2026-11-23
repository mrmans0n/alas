import SwiftUI

/// The ship review a review session's round belongs to, as the banner shows it.
struct ReviewVerdictShipContext {
    let round: ShipReviewRound
    let maxRounds: Int
    /// "Sent to <owner> session", when this round's findings went to the owner.
    let sentToOwner: String?
    let canShipAnyway: Bool
    let reviewerSessionLive: Bool
}

struct ReviewVerdictBannerActions {
    var reviewAgain: () -> Void = {}
    var shipAnyway: () -> Void = {}
    var openReviewerSession: () -> Void = {}
}

/// Sits under the review pane header for any session with a verdict.
struct ReviewVerdictBanner: View {
    let verdict: ReviewSessionVerdict
    let ship: ReviewVerdictShipContext?
    var actions = ReviewVerdictBannerActions()
    var now: () -> Date = Date.init

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            HStack(spacing: scale.space[2]) {
                chip
                if let ship, !ship.round.reviewerLabel.isEmpty {
                    Text(ship.round.reviewerLabel)
                        .font(scale.meta.font(weight: .medium))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                }
                Text(metaLine)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if !verdict.summary.isEmpty {
                DiffReviewInlineFeedbackMarkdown.view(verdict.summary)
                    .foregroundColor(theme.color("fg"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let ship {
                actionRow(ship)
            }
        }
        .padding(.horizontal, scale.space[4])
        .padding(.vertical, scale.space[2])
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-2"))
    }

    private var chip: some View {
        Text(verdict.verdict.displayLabel)
            .font(scale.caption.font(weight: .semibold))
            .padding(.horizontal, scale.space[1])
            .padding(.vertical, scale.space[0])
            .background(tone.opacity(0.16))
            .foregroundColor(tone)
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
    }

    private var tone: Color {
        switch verdict.verdict {
        case .approve: theme.color("add")
        case .requestChanges: theme.color("warn")
        case .comment: theme.color("fg-muted")
        }
    }

    private var metaLine: String {
        let time = relativeTime(verdict.reviewedAt, now: now())
        guard let ship else { return time }
        let sha = String(ship.round.headSHA.prefix(7))
        return "reviewed \(sha) · round \(ship.round.number) of \(ship.maxRounds) · \(time)"
    }

    @ViewBuilder
    private func actionRow(_ ship: ReviewVerdictShipContext) -> some View {
        HStack(spacing: scale.space[2]) {
            if let sentToOwner = ship.sentToOwner {
                Text(sentToOwner)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            AlasButton(title: "Review again", style: .normal, compact: true, action: actions.reviewAgain)
            if ship.canShipAnyway {
                AlasButton(title: "Ship anyway", style: .normal, compact: true, action: actions.shipAnyway)
            }
            if ship.reviewerSessionLive {
                AlasButton(title: "Open reviewer session", style: .subtle, compact: true, action: actions.openReviewerSession)
            }
        }
    }
}
