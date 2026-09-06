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

    static func syncStepState(_ state: GGSyncProgressPresentation.Step.State) -> String {
        switch state {
        case .pending: "Pending"
        case .current: "In progress"
        case .complete: "Complete"
        case .failed: "Failed"
        }
    }
}

struct ChangesPreparationReconciliationPresentation: Equatable {
    let spinnerColorToken: String?
    let accessibilityValue: String?

    static func make(
        for action: GGStackReadinessModel.Action
    ) -> ChangesPreparationReconciliationPresentation {
        ChangesPreparationReconciliationPresentation(
            spinnerColorToken: action.emphasis == .primary ? "bg-0" : nil,
            accessibilityValue: action.isInFlight ? "In progress" : nil
        )
    }
}

struct ChangesPreparationCard: View {
    let model: ChangesPreparationModel
    let onReviewChanges: () -> Void
    let onDraftCommit: () -> Void
    let onPublishCommit: () -> Void
    let onGGAction: (GGChangesPreparationAction) -> Void
    let onGGStackAction: (GGStackActionKind) -> Void
    let onReviewRequestAction: (ReviewReadinessActionKind) -> Void
    let onDismissSyncFailure: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let syncProgress = model.syncProgress {
                syncProgressView(syncProgress)
            } else {
                if let reviewAction = model.reviewAction {
                    primaryReviewButton(reviewAction)
                }
                if let reconciliationAction = model.reconciliationAction {
                    ggReconciliationButton(reconciliationAction)
                }
                if !model.ggActions.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], spacing: 6) {
                        ForEach(model.ggActions, id: \.kind) { action in
                            ggDestinationButton(action)
                        }
                    }
                } else if model.draftAction != nil || model.publishAction != nil || !model.reviewRequestActions.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        secondaryActionsHorizontal
                        secondaryActionsVertical
                    }
                }
            }
            if let error = model.mutationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("warn"))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("changes-preparation-gg-error")
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

    private func syncProgressView(_ progress: GGSyncProgressPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(progress.steps) { step in
                HStack(spacing: 7) {
                    syncStepIcon(step.state)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(step.title)
                        .font(.system(size: 11, weight: step.state == .current ? .semibold : .regular))
                        .foregroundStyle(theme.color(step.state == .pending ? "fg-faint" : "fg"))
                    Spacer(minLength: 6)
                    Text(step.detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.color("fg-faint"))
                        .lineLimit(1)
                }
                .frame(height: 20)
                .accessibilityElement(children: .combine)
                .accessibilityValue(ChangesPreparationCardText.syncStepState(step.state))
            }
        }
        .accessibilityIdentifier("changes-preparation-gg-sync-progress")
    }

    @ViewBuilder
    private func syncStepIcon(_ state: GGSyncProgressPresentation.Step.State) -> some View {
        switch state {
        case .pending:
            Circle().stroke(theme.color("line"), lineWidth: 1).frame(width: 8, height: 8)
        case .current:
            Spinner(lineWidth: 1.4, duration: 0.8).frame(width: 10, height: 10)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(theme.color("add"))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(theme.color("warn"))
        }
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
            if model.canDismissSyncFailure {
                Button(action: onDismissSyncFailure) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.color("fg-faint"))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss sync failure")
            }
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(ChangesPreparationCardText.reviewStats(
                        fileCount: action.fileCount,
                        additions: action.additions,
                        deletions: action.deletions
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("bg-0").opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var secondaryActionsHorizontal: some View {
        HStack(spacing: 8) {
            if let draftAction = model.draftAction {
                secondaryDraftButton(draftAction)
            }
            if let publishAction = model.publishAction {
                secondaryPublishButton(publishAction)
            }
            ForEach(model.reviewRequestActions, id: \.kind) { action in
                secondaryReviewRequestButton(action)
            }
        }
    }

    private var secondaryActionsVertical: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let draftAction = model.draftAction {
                secondaryDraftButton(draftAction)
            }
            if let publishAction = model.publishAction {
                secondaryPublishButton(publishAction)
            }
            ForEach(model.reviewRequestActions, id: \.kind) { action in
                secondaryReviewRequestButton(action)
            }
        }
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

    private func secondaryPublishButton(_ action: CommitPublishAvailability) -> some View {
        secondaryButton(
            title: action.label,
            subtitle: action.detail,
            iconName: "arrow.up",
            showsDot: false,
            isEnabled: action.isEnabled,
            help: action.disabledReason ?? action.detail,
            action: onPublishCommit
        )
        .accessibilityIdentifier("changes-preparation-publish")
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
            isInFlight: action.isInFlight,
            action: { onReviewRequestAction(action.kind) }
        )
        .accessibilityIdentifier("changes-preparation-review-request")
    }

    private func ggDestinationButton(_ action: ChangesPreparationModel.GGAction) -> some View {
        Button {
            onGGAction(action.kind)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if action.isInFlight {
                        Spinner(lineWidth: 1.5, duration: 0.7)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    } else {
                        Icon(name: ggIconName(for: action.kind), size: 10, color: theme.color("fg-dim"))
                    }
                    Text(action.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                Text(ggSubtitle(for: action))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled || action.isInFlight ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.color("bg-2").opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line").opacity(0.65), lineWidth: 0.75)
        )
        .help(action.disabledReason ?? action.title)
        .accessibilityValue(action.isInFlight ? "In progress" : "")
        .accessibilityIdentifier("changes-preparation-gg-\(ggIdentifier(for: action.kind))")
    }

    private func ggReconciliationButton(_ action: GGStackReadinessModel.Action) -> some View {
        let presentation = ChangesPreparationReconciliationPresentation.make(for: action)
        return Button {
            onGGStackAction(action.kind)
        } label: {
            HStack(spacing: 8) {
                if action.isInFlight {
                    Spinner(
                        lineWidth: 1.5,
                        duration: 0.7,
                        color: presentation.spinnerColorToken.map { theme.color($0) }
                    )
                        .frame(width: 11, height: 11)
                        .accessibilityHidden(true)
                } else {
                    Icon(
                        name: ggReconciliationIconName(for: action.kind),
                        size: 11,
                        color: action.emphasis == .primary
                            ? theme.color("bg-0")
                            : theme.color("fg-dim")
                    )
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(
                            action.emphasis == .primary
                                ? theme.color("bg-0")
                                : theme.color("fg")
                        )
                        .lineLimit(1)
                    if let detail = action.detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundColor(
                                action.emphasis == .primary
                                    ? theme.color("bg-0").opacity(0.78)
                                    : theme.color("fg-faint")
                            )
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled || action.isInFlight ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    action.emphasis == .primary
                        ? theme.color("accent")
                        : theme.color("bg-2").opacity(0.72)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line").opacity(0.65), lineWidth: 0.75)
        )
        .help(action.detail ?? action.title)
        .accessibilityValue(presentation.accessibilityValue ?? "")
        .accessibilityIdentifier("changes-preparation-gg-reconciliation")
    }

    private func ggSubtitle(for action: ChangesPreparationModel.GGAction) -> String {
        if action.isInFlight {
            return switch action.kind {
            case .amendCurrent: "Amending…"
            case .absorbIntoStack: "Absorbing…"
            case .newStackCommit, .commitAndSync: action.title
            }
        }
        if let disabledReason = action.disabledReason {
            return disabledReason
        }
        if action.hasNonEmptyDraft, !action.stats.hasChanges {
            return "Draft ready"
        }
        return ChangesPreparationCardText.draftStats(
            stagedCount: action.stats.files,
            additions: action.stats.insertions,
            deletions: action.stats.deletions
        )
    }

    private func ggIconName(for action: GGChangesPreparationAction) -> String {
        switch action {
        case .newStackCommit: "commit"
        case .commitAndSync: "arrow.clockwise"
        case .amendCurrent: "arrow.uturn.backward.circle"
        case .absorbIntoStack: "arrow.down.to.line.compact"
        }
    }

    private func ggIdentifier(for action: GGChangesPreparationAction) -> String {
        switch action {
        case .newStackCommit: "new"
        case .commitAndSync: "sync"
        case .amendCurrent: "amend"
        case .absorbIntoStack: "absorb"
        }
    }

    private func ggReconciliationIconName(for action: GGStackActionKind) -> String {
        switch action {
        case .rebase: "arrow.triangle.2.circlepath"
        case .sync: "arrow.clockwise"
        default: "arrow.clockwise"
        }
    }

    private func secondaryButton(
        title: String,
        subtitle: String,
        iconName: String,
        showsDot: Bool,
        isEnabled: Bool,
        isInFlight: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isInFlight {
                    Spinner(lineWidth: 1.5, duration: 0.7)
                        .frame(width: 11, height: 11)
                        .accessibilityHidden(true)
                } else {
                    Icon(name: iconName, size: 11, color: theme.color("fg-dim"))
                }
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
        .opacity(isEnabled || isInFlight ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.color("bg-2").opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line").opacity(0.65), lineWidth: 0.75)
        )
        .help(help ?? title)
    }
}
