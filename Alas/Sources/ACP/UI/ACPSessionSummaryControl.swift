import SwiftUI

struct ACPSessionSummaryControl: View {
    @Environment(\.designScale) private var scale
    @ObservedObject var coordinator: SessionSummaryCoordinator
    @ObservedObject var session: ACPSession
    @ObservedObject private var composer: ACPComposerState
    let requested: Bool
    let runtimeEnabled: Bool
    let supported: Bool
    let model: LocalTextModelState

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var isLit: Bool { hovering || cardIsShown }

    private var cardIsShown: Bool {
        coordinator.cardMode != nil && coordinator.boundSessionIncarnation == session.incarnation
    }

    init(
        coordinator: SessionSummaryCoordinator,
        session: ACPSession,
        requested: Bool,
        runtimeEnabled: Bool,
        supported: Bool,
        model: LocalTextModelState
    ) {
        self.coordinator = coordinator
        self.session = session
        _composer = ObservedObject(wrappedValue: session.composer)
        self.requested = requested
        self.runtimeEnabled = runtimeEnabled
        self.supported = supported
        self.model = model
    }

    var body: some View {
        let idle = SessionSummaryIdleFacts.current(session: session, composer: composer).isIdle
        let presentation = ACPSessionSummaryPresentation(
            requested: requested,
            runtimeEnabled: runtimeEnabled,
            supported: supported,
            model: model,
            idle: idle,
            hasCompleteTurn: idle && SessionSummaryContext.hasCompleteTurn(session: session),
            phase: coordinator.phase
        )

        if presentation.isVisible {
            control(presentation: presentation)
        }
    }

    private func control(presentation: ACPSessionSummaryPresentation) -> some View {
        Button {
            // The recap strip in the composer shows the result.
            switch ACPSessionSummaryPresentation.controlAction(cardShown: cardIsShown, phase: coordinator.phase) {
            case .cancel:
                coordinator.cancelPresentation()
            case .summarize:
                Task { await coordinator.summary(for: session, mode: .manual) }
            case .refresh:
                Task { await coordinator.refresh(session, mode: .manual) }
            }
        } label: {
            HStack(spacing: scale.space[1]) {
                if coordinator.phase == .loading {
                    if reduceMotion {
                        Image(systemName: "hourglass")
                            .font(scale.caption.font(weight: .regular))
                    } else {
                        Spinner(lineWidth: 1.5)
                            .frame(width: 10, height: 10)
                    }
                } else {
                    Image(systemName: "text.quote")
                        .font(scale.caption.font(weight: .regular))
                }
                Text("Summarize Session")
                    .font(scale.caption.font(weight: .semibold))
            }
            .foregroundStyle(theme.color(isLit ? "accent" : "fg-muted"))
            .padding(.horizontal, scale.space[2])
            .frame(height: 24)
            .background(
                theme.color("accent").opacity(isLit ? 0.18 : 0.08),
                in: RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous)
                    .strokeBorder(theme.color("accent").opacity(isLit ? 0.5 : 0.25), lineWidth: 0.5)
            }
        }
        .buttonStyle(.toolbarControl)
        .onHover { hovering = $0 }
        .help(ACPSessionSummaryPresentation.help)
        .accessibilityLabel("Summarize Session")
        .accessibilityHint(ACPSessionSummaryPresentation.help)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityAddTraits(cardIsShown ? .isSelected : [])
        .accessibilityIdentifier("acp-session-summary")
    }
}
