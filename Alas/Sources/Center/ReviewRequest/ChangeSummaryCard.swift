import SwiftUI

/// What the change summary card shows. A summary is only presented, and only
/// copyable, while the branch still matches the facts it was drafted from.
enum ChangeSummaryPhase: Equatable {
    case summarizing
    case failed
    case current(ChangeSummaryDraft)
    case stale

    static func resolve(
        isSummarizing: Bool,
        draft: ChangeSummaryDraft?,
        currentFacts: ChangeSummaryFacts?
    ) -> Self {
        if isSummarizing { return .summarizing }
        guard let draft else { return .failed }
        return draft.isCurrent(for: currentFacts) ? .current(draft) : .stale
    }
}

/// On-device change summary for a draft review request. Copying is the only
/// way the text leaves the card; it never fills the title or description.
/// The narrative is not selectable, so the staleness check and facts that
/// Copy adds cannot be bypassed.
struct ChangeSummaryCard: View {
    let phase: ChangeSummaryPhase
    /// False while the branch is loading or no longer matches the draft.
    let canSummarize: Bool
    let onSummarize: () -> Void
    /// Copies the summary after re-checking the repository; false when the
    /// branch moved and the summary went stale instead.
    let onCopy: (ChangeSummaryDraft) async -> Bool
    let onCancel: () -> Void
    let onDismiss: () -> Void

    @State private var copied = false
    @State private var copying = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("fg-dim"))
                Text("Change summary")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Spacer()
                actions
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.color("fg-dim"))
                }
                .buttonStyle(.plain)
                .help("Dismiss this summary")
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .onChange(of: phase) { _, _ in copied = false }
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .summarizing:
            AlasButton(title: "Cancel", icon: "x", action: onCancel)
        case let .current(draft):
            AlasButton(title: copied ? "Copied" : "Copy", icon: copied ? "checkmark" : "doc.on.doc") {
                copying = true
                Task { @MainActor in
                    copied = await onCopy(draft)
                    copying = false
                }
            }
            .disabled(copying)
            .help("Copy the summary and change facts as Markdown")
        case .failed, .stale:
            AlasButton(title: "Summarize Again", icon: "arrow.clockwise", action: onSummarize)
                .disabled(!canSummarize)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .summarizing:
            HStack(spacing: 6) {
                Spinner().frame(width: 12, height: 12)
                note("Drafting on-device from commit messages, file names, and descriptions…")
            }
        case .failed:
            note("Couldn't draft a summary that stays within the branch's evidence.")
        case .stale:
            note("The branch changed since this summary was drafted.")
        case let .current(draft):
            Text(draft.narrative)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
                .fixedSize(horizontal: false, vertical: true)
            if let disclosure = draft.coverage.disclosure {
                Text(disclosure)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("warn"))
            }
            note(Self.factsLine(draft.facts))
            note("On-device draft. Review it before sharing; Copy includes the facts above as Markdown.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(theme.color("fg-dim"))
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func factsLine(_ facts: ChangeSummaryFacts) -> String {
        let runs = switch facts.runResults {
        case nil: "run results unavailable"
        case let results? where results.isEmpty: "no run results"
        case let results?: results.map { "\($0.scriptName) \($0.outcomeLabel)" }.joined(separator: ", ")
        }
        return "\(facts.commits.count) commits · \(facts.files.count) files · \(facts.lineStatistics) · \(runs)"
    }
}
