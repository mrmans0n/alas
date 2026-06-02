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
            Divider().opacity(0.45)
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
        .background(theme.color("bg-1").opacity(0.96))
    }

    private func collapsedRow(model: ReviewReadinessModel) -> some View {
        HStack(spacing: 7) {
            NerdFontGlyphView(symbol: "\u{EA84}", hex: "7A8089")
                .frame(width: 13, height: 13)
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
                    Text(chip.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                                style: .normal,
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
        .font(.system(size: 10.5))
        .foregroundColor(theme.color("fg-dim"))
    }

    private func factRow(_ fact: ReviewReadinessModel.Fact) -> some View {
        HStack(spacing: 8) {
            Text(fact.label)
            Spacer(minLength: 8)
            Text(fact.value)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
