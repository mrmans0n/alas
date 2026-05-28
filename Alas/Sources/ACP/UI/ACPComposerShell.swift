import SwiftUI

/// Floating glass pill composer. Wraps the AppKit-backed `ACPInputField`
/// in the design's chrome: heavy blur, model + mode pickers on the right,
/// animated send button that mirrors `session.streamingState`.
struct ACPComposer: View {
    @ObservedObject var session: ACPSession
    let manager: ACPSessionManager
    let worktreeRoot: URL
    let agentLookup: (String) -> AgentDefinition?
    let onSubmit: (_ text: String, _ attachments: [ACPMessage.Attachment]) -> Bool

    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool
    @StateObject private var actions = ACPComposerActions()

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                pill.frame(maxWidth: 720)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .padding(.top, 28)
        }
        .background(
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
        )
    }

    private var pill: some View {
        VStack(spacing: 6) {
            ACPInputField(
                session: session,
                worktreeRoot: worktreeRoot,
                actions: actions,
                onSubmit: onSubmit
            )
            .frame(minHeight: 44, maxHeight: 140)

            HStack(spacing: 8) {
                hint
                Spacer()
                autoRunToggle
                if let thinking = session.chipState.thinking {
                    thinkingChip(thinking)
                }
                if let mode = session.chipState.mode {
                    modeChip(mode)
                }
                if let models = session.chipState.models {
                    modelChip(models)
                }
                sendButton
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
        HStack(spacing: 6) {
            // Pulse + agent identity (icon + ACP label). Pulse moved here
            // from the toolbar so the "live agent" cue sits next to the
            // composer where focus is.
            ACPPulseDot(color: session.disconnected ? theme.color("del") : theme.color("add"))
            if let agent = agentLookup(session.agentId) {
                AgentLogoView(agent: agent).frame(width: 14, height: 14)
            }
            Text("ACP").font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("fg-muted"))
            Rectangle().fill(theme.color("line")).frame(width: 0.5, height: 12).padding(.horizontal, 2)
            kbdLabel("⏎")
            Text("send").font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.color("fg-muted"))
            kbdLabel("⇧⏎")
            Text("newline").font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.color("fg-muted"))
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
        inputFocused ? theme.color("accent").opacity(0.7) : theme.color("line")
    }

    // MARK: - Auto-run pill (was in the toolbar)

    private var autoRunToggle: some View {
        Button {
            session.autoRunEnabled.toggle()
            manager.persist(session)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: session.autoRunEnabled ? "bolt.fill" : "bolt")
                    .font(.system(size: 10, weight: .bold))
                Text("Auto-run")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(autoRunFg)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(autoRunBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(autoRunBorder, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help(autoRunHelpText)
    }

    private var autoRunHelpText: String {
        if session.chipState.autoRun == .ignored {
            return "Auto-run has no effect — this agent doesn't request permissions"
        }
        return session.autoRunEnabled
            ? "Auto-run is ON — agent runs tools without asking"
            : "Click to skip permission prompts"
    }

    /// Mirrors the design's outlined-pill treatment: dark accent-tinted
    /// fill when active, plain dark when inactive. No glow or filled
    /// gradient — that styling diverges from the handoff.
    private var autoRunBg: Color {
        session.autoRunEnabled
            ? theme.color("warn").opacity(0.20)
            : theme.color("bg-3").opacity(0.7)
    }
    private var autoRunBorder: Color {
        session.autoRunEnabled
            ? theme.color("warn").opacity(0.55)
            : theme.color("line")
    }
    private var autoRunFg: Color {
        session.autoRunEnabled
            ? Color.blend(theme.color("warn"), .white, t: 0.55)
            : theme.color("fg-muted")
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

    // MARK: - Send button

    private var sendButton: some View {
        Button {
            sendButtonTapped()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(buttonBg)
                Image(systemName: buttonGlyph)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(buttonFg)
            }
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(buttonBorder, lineWidth: 0.5))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sendDisabled)
        .opacity(sendDisabled ? 0.7 : 1.0)
        .help(sendHelpText)
    }

    /// True while we can't deliver a prompt: the agent process isn't
    /// attached yet, or it disconnected. Streaming/sending isn't covered
    /// here — those states swap the button to the cancel mode, which IS
    /// clickable.
    private var sendDisabled: Bool {
        switch session.streamingState {
        case .streaming, .sending: return false
        default: return !session.attached || session.disconnected
        }
    }

    private var sendHelpText: String {
        switch session.streamingState {
        case .streaming, .sending: return "Stop streaming"
        default:
            if session.disconnected { return "Agent disconnected" }
            if !session.attached    { return "Agent connecting…" }
            return "Send (⏎)"
        }
    }

    /// Click handler: send while idle, stop while streaming.
    private func sendButtonTapped() {
        switch session.streamingState {
        case .streaming, .sending:
            let sid = session.id
            Task { @MainActor in
                if let runner = manager.runners[sid] {
                    await runner.userCancel()
                } else {
                    session.streamingState = .idle
                }
            }
        default:
            guard !sendDisabled else { return }
            actions.submit?()
        }
    }

    /// Matches the design's `.chat-send` states. Idle = dark fill + line
    /// border (the "no input" look), ready = solid accent + accent
    /// border + dark icon, stop = solid del + dark icon.
    private var buttonBg: Color {
        switch session.streamingState {
        case .streaming, .sending: return theme.color("del")
        default:
            return sendDisabled
                ? theme.color("bg-3").opacity(0.7)
                : theme.color("accent")
        }
    }
    private var buttonFg: Color {
        switch session.streamingState {
        case .streaming, .sending: return theme.color("bg-0")
        default:
            return sendDisabled ? theme.color("fg-dim") : theme.color("bg-0")
        }
    }
    private var buttonBorder: Color {
        switch session.streamingState {
        case .streaming, .sending: return theme.color("del").opacity(0.7)
        default:
            return sendDisabled
                ? theme.color("line")
                : theme.color("accent").opacity(0.7)
        }
    }
    private var buttonGlyph: String {
        switch session.streamingState {
        case .streaming, .sending: return "stop.fill"
        default:                   return "arrow.up"
        }
    }
}
