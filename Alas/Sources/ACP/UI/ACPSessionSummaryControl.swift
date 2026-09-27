import SwiftUI

struct ACPSessionSummaryControl: View {
    @ObservedObject var coordinator: SessionSummaryCoordinator
    @ObservedObject var session: ACPSession
    @ObservedObject private var composer: ACPComposerState
    let requested: Bool
    let runtimeEnabled: Bool
    let supported: Bool
    let model: LocalTextModelState

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popoverOpen = false
    @State private var hovering = false

    private var isLit: Bool { hovering || popoverOpen }

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

        Group {
            if presentation.isVisible {
                control(presentation: presentation)
            }
        }
        .onChange(of: popoverOpen) { wasOpen, isOpen in
            if wasOpen, !isOpen {
                coordinator.cancelPresentation()
            }
        }
        .onChange(of: coordinator.presentationGeneration) {
            popoverOpen = ACPSessionSummaryPresentation.popoverOpenAfterGenerationChange(
                wasOpen: popoverOpen
            )
        }
        .onDisappear {
            guard popoverOpen || coordinator.phase == .loading else { return }
            popoverOpen = false
            coordinator.cancelPresentation()
        }
    }

    private func control(presentation: ACPSessionSummaryPresentation) -> some View {
        Button {
            if popoverOpen {
                popoverOpen = false
            } else if coordinator.phase == .loading {
                coordinator.cancelPresentation()
            } else {
                // Generate first, then present the finished summary; a cancel or
                // session activity in between leaves the phase idle, so nothing opens.
                Task {
                    await coordinator.summary(for: session)
                    switch coordinator.phase {
                    case .result, .failed: popoverOpen = true
                    case .idle, .loading: break
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if coordinator.phase == .loading {
                    if reduceMotion {
                        Image(systemName: "hourglass")
                            .font(.system(size: 10))
                    } else {
                        Spinner(lineWidth: 1.5)
                            .frame(width: 10, height: 10)
                    }
                } else {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10))
                }
                Text("Summarize Session")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(theme.color(isLit ? "accent" : "fg-muted"))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                theme.color("accent").opacity(isLit ? 0.18 : 0.08),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.color("accent").opacity(isLit ? 0.5 : 0.25), lineWidth: 0.5)
            }
        }
        .buttonStyle(.toolbarControl)
        .onHover { hovering = $0 }
        .help(ACPSessionSummaryPresentation.help)
        .accessibilityLabel("Summarize Session")
        .accessibilityHint(ACPSessionSummaryPresentation.help)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityAddTraits(popoverOpen ? .isSelected : [])
        .accessibilityIdentifier("acp-session-summary")
        .popover(isPresented: $popoverOpen, arrowEdge: .top) {
            ACPSessionSummaryPopover(
                coordinator: coordinator,
                session: session,
                presentation: presentation,
                isPresented: $popoverOpen
            )
        }
    }
}
