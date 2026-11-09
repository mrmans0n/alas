import SwiftUI

struct ReviewLoopDrawer: View {
    @Bindable var state: ReviewLoopState
    let canOpenAgentHandoff: Bool
    let onAction: (ReviewReadinessActionKind) -> Void
    var onRevealReviewRequest: (Int) -> Void = { _ in }
    var shepherd: ReviewShepherdDrawerModel? = nil
    var servedActions: Set<ReviewReadinessActionKind>? = nil

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: ReviewReadinessModel {
        ReviewReadinessModel(
            snapshot: state.snapshot,
            lastError: state.lastError,
            canOpenAgentHandoff: canOpenAgentHandoff,
            inFlightAction: state.inFlightAction,
            servedActions: servedActions
        )
    }

    private var layout: PaneDrawerLayout {
        PaneDrawerLayout(expanded: state.isExpanded)
    }

    var body: some View {
        let model = model
        VStack(spacing: 0) {
            collapsedRow(model: model)

            if state.isExpanded {
                expandedBody(model: model)
                    .transition(.paneDrawerBody)
            }
        }
        // The status tone lives in the dot and chips only; the surface
        // itself stays neutral so it matches the section header bands.
        .paneDrawer(layout, fill: theme.color("section-head-bg"), hairline: theme.color("line"))
    }

