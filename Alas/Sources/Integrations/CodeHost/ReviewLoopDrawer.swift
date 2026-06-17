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
                .fill(toneColor(model.primaryTone).opacity(0.24))
                .frame(height: 1)
            collapsedRow(model: model)

            if state.isExpanded {
                expandedBody(model: model)
            }
        }
        .background(
            ZStack(alignment: .top) {
                theme.color("bg-1").opacity(0.97)
                toneColor(model.primaryTone).opacity(0.028)
            }
        )
    }

    private func collapsedRow(model: ReviewReadinessModel) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(toneColor(model.primaryTone))
                .frame(width: 6, height: 6)
                .shadow(color: toneColor(model.primaryTone).opacity(model.primaryTone == .muted ? 0 : 0.45), radius: 3)
            Icon(name: model.providerIconName, size: 11, color: theme.color("fg-faint"))
            headerTitle(model: model)

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
        .onTapGesture {
            toggleExpanded()
        }
        .focusable()
        .onKeyPress(.return) {
            toggleExpanded()
            return .handled
        }
        .onKeyPress(.space) {
            toggleExpanded()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.identity)
        .accessibilityHint(state.isExpanded ? "Collapse review status" : "Expand review status")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            toggleExpanded()
        }
    }

    private func toggleExpanded() {
        state.setExpanded(!state.isExpanded)
    }

    private func headerTitle(model: ReviewReadinessModel) -> some View {
        HStack(spacing: 3) {
            Text((model.providerTitle ?? model.identity).uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)

            if let requestNumberTitle = model.requestNumberTitle {
                Button {
                    onAction(.openReviewRequest)
                } label: {
                    Text(requestNumberTitle.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(theme.color("accent"))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Open \(model.providerTitle ?? "review") \(requestNumberTitle)")
            }
        }
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
                            ReviewReadinessActionButton(action: action) {
                                onAction(action.kind)
                            }
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
                .fill(color.opacity(chip.tone == .muted ? 0.07 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(chip.tone == .muted ? 0.2 : 0.34), lineWidth: 0.75)
        )
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

private struct ReviewReadinessActionButton: View {
    let action: ReviewReadinessModel.Action
    let onAction: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onAction) {
            HStack(spacing: 6) {
                Icon(name: action.iconName, size: iconSize, color: foreground)
                Text(action.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(border, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.5)
        .help(action.title)
    }

    private var iconSize: CGFloat {
        switch action.kind {
        case .openAgentHandoff:
            11
        default:
            10.5
        }
    }

    private var background: Color {
        switch action.emphasis {
        case .primary:
            theme.color("accent")
        case .normal:
            theme.color("bg-3").opacity(0.72)
        }
    }

    private var border: Color {
        switch action.emphasis {
        case .primary:
            theme.color("accent").opacity(0.7)
        case .normal:
            theme.color("line")
        }
    }

    private var foreground: Color {
        switch action.emphasis {
        case .primary:
            theme.color("bg-0")
        case .normal:
            theme.color("fg-muted")
        }
    }
}

private extension ReviewReadinessModel {
    var primaryTone: Chip.Tone {
        chips.first?.tone ?? .muted
    }
}
