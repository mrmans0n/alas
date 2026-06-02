import SwiftUI

struct ReviewLoopDrawer: View {
    @Bindable var state: ReviewLoopState
    let canOpenAgentHandoff: Bool
    let onAction: (ReviewReadinessActionKind) -> Void

    @Environment(\.theme) private var theme

    private var model: ReviewReadinessModel {
        ReviewReadinessModel(
            snapshot: state.snapshot,
            lastError: state.lastError,
            canOpenAgentHandoff: canOpenAgentHandoff
        )
    }

    var body: some View {
        let model = model
        VStack(spacing: 0) {
            Rectangle()
                .fill(toneColor(model.primaryTone).opacity(0.34))
                .frame(height: 1)
            Button {
                state.setExpanded(!state.isExpanded)
            } label: {
                collapsedRow(model: model)
            }
            .buttonStyle(.plain)

            if state.isExpanded {
                expandedBody(model: model)
            }
        }
        .background(
            ZStack(alignment: .top) {
                theme.color("bg-1").opacity(0.97)
                toneColor(model.primaryTone).opacity(0.045)
            }
        )
    }

    private func collapsedRow(model: ReviewReadinessModel) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(toneColor(model.primaryTone))
                .frame(width: 6, height: 6)
                .shadow(color: toneColor(model.primaryTone).opacity(model.primaryTone == .muted ? 0 : 0.45), radius: 3)
            Icon(name: "branch", size: 11, color: theme.color("fg-faint"))
            Text(model.identity.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)

            if state.isRefreshing {
                Spinner(lineWidth: 1.4, duration: 0.8)
                    .frame(width: 11, height: 11)
            }

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                ForEach(model.chips) { chip in
                    chipView(chip)
                }
            }
            Icon(name: state.isExpanded ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func expandedBody(model: ReviewReadinessModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = model.title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let blockingText = model.blockingText {
                Text(blockingText)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.actions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.actions) { action in
                            AlasButton(
                                title: action.title,
                                style: style(for: action.kind),
                                action: { onAction(action.kind) }
                            )
                            .disabled(!action.isEnabled)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if !model.facts.isEmpty {
                facts(model.facts)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func facts(_ facts: [ReviewReadinessModel.Fact]) -> some View {
        VStack(spacing: 4) {
            ForEach(facts) { fact in
                factRow(fact)
            }
        }
    }

    private func factRow(_ fact: ReviewReadinessModel.Fact) -> some View {
        HStack(spacing: 8) {
            Text(fact.label)
                .font(.system(size: 10.5))
                .foregroundColor(theme.color("fg-faint"))
            Spacer(minLength: 8)
            Text(fact.value)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.color("bg-2").opacity(0.48))
        )
    }

    private func chipView(_ chip: ReviewReadinessModel.Chip) -> some View {
        let color = toneColor(chip.tone)
        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(chip.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(labelColor(for: chip.tone))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(chip.tone == .muted ? 0.08 : 0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(chip.tone == .muted ? 0.22 : 0.42), lineWidth: 0.75)
        )
    }

    private func style(for action: ReviewReadinessActionKind) -> AlasButtonStyle {
        switch action {
        case .pushBranch, .createReviewRequest, .openAgentHandoff:
            return .primary
        case .refresh, .openReviewRequest, .rerunFailedChecks, .merge:
            return .normal
        }
    }

    private func labelColor(for tone: ReviewReadinessModel.Chip.Tone) -> Color {
        switch tone {
        case .muted:
            return theme.color("fg-dim")
        case .accent, .success, .warning, .danger:
            return theme.darkMode
                ? Color.blend(toneColor(tone), .white, t: 0.55)
                : Color.blend(toneColor(tone), .black, t: 0.25)
        }
    }

    private func toneColor(_ tone: ReviewReadinessModel.Chip.Tone) -> Color {
        switch tone {
        case .accent: theme.color("accent")
        case .success: theme.color("add")
        case .warning: theme.color("warn")
        case .danger: theme.color("del")
        case .muted: theme.color("fg-faint")
        }
    }
}

private extension ReviewReadinessModel {
    var primaryTone: Chip.Tone {
        chips.first?.tone ?? .muted
    }
}