    private func collapsedRow(model: ReviewReadinessModel) -> some View {
        PaneDrawerRow(
            leading: {
                Circle()
                    .fill(toneColor(model.primaryTone))
                    .frame(width: 6, height: 6)
                    .shadow(color: toneColor(model.primaryTone).opacity(model.primaryTone == .muted ? 0 : 0.45), radius: 3)
                Icon(name: model.providerIconName, size: 11, color: theme.color("fg-faint"))
            },
            identity: { headerTitle(model: model) },
            chips: { compact in
                if let shepherd, shepherd.record != nil {
                    ReviewShepherdChip(model: shepherd)
                }
                ForEach(model.chips) { chip in
                    chipView(chip, compact: compact)
                }
            },
            trailing: {
                if state.showsRefreshProgress {
                    Spinner(lineWidth: 1.4, duration: 0.8)
                        .frame(width: 11, height: 11)
                }
                Icon(name: "chev-right", size: 10, color: theme.color("fg-faint"))
                    .rotationEffect(layout.chevronAngle)
            }
        )
        .padding(.horizontal, layout.innerHorizontal(scale.space[3]))
        .padding(.vertical, scale.space[2])
        .contentShape(Rectangle())
        .onTapGesture {
            toggleExpanded()
        }
        .focusable()
        .focusEffectDisabled()
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

    func toggleExpanded() {
        withAnimation(PaneDrawerLayout.animation(reduceMotion: reduceMotion)) {
            state.setExpanded(!state.isExpanded)
        }
        if state.isExpanded, let request = state.snapshot?.reviewRequest {
            onRevealReviewRequest(request.number)
        }
    }

    func performAction(_ action: ReviewReadinessActionKind) {
        if let request = state.snapshot?.reviewRequest {
            onRevealReviewRequest(request.number)
        }
        onAction(action)
    }

    private func headerTitle(model: ReviewReadinessModel) -> some View {
        HStack(spacing: scale.space[1]) {
            Text((model.providerTitle ?? model.identity).uppercased())
                .font(scale.caption.font(weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.providerTitle ?? model.identity)

            if let requestNumberTitle = model.requestNumberTitle {
                Button {
                    performAction(.openReviewRequest)
                } label: {
                    Text(requestNumberTitle.uppercased())
                        .font(scale.caption.font(weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(theme.color("accent"))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(state.inFlightAction != nil)
                .opacity(state.inFlightAction == nil ? 1 : 0.5)
                .help("Open \(model.providerTitle ?? "review") \(requestNumberTitle)")
            }
        }
    }

    private func expandedBody(model: ReviewReadinessModel) -> some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            if let title = model.title {
                Text(title)
                    .font(scale.title.font)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let blockingText = model.blockingText {
                Text(blockingText)
                    .font(scale.meta.font)
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let shepherd {
                ReviewShepherdBlock(model: shepherd)
            }

            if !model.actions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: scale.space[2]) {
                        ForEach(model.actions) { action in
                            ReviewReadinessActionButton(action: action) {
                                performAction(action.kind)
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
        .padding(.horizontal, layout.innerHorizontal(scale.space[3]))
        .padding(.bottom, scale.space[3])
    }

    private func facts(_ facts: [ReviewReadinessModel.Fact]) -> some View {
        VStack(spacing: scale.space[1]) {
            ForEach(facts) { fact in
                factRow(fact)
            }
        }
    }

    private func factRow(_ fact: ReviewReadinessModel.Fact) -> some View {
        HStack(spacing: scale.space[2]) {
            Text(fact.label)
                .font(scale.meta.font)
                .foregroundColor(theme.color("fg-faint"))
            Spacer(minLength: scale.space[2])
            Text(fact.value)
                .font(scale.meta.font(weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, scale.space[2])
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: scale.radius.small)
                .fill(theme.color("bg-2").opacity(0.48))
        )
    }

    /// Chip text for the collapsed row. The compact form only differs for the
    /// one label long enough to push the identity off the row.
    static func chipLabel(for chip: ReviewReadinessModel.Chip, compact: Bool) -> String {
        guard compact else { return chip.title }
        return chip.id == "unsupported" ? "No code host" : chip.title
    }

    private func chipView(_ chip: ReviewReadinessModel.Chip, compact: Bool) -> some View {
        let color = toneColor(chip.tone)
        return HStack(spacing: scale.space[1]) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(Self.chipLabel(for: chip, compact: compact))
                .font(scale.meta.font(weight: .medium))
                .foregroundColor(labelColor(for: chip.tone))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, scale.space[2])
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .fill(color.opacity(chip.tone == .muted ? 0.07 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(color.opacity(chip.tone == .muted ? 0.2 : 0.34), lineWidth: 0.75)
        )
        .help(chip.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.title)
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
    @Environment(\.designScale) private var scale

    var body: some View {
        Button(action: onAction) {
            HStack(spacing: scale.space[2]) {
                if action.isInFlight {
                    Spinner(lineWidth: 1.5, duration: 0.7)
                        .frame(width: iconSize, height: iconSize)
                        .accessibilityHidden(true)
                } else {
                    Icon(name: action.iconName, size: iconSize, color: foreground)
                }
                Text(action.title)
                    .font(scale.meta.font(weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, scale.space[3])
            .frame(height: 26)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(border, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled || action.isInFlight ? 1 : 0.5)
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
    /// Drives the status dot; the drawer surface itself is tone-neutral.
    var primaryTone: Chip.Tone {
        chips.first?.tone ?? .muted
    }
}

/// The collapsed row shared by the review and stack drawers. Fallbacks, in
/// order: everything on one line; identity and chips on two lines; two lines
/// with the short chip label. Only the last may shorten the identity, and the
/// callers keep the full text in `.help` and the accessibility label.
struct PaneDrawerRow<Leading: View, Identity: View, Chips: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let identity: () -> Identity
    @ViewBuilder let chips: (_ compact: Bool) -> Chips
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.designScale) private var scale

    var body: some View {
        ViewThatFits(in: .horizontal) {
            oneLine
            twoLines(compact: false, shortensIdentity: false)
            twoLines(compact: true, shortensIdentity: true)
        }
    }

    private var oneLine: some View {
        HStack(spacing: scale.space[2]) {
            leading()
            identity().fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: scale.space[2])
            HStack(spacing: scale.space[1]) { chips(false) }
                .fixedSize(horizontal: true, vertical: false)
            trailing()
        }
    }

    private func twoLines(compact: Bool, shortensIdentity: Bool) -> some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            HStack(spacing: scale.space[2]) {
                leading()
                if shortensIdentity {
                    identity()
                } else {
                    identity().fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: scale.space[2])
                trailing()
            }
            HStack(spacing: scale.space[1]) { chips(compact) }
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
