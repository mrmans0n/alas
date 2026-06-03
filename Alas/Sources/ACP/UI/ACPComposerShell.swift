import SwiftUI

enum ACPComposerPlacement: Equatable {
    case bottom
    case raisedEmpty

    static func bottomInset(for placement: ACPComposerPlacement, containerHeight: CGFloat) -> CGFloat {
        switch placement {
        case .bottom:
            return 18
        case .raisedEmpty:
            let target = containerHeight * 0.34
            let roomAwareMaximum = max(96, containerHeight - 260)
            return min(max(target, 96), min(320, roomAwareMaximum))
        }
    }
}

/// Floating glass pill composer. Wraps the AppKit-backed `ACPInputField`
/// in the design's chrome: heavy blur, model + mode pickers on the right,
/// animated send button that mirrors `session.transcript.streamingState`.
struct ACPComposer: View {
    @ObservedObject var session: ACPSession
    @ObservedObject private var composer: ACPComposerState
    let manager: ACPSessionManager
    let worktreeRoot: URL
    let agentLookup: (String) -> AgentDefinition?
    /// Current value of the `acpSendOnEnter` setting. Threaded down to
    /// `ACPInputField` so its placeholder reflects whichever action ⏎
    /// triggers under the current mapping.
    let sendOnEnter: Bool
    let focusRequest: Int
    let placement: ACPComposerPlacement
    let onSubmit: ACPComposerSubmitHandler
    let filesProvider: (@Sendable () async -> [URL])?

    @Environment(\.theme) private var theme
    @State private var inputFocused = false
    @StateObject private var actions = ACPComposerActions()
    @State private var hasText: Bool = false
    @State private var imageNotice: String?

    init(
        session: ACPSession,
        manager: ACPSessionManager,
        worktreeRoot: URL,
        agentLookup: @escaping (String) -> AgentDefinition?,
        sendOnEnter: Bool,
        focusRequest: Int = 0,
        placement: ACPComposerPlacement = .bottom,
        filesProvider: (@Sendable () async -> [URL])? = nil,
        onSubmit: @escaping ACPComposerSubmitHandler
    ) {
        self._session = ObservedObject(wrappedValue: session)
        self._composer = ObservedObject(wrappedValue: session.composer)
        self.manager = manager
        self.worktreeRoot = worktreeRoot
        self.agentLookup = agentLookup
        self.sendOnEnter = sendOnEnter
        self.focusRequest = focusRequest
        self.placement = placement
        self.filesProvider = filesProvider
        self.onSubmit = onSubmit
    }

    var body: some View {
        GeometryReader { proxy in
            composerLayout(
                bottomInset: ACPComposerPlacement.bottomInset(
                    for: placement,
                    containerHeight: proxy.size.height
                )
            )
        }
    }

