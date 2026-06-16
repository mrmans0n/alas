import SwiftUI

enum ChangesPreparationCardText {
    static func reviewStats(fileCount: Int, additions: Int?, deletions: Int?) -> String {
        let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
        guard let additions, let deletions else { return files }
        return "\(files) · +\(additions) −\(deletions)"
    }

    static func draftStats(stagedCount: Int, additions: Int, deletions: Int) -> String {
        guard stagedCount > 0 else { return "0 staged" }
        let staged = stagedCount == 1 ? "1 staged" : "\(stagedCount) staged"
        return "\(staged) · +\(additions) −\(deletions)"
    }
}

struct ChangesPreparationCard: View {
    let model: ChangesPreparationModel
    let onReviewChanges: () -> Void
    let onDraftCommit: () -> Void
    let onReviewRequestAction: (ReviewReadinessActionKind) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let reviewAction = model.reviewAction {
                primaryReviewButton(reviewAction)
            }
            if model.draftAction != nil || model.reviewRequestAction != nil {
                HStack(spacing: 8) {
                    if let draftAction = model.draftAction {
                        secondaryDraftButton(draftAction)
                    }
                    if let reviewRequestAction = model.reviewRequestAction {
                        secondaryReviewRequestButton(reviewRequestAction)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.color("bg-1"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line").opacity(0.75), lineWidth: 0.75)
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityIdentifier("changes-preparation-card")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Icon(name: "diff", size: 11, color: theme.color("fg-faint"))
            Text("Prepare")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
    }

    private func primaryReviewButton(_ action: ChangesPreparationModel.ReviewAction) -> some View {
        Button(action: onReviewChanges) {
            HStack(spacing: 9) {
                Icon(name: "diff", size: 13, color: theme.color("bg-0"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.color("bg-0"))
                    Text(ChangesPreparationCardText.reviewStats(
                        fileCount: action.fileCount,
                        additions: action.additions,
                        deletions: action.deletions
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("bg-0").opacity(0.72))
                }
                Spacer(minLength: 8)
                Icon(name: "chev-right", size: 11, color: theme.color("bg-0").opacity(0.72))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.color("accent"))
        )
        .help(action.title)
        .accessibilityIdentifier("changes-preparation-review")
    }

    private func secondaryDraftButton(_ action: ChangesPreparationModel.DraftAction) -> some View {
        secondaryButton(
            title: action.title,
            subtitle: ChangesPreparationCardText.draftStats(
                stagedCount: action.stagedCount,
                additions: action.additions,
                deletions: action.deletions
            ),
            iconName: "commit",
            showsDot: action.hasNonEmptyDraft,
            isEnabled: true,
            action: onDraftCommit
        )
        .accessibilityIdentifier("changes-preparation-draft")
    }

    private func secondaryReviewRequestButton(
        _ action: ChangesPreparationModel.ReviewRequestAction
    ) -> some View {
        secondaryButton(
            title: action.title,
            subtitle: "Branch review",
            iconName: action.iconName,
            showsDot: action.emphasis == .primary,
            isEnabled: action.isEnabled,
            action: { onReviewRequestAction(action.kind) }
        )
        .accessibilityIdentifier("changes-preparation-review-request")
    }

    private func secondaryButton(
        title: String,
        subtitle: String,
        iconName: String,
        showsDot: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(name: iconName, size: 11, color: theme.color("fg-dim"))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(theme.color("fg"))
                            .lineLimit(1)
                        if showsDot {
                            Circle()
                                .fill(theme.color("accent"))
                                .frame(width: 5, height: 5)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.color("bg-2").opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line").opacity(0.65), lineWidth: 0.75)
        )
        .help(title)
    }
}