    private var composerRow: some View {
        HStack {
            Spacer(minLength: 0)
            pill.frame(maxWidth: 720)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private func composerLayout(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            composerRow
                .padding(.top, 28)
                .padding(.bottom, bottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bottomShim.opacity(placement == .bottom ? 1 : 0))
    }

    private var bottomShim: some View {
        // Very gentle bottom shim — just enough that the pill doesn't
        // sit on a hard edge of transcript text. The transcript itself
        // has 240pt of bottom padding so most content stays above the
        // pill; this gradient only touches the last ~80pt.
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.55),
                .init(color: theme.color("bg-1").opacity(0.55), location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var pill: some View {
        VStack(spacing: 6) {
            if let imageNotice {
                Text(imageNotice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("del"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            ACPInputField(
                session: session,
                composer: composer,
                worktreeRoot: worktreeRoot,
                actions: actions,
                isFocused: $inputFocused,
                focusRequest: focusRequest,
                sendOnEnter: sendOnEnter,
                onDraftChange: { draft in
                    manager.persistComposerDraft(draft, for: session)
                    hasText = draft.hasContent
                },
                onDraftClear: { manager.clearComposerDraft(for: session) },
                onSubmit: onSubmit,
                onImageError: { error in
                    imageNotice = error.userMessage
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if imageNotice == error.userMessage { imageNotice = nil }
                    }
                },
                filesProvider: filesProvider
            )
            .frame(minHeight: 44, maxHeight: 140)
            .onAppear {
                hasText = composer.draft.hasContent
            }
            .onChange(of: composer.revision) { _, _ in
                hasText = composer.draft.hasContent
            }

            HStack(spacing: 8) {
                hint
                Spacer()
                attachButton
                autoRunToggle
                if let thinking = session.chipState.thinking {
                    thinkingChip(thinking)
                }
                ForEach(session.chipState.parameters) { parameter in
                    parameterChip(parameter)
                }
                if let mode = session.chipState.mode {
                    modeChip(mode)
                }
                if let models = session.chipState.models {
                    modelChip(models)
                }
                ACPComposerActionButton(
                    action: currentAction,
                    onPrimary: handlePrimary,
                    onMenu: handleMenu,
                    queueBadgeCount: session.queue.count
                )
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background {
            // Two layered BACKGROUNDS — both sit behind the content. The
            // previous version put the dark gradient as `.overlay`,
            // which painted it OVER the chips and text and washed them
            // out (this is the bug the user kept seeing). Material goes
            // closest to the content; the tint sits behind it.
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [theme.color("bg-2").opacity(0.55),
                                     theme.color("bg-1").opacity(0.65)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(borderColor, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    private var hint: some View {
        ViewThatFits(in: .horizontal) {
            hintContent(showShortcuts: true)
            hintContent(showShortcuts: false)
        }
    }

    private func hintContent(showShortcuts: Bool) -> some View {
        HStack(spacing: 6) {
            // Pulse + agent identity (icon + ACP label). Pulse moved here
            // from the toolbar so the "live agent" cue sits next to the
            // composer where focus is.
            ACPPulseDot(color: session.agentState == .disconnected ? theme.color("del") : theme.color("add"))
            if let agent = agentLookup(session.agentId) {
                AgentLogoView(agent: agent).frame(width: 14, height: 14)
            }
            if showShortcuts {
                Rectangle().fill(theme.color("line")).frame(width: 0.5, height: 12).padding(.horizontal, 2)
                kbdLabel("⏎")
                Text("send").font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.color("fg-muted"))
                kbdLabel("⇧⏎")
                Text("newline").font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.color("fg-muted"))
            }
        }
    }

    private func kbdLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, design: .monospaced))
            .fontWeight(.semibold)
            .foregroundStyle(theme.color("fg"))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(theme.color("bg-0").opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    private var borderColor: Color {
        inputFocused ? theme.color("add").opacity(0.7) : theme.color("line")
    }

    // MARK: - Auto-run pill (was in the toolbar)

    private var autoRunToggle: some View {
        Button {
            session.autoRunEnabled.toggle()
            manager.persist(session)
        } label: {
            Image(systemName: session.autoRunEnabled ? "bolt.fill" : "bolt")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(autoRunFg)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(autoRunBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(autoRunBorder, lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto-run")
        .disabled(autoRunDisabled)
        .opacity(autoRunDisabled ? 0.5 : 1.0)
        .help(autoRunHelp)
    }

    private var autoRunDisabled: Bool {
        if session.chipState.autoRun == .ignored { return true }
        switch session.transcript.streamingState {
        case .streaming, .sending: return true
        default: return session.agentState != .ready
        }
    }

    private var autoRunHelp: String {
        if session.chipState.autoRun == .ignored {
            return "Auto-run has no effect — this agent doesn't request permissions"
        }
        if case .streaming = session.transcript.streamingState { return "Auto-run cannot be changed while streaming" }
        if case .sending = session.transcript.streamingState { return "Auto-run cannot be changed while sending" }
        // .disconnected wins over "connecting" — it's a terminal state.
        if session.agentState == .disconnected { return "Agent disconnected" }
        if session.agentState != .ready { return "Agent connecting…" }
        return session.autoRunEnabled
            ? "Auto-run is ON — agent runs tools without asking"
            : "Click to skip permission prompts"
    }

    /// Mirrors the design's outlined-pill treatment: dark accent-tinted
    /// fill when active, plain dark when inactive. No glow or filled
    /// gradient — that styling diverges from the handoff.
    private var autoRunBg: Color {
        session.autoRunEnabled
            ? theme.color("caution").opacity(0.20)
            : theme.color("bg-3").opacity(0.7)
    }
    private var autoRunBorder: Color {
        session.autoRunEnabled
            ? theme.color("caution").opacity(0.55)
            : theme.color("line")
    }
    private var autoRunFg: Color {
        session.autoRunEnabled
            ? Color.blend(theme.color("caution"), .white, t: 0.55)
            : theme.color("fg-muted")
    }

    private var attachButton: some View {
        Button {
            actions.presentImagePicker?()
        } label: {
            Image(systemName: "photo")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.color("fg-muted"))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("bg-3").opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach image")
        .help("Attach an image")
    }

    // MARK: - Chip builders driven by ACPChipState

    private func modeChip(_ spec: ChipSpec) -> some View {
        chip(spec: spec,
             label: chipLabel(prefix: "Mode", spec: spec),
             placeholder: "Mode",
             accent: theme.color("accent"))
    }

    private func thinkingChip(_ spec: ChipSpec) -> some View {
        chip(spec: spec,
             label: chipLabel(prefix: "Thinking", spec: spec),
             placeholder: "Thinking",
             accent: theme.color("warn"))
    }

    private func modelChip(_ spec: ChipSpec) -> some View {
        chip(spec: spec,
             label: spec.options.first(where: { $0.id == spec.currentId })?.name
                    ?? spec.currentId
                    ?? "Model",
             placeholder: "Model",
             accent: theme.color("syntax-keyword"))
    }

    private func parameterChip(_ parameter: ACPParameterChip) -> some View {
        chip(spec: parameter.spec,
             label: chipLabel(prefix: parameter.label, spec: parameter.spec),
             placeholder: parameter.label,
             accent: theme.color("fg-muted"))
    }

    private func chip(spec: ChipSpec,
                      label: String,
                      placeholder: String,
                      accent: Color) -> some View {
        ACPSelectChip(
            label: label,
            placeholder: placeholder,
            accent: accent,
            items: spec.options.map {
                ACPSelectChip.Item(id: $0.id, name: $0.name, description: $0.description)
            },
            selectedId: spec.currentId,
            onSelect: { item in apply(spec: spec, selectedId: item.id) }
        )
    }

    /// "Mode: Plan" when a value is selected, "Mode" while pending.
    private func chipLabel(prefix: String, spec: ChipSpec) -> String {
        if let id = spec.currentId,
           let item = spec.options.first(where: { $0.id == id }) {
            return "\(prefix): \(item.name)"
        }
        return prefix
    }

    /// Dispatch a chip selection to the right RPC based on where the spec
    /// was sourced from. The composer doesn't need to know about agent
    /// differences — `ChipSpec.source` carries the dispatch info.
    private func apply(spec: ChipSpec, selectedId: String) {
        let sid = session.id
        let remoteId = session.remoteSessionId ?? sid
        switch spec.source {
        case .mode:
            session.currentMode = selectedId
        case .model:
            session.currentModel = selectedId
        case .configOption(let id):
            if let idx = session.availableConfigOptions.firstIndex(where: { $0.id == id }) {
                let old = session.availableConfigOptions[idx]
                session.availableConfigOptions[idx] = ACPConfigOption(
                    id: old.id, name: old.name, type: old.type,
                    category: old.category, currentValue: selectedId,
                    options: old.options)
            }
        }
        manager.persist(session)

        Task { @MainActor in
            guard let runner = manager.runners[sid] else { return }
            switch spec.source {
            case .mode:
                try? await runner.connection.setMode(sessionId: remoteId, modeId: selectedId)
            case .model:
                try? await runner.connection.setModel(sessionId: remoteId, modelId: selectedId)
            case .configOption(let id):
                // The agent's response carries the refreshed configOptions
                // (including dependent updates — e.g. switching reasoning
                // effort can reshape available model variants). Overwrite
                // the optimistic local update so dependent chips stay in
                // sync. Empty response → keep the optimistic state.
                if let updated = try? await runner.connection.setConfigOption(
                    sessionId: remoteId, configId: id, value: selectedId),
                   !updated.isEmpty {
                    session.availableConfigOptions = updated
                    manager.persist(session)
                }
            }
        }
    }

    private func stopTapped() {
        let sid = session.id
        Task { @MainActor in
            if let runner = manager.runners[sid] {
                await runner.userCancel()
            } else {
                session.transcript.streamingState = .idle
            }
        }
    }

    // MARK: - Unified action button wiring

    private var currentAction: ComposerAction {
        composerAction(
            streamingState: session.transcript.streamingState,
            hasText: hasText,
            agentState: session.agentState
        )
    }

    private func handlePrimary() {
        if let intent = primarySubmitIntent(for: currentAction, optionPressed: optionPressed) {
            actions.submitWithIntent?(intent)
            return
        }

        switch currentAction {
        case .stop:
            stopTapped()
        case .send, .queue, .hidden:
            break
        }
    }

    private var optionPressed: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.option) == true
    }

    private func handleMenu(_ item: ComposerMenuItem) {
        switch item {
        case .steer:
            actions.submitWithIntent?(.steer)
        case .stop:
            stopTapped()
        }
    }
}
