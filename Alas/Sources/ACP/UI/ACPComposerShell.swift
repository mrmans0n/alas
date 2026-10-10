import SwiftUI

enum ACPComposerControlPresentation {
    static func modeUsesWarningTint(_ spec: ChipSpec) -> Bool {
        spec.options.first(where: { $0.id == spec.currentId })?.kind == .fullAccess
    }

    static func fastModeIconName(isEnabled: Bool) -> String {
        isEnabled ? "bolt.fill" : "bolt"
    }

    static func autoRunIconName(isEnabled: Bool) -> String {
        isEnabled ? "play.fill" : "play"
    }

    static func micIconName(for state: ACPDictationState) -> String {
        state == .listening ? "mic.fill" : "mic"
    }

    /// Entries for the mic button's language menu: the automatic choice
    /// first, then the installed languages by name. A language the user
    /// picked in Settings but hasn't downloaded yet is included too, so the
    /// menu never contradicts the actual setting.
    static func dictationMenuItems(installed: [String], selected: String) -> [ACPDictationMenuItem] {
        var identifiers = installed
        let normalizedSelection = selected.replacingOccurrences(of: "-", with: "_")
        if !normalizedSelection.isEmpty,
           !identifiers.contains(where: { $0.replacingOccurrences(of: "-", with: "_") == normalizedSelection }) {
            identifiers.append(normalizedSelection)
        }
        let items = ACPDictationLocaleFormatter.sortedByDisplayName(identifiers).map { identifier in
            ACPDictationMenuItem(
                localeIdentifier: identifier,
                title: ACPDictationLocaleFormatter.displayName(for: identifier),
                isSelected: identifier.replacingOccurrences(of: "-", with: "_") == normalizedSelection
            )
        }
        let automatic = ACPDictationMenuItem(
            localeIdentifier: ACPDictationLocaleFormatter.automaticIdentifier,
            title: ACPDictationLocaleFormatter.displayName(for: ACPDictationLocaleFormatter.automaticIdentifier),
            isSelected: normalizedSelection.isEmpty
        )
        return [automatic] + items
    }

    static func micHelp(for state: ACPDictationState) -> String {
        switch state {
        case .unavailable: return "Dictation unavailable"
        case .idle: return "Dictate into the composer"
        case .preparing: return "Preparing dictation…"
        case .listening: return "Listening — click to stop"
        case .failed(let message): return message
        }
    }

    static func fastModeHelp(isEnabled: Bool, canToggle: Bool) -> String {
        guard canToggle else { return "Fast mode cannot be changed" }
        return isEnabled
            ? "Fast mode is ON — click to disable"
            : "Click to enable fast mode"
    }

    static func canRenderFastModeButton(for spec: ChipSpec) -> Bool {
        isFastModeToggleSelect(spec) && rawFastModeToggleTarget(for: spec) != nil
    }

    static func fastModeToggleTarget(for spec: ChipSpec) -> String? {
        guard isFastModeToggleSelect(spec) else { return nil }
        return rawFastModeToggleTarget(for: spec)
    }

    static func isFastModeEnabled(_ spec: ChipSpec) -> Bool {
        guard let currentId = spec.currentId else { return false }
        if let item = spec.options.first(where: { $0.id == currentId }) {
            return isFastModeOn(id: item.id, name: item.name)
        }
        return isFastModeOn(id: currentId, name: currentId)
    }

    private static func isFastModeToggleSelect(_ spec: ChipSpec) -> Bool {
        guard !spec.options.isEmpty else { return false }

        var hasOnOption = false
        var hasOffOption = false
        for option in spec.options {
            if isFastModeOn(id: option.id, name: option.name) {
                hasOnOption = true
            } else if isFastModeOff(id: option.id, name: option.name) {
                hasOffOption = true
            } else {
                return false
            }
        }

        return hasOnOption && hasOffOption
    }

    private static func rawFastModeToggleTarget(for spec: ChipSpec) -> String? {
        if isFastModeEnabled(spec) {
            return spec.options.first(where: { isFastModeOff(id: $0.id, name: $0.name) })?.id
        }
        return spec.options.first(where: { isFastModeOn(id: $0.id, name: $0.name) })?.id
    }

    private static func isFastModeOn(id: String, name: String) -> Bool {
        let tokens = [normalizedFastModeValue(id), normalizedFastModeValue(name)]
        return tokens.contains { ["true", "on", "enabled", "yes", "1", "fast"].contains($0) }
    }

    private static func isFastModeOff(id: String, name: String) -> Bool {
        let tokens = [normalizedFastModeValue(id), normalizedFastModeValue(name)]
        return tokens.contains { ["false", "off", "disabled", "no", "0", "standard"].contains($0) }
    }

    private static func normalizedFastModeValue(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

enum ACPComposerOverflowItem: Hashable {
    case mode
    case thinking
    case fastMode
    case autoRun
    case parameter(String)
    case boolean(String)
    case provider
    case authentication

    static func items(
        hasMode: Bool,
        hasThinking: Bool,
        hasFastMode: Bool,
        parameterIDs: [String],
        booleanIDs: [String],
        hasProvider: Bool,
        hasAuthentication: Bool
    ) -> [Self] {
        var result: [Self] = []
        if hasMode { result.append(.mode) }
        if hasThinking { result.append(.thinking) }
        if hasFastMode { result.append(.fastMode) }
        result.append(.autoRun)
        result.append(contentsOf: parameterIDs.map(Self.parameter))
        result.append(contentsOf: booleanIDs.map(Self.boolean))
        if hasProvider { result.append(.provider) }
        if hasAuthentication { result.append(.authentication) }
        return result
    }
}

enum ACPComposerPlacement: Equatable {
    case bottom
    case inFlow

    static func bottomInset(for placement: ACPComposerPlacement, containerHeight: CGFloat) -> CGFloat {
        switch placement {
        case .bottom, .inFlow:
            return 18
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
    /// Current value of the `acpSendOnEnter` setting. Threaded down to
    /// `ACPInputField` so its placeholder reflects whichever action ⏎
    /// triggers under the current mapping.
    let sendOnEnter: Bool
    /// Current value of the `acpDictationLocale` setting. Empty means the
    /// dictation engine picks a language automatically.
    let dictationLocale: String
    /// Persists a language chosen from the mic's context menu.
    let onSelectDictationLocale: (String) -> Void
    let focusRequest: Int
    let dropRouter: ACPComposerDropRouter
    let placement: ACPComposerPlacement
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let actions: ACPComposerActions
    let onSubmit: ACPComposerSubmitHandler
    let filesProvider: (@Sendable () async -> [URL])?
    let sessionMentions: ACPSessionMentionSource?
    let symbolMentions: ACPSymbolMentionSource?

    let nextPromptOffer: String?
    let takeNextPromptOffer: () -> String?
    let dismissNextPromptOffer: () -> Void
    let onNextPromptStateChange: (NextPromptEligibilitySnapshot.Environment) -> Void
    let nextPromptInputBlocked: () -> Bool
    /// Slash prompts plugins add, offered after Alas's own commands.
    let pluginPrompts: [ACPPromptSuggestion]
    /// Plugins that add context to every prompt; named in a chip so the context is never invisible.
    let contextProviders: [String]

    @Environment(\.theme) private var theme
    @State private var inputFocused = false
    @State private var hasText: Bool = false
    @State private var composerNotice: String?
    @StateObject private var dictation = ACPDictationService(engine: ACPSpeechDictationEngine())
    /// Languages ready to use without a download, for the mic's menu.
    @State private var installedDictationLocales: [String] = []

    init(
        session: ACPSession,
        manager: ACPSessionManager,
        worktreeRoot: URL,
        sendOnEnter: Bool,
        dictationLocale: String = "",
        onSelectDictationLocale: @escaping (String) -> Void = { _ in },
        focusRequest: Int = 0,
        dropRouter: ACPComposerDropRouter,
        placement: ACPComposerPlacement = .bottom,
        contentMaxWidth: CGFloat = ACPChatLayout.defaultContentMaxWidth,
        typography: ACPChatTypography = .default,
        actions: ACPComposerActions,
        filesProvider: (@Sendable () async -> [URL])? = nil,
        sessionMentions: ACPSessionMentionSource? = nil,
        symbolMentions: ACPSymbolMentionSource? = nil,
        nextPromptOffer: String? = nil,
        takeNextPromptOffer: @escaping () -> String? = { nil },
        dismissNextPromptOffer: @escaping () -> Void = {},
        onNextPromptStateChange: @escaping (NextPromptEligibilitySnapshot.Environment) -> Void = { _ in },
        nextPromptInputBlocked: @escaping () -> Bool = { false },
        pluginPrompts: [ACPPromptSuggestion] = [],
        contextProviders: [String] = [],
        onSubmit: @escaping ACPComposerSubmitHandler
    ) {
        self._session = ObservedObject(wrappedValue: session)
        self._composer = ObservedObject(wrappedValue: session.composer)
        self.manager = manager
        self.worktreeRoot = worktreeRoot
        self.sendOnEnter = sendOnEnter
        self.dictationLocale = dictationLocale
        self.onSelectDictationLocale = onSelectDictationLocale
        self.focusRequest = focusRequest
        self.dropRouter = dropRouter
        self.placement = placement
        self.contentMaxWidth = contentMaxWidth
        self.typography = typography
        self.actions = actions
        self.filesProvider = filesProvider
        self.sessionMentions = sessionMentions
        self.symbolMentions = symbolMentions
        self.onSubmit = onSubmit
        self.nextPromptOffer = nextPromptOffer
        self.takeNextPromptOffer = takeNextPromptOffer
        self.dismissNextPromptOffer = dismissNextPromptOffer
        self.onNextPromptStateChange = onNextPromptStateChange
        self.nextPromptInputBlocked = nextPromptInputBlocked
        self.pluginPrompts = pluginPrompts
        self.contextProviders = contextProviders
    }

    var body: some View {
        switch placement {
        case .inFlow:
            VStack(spacing: 0) {
                noticeBanner
                composerRow
                    .padding(.top, 28)
                    .padding(
                        .bottom,
                        ACPComposerPlacement.bottomInset(for: .inFlow, containerHeight: 0)
                    )
            }
            .frame(maxWidth: .infinity)
        case .bottom:
            GeometryReader { proxy in
                composerLayout(
                    bottomInset: ACPComposerPlacement.bottomInset(
                        for: placement,
                        containerHeight: proxy.size.height
                    )
                )
            }
        }
    }

    /// Live ACP session-notice banner. Inserted as a sibling immediately
    /// above `composerRow` in each placement's own layout — rather than
    /// wrapped around `ACPComposer` from the outside — because `.bottom`
    /// fills its full available height and self-anchors the pill to the
    /// bottom via an internal `Spacer`; an externally-wrapping VStack would
    /// hand that `Spacer` most of the height and strand the banner at the
    /// top of the chat surface instead of above the composer.
    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = session.activeNotice {
            HStack {
                Spacer(minLength: 0)
                ACPSessionNoticeBanner(notice: notice) {
                    session.dismissActiveNotice()
                }
                .frame(maxWidth: contentMaxWidth)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeOut(duration: 0.15), value: session.activeNotice)
        }
    }

    /// Active background work, docked flush on top of the pill. Lives here
    /// rather than around `ACPComposer` for the same reason as `noticeBanner`.
    @ViewBuilder
    private var backgroundTaskTray: some View {
        let tasks = session.activeBackgroundTasks
        if !tasks.isEmpty {
            let sessionId = session.id
            let canStop = !manager.isMirror(sessionId: sessionId)
                && session.backgroundTaskStopSupported && session.agentState == .ready
            ACPBackgroundTaskTray(
                tasks: tasks,
                canStop: canStop,
                expandedOverride: $session.backgroundTrayExpanded,
                stop: { [manager] id in
                    Task { _ = await manager.runners[sessionId]?.stopBackgroundTask(id: id) }
                },
                stopAll: { [manager] in
                    let ids = tasks.filter(\.canStop).map(\.id)
                    Task {
                        for id in ids { _ = await manager.runners[sessionId]?.stopBackgroundTask(id: id) }
                    }
                }
            )
            .padding(.horizontal, 12)
        }
    }

    private var composerRow: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                backgroundTaskTray
                pill
            }
            .frame(maxWidth: contentMaxWidth)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private func composerLayout(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            noticeBanner
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
            if let composerNotice {
                Text(composerNotice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("del"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            if !contextProviders.isEmpty {
                Label("Context from \(contextProviders.joined(separator: ", "))", systemImage: "puzzlepiece.extension")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("fg-muted"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.color("bg-3").opacity(0.85), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("These plugins add text to every prompt you send. The agent sees it; the transcript doesn't.")
            }
            ACPInputField(
                session: session,
                composer: composer,
                worktreeRoot: worktreeRoot,
                actions: actions,
                dropRouter: dropRouter,
                isFocused: $inputFocused,
                focusRequest: focusRequest,
                sendOnEnter: sendOnEnter,
                typography: typography,
                onDraftChange: { draft in
                    manager.persistComposerDraft(draft, for: session)
                    hasText = draft.hasContent
                },
                onDraftClear: { manager.clearComposerDraft(for: session) },
                onStopDictation: { dictation.stop() },
                onSubmit: { text, attachments, intent, draft, completion in
                    dictation.stop()
                    return onSubmit(text, attachments, intent, draft, completion)
                },
                onImageError: { error in
                    composerNotice = error.userMessage
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if composerNotice == error.userMessage { composerNotice = nil }
                    }
                },
                filesProvider: filesProvider,
                nextPromptOffer: nextPromptOffer,
                takeNextPromptOffer: takeNextPromptOffer,
                dismissNextPromptOffer: dismissNextPromptOffer,
                onNextPromptStateChange: onNextPromptStateChange,
                nextPromptInputBlocked: nextPromptInputBlocked,
                nextPromptIsDictating: { dictation.state == .preparing || dictation.state == .listening },
                upstreamReferences: manager.upstreamReferences.store(for: worktreeRoot),
                sessionMentions: sessionMentions,
                symbolMentions: symbolMentions,
                alasCommands: manager.isMirror(sessionId: session.id) || session.readOnlyRestricted
                    ? []
                    : [ACPAlasSlashCommand.btwSuggestion] + pluginPrompts
            )
            .disabled(isMirror)
            .opacity(isMirror ? 0.5 : 1)
            .onChange(of: isMirror) { _, mirror in
                if mirror { dictation.stop() }
            }
            .frame(minHeight: 44, maxHeight: 140)
            .onAppear {
                hasText = composer.draft.hasContent
                dictation.onTranscriptUpdate = { text, isFinal in
                    actions.applyDictationTranscript?(text, isFinal)
                }
                dictation.onStop = { actions.cancelDictationRegion?() }
                dictation.onNotice = { message in
                    composerNotice = message
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if composerNotice == message { composerNotice = nil }
                    }
                }
                dictation.preferredLocaleIdentifier = dictationLocale
            }
            .task {
                installedDictationLocales = await dictation.installedLocaleIdentifiers()
            }
            .onChange(of: dictationLocale) { _, newValue in
                // Settings lives in its own window and can be open next to
                // an actively dictating composer. Without stopping first,
                // a language change made there would leave the running
                // session transcribing under its original locale while the
                // mic menu already shows the new one — mirrors the same
                // guard the mic's own menu applies.
                dictation.stop()
                dictation.preferredLocaleIdentifier = newValue
            }
            .onChange(of: composer.revision) { _, _ in
                hasText = composer.draft.hasContent
            }
            .onChange(of: dictation.state) { _, state in
                guard case .failed(let message) = state else { return }
                composerNotice = message
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if composerNotice == message { composerNotice = nil }
                }
            }

            Group {
                if isMirror {
                    mirrorToolbar
                } else {
                    ViewThatFits(in: .horizontal) {
                        expandedToolbar(showShortcuts: true)
                        expandedToolbar(showShortcuts: false)
                        compactToolbar
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .acpComposerPill(focused: inputFocused)
    }

    private var isMirror: Bool { manager.isMirror(sessionId: session.id) }

    private var mirrorToolbar: some View {
        HStack(spacing: 8) {
            if manager.showsTakeoverBanner(sessionId: session.id) {
                Button {
                    Task { await manager.takeOver(sessionId: session.id) }
                } label: {
                    Text("Take over")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.color("fg"))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(theme.color("bg-3").opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(manager.mirrorIsBusy(sessionId: session.id)
                      ? "Working in another window. Take over here to control this session."
                      : "Open in another window. Take over here to control this session.")
            }
            Spacer(minLength: 0)
            contextUsageButton
            actionButton
                .disabled(true)
                .opacity(0.5)
        }
    }

    private var contextUsageButton: some View {
        ACPContextUsageButton(usage: session.contextUsage,
                              modelName: session.currentModelDisplayName,
                              lastTurnQuota: session.lastTurnQuota,
                              sessionQuotaTotal: session.sessionQuotaTotal)
    }

    private var actionButton: some View {
        ACPComposerActionButton(
            action: currentAction,
            onPrimary: handlePrimary,
            onMenu: handleMenu,
            onSchedule: { actions.submitWithIntent?(.schedule($0)) },
            queueBadgeCount: session.visibleQueueCount,
            queueByDefault: sendOnEnter,
            nativeSteering: session.canSteerRunningTurn
        )
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func expandedToolbar(showShortcuts: Bool) -> some View {
        HStack(spacing: 8) {
            if showShortcuts { shortcutHint }
            Spacer(minLength: 0)
            contextUsageButton
            if dictation.state != .unavailable { micButton }
            attachButton
            chips.fastModeToggle()
            autoRunToggle
            if let thinking = session.chipState.thinking {
                chips.thinkingChip(thinking).fixedSize(horizontal: true, vertical: false)
            }
            ForEach(chips.parameterChips) { parameter in
                chips.parameterChip(parameter).fixedSize(horizontal: true, vertical: false)
            }
            ForEach(chips.booleanConfigOptions) { option in
                chips.booleanConfigToggle(option).fixedSize(horizontal: true, vertical: false)
            }
            if let providerName = session.currentProviderDisplayName {
                providerPill(providerName).fixedSize(horizontal: true, vertical: false)
            }
            if let status = visibleAuthStatus {
                authStatusPill(status).fixedSize(horizontal: true, vertical: false)
            }
            if let mode = session.chipState.mode {
                chips.modeChip(mode).fixedSize(horizontal: true, vertical: false)
            }
            if let models = session.chipState.models {
                chips.modelChip(models).fixedSize(horizontal: true, vertical: false)
            }
            actionButton
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 8) {
            contextUsageButton
            if dictation.state != .unavailable { micButton }
            attachButton
            Spacer(minLength: 0)
            if let models = session.chipState.models {
                chips.modelChip(models)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
            ACPComposerOptionsButton(
                chips: chips,
                autoRun: .init(isEnabled: session.autoRunEnabled, isDisabled: autoRunDisabled,
                               help: autoRunHelp, toggle: toggleAutoRun),
                providerName: session.currentProviderDisplayName,
                authStatus: visibleAuthStatus,
                onOpen: dismissNextPromptOffer
            )
            actionButton
        }
    }

    private var visibleAuthStatus: ACPAuthStatus? {
        guard let status = session.authStatus, status.kind != .none else { return nil }
        return status
    }

    private var shortcutHint: some View {
        HStack(spacing: 6) {
            kbdLabel("⏎")
            Text("send").font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.color("fg-muted"))
            kbdLabel("⇧⏎")
            Text("newline").font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.color("fg-muted"))
        }
        .fixedSize(horizontal: true, vertical: false)
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

    private func providerPill(_ name: String) -> some View {
        Text("Provider: \(name)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.color("fg-muted"))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("bg-3").opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
            .accessibilityLabel("Provider, \(name)")
            .help("Provider selected by the adapter")
    }

    private func authStatusPill(_ status: ACPAuthStatus) -> some View {
        Text(status.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.color("fg-muted"))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("bg-3").opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
            .accessibilityLabel("Signed in, \(status.label)")
            .help(Self.authStatusHoverText(status))
    }

    static func authStatusHoverText(_ status: ACPAuthStatus) -> String {
        var parts: [String] = []
        if let plan = status.account?.plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(plan)
        }
        if let email = status.account?.email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(email)
        }
        if let detail = status.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(detail)
        }
        return parts.isEmpty ? "Auth status reported by the adapter" : parts.joined(separator: " · ")
    }

    // MARK: - Auto-run pill (was in the toolbar)

    private var chips: ACPComposerChips {
        ACPComposerChips(theme: theme, chipState: session.chipState,
                         configOptions: session.availableConfigOptions,
                         onSelect: { apply(spec: $0, selectedId: $1) },
                         onConfigValue: { apply(configOptionId: $0, value: $1) })
    }

    private var autoRunToggle: some View {
        ACPAutoRunToggle(isEnabled: session.autoRunEnabled, isDisabled: autoRunDisabled,
                         help: autoRunHelp, onToggle: toggleAutoRun)
    }

    private func toggleAutoRun() {
        session.autoRunEnabled.toggle()
        manager.persist(session)
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

    private var micButton: some View {
        ACPDictationMicButton(
            dictation: dictation,
            installedLocales: installedDictationLocales,
            selectedLocale: dictationLocale,
            onWillToggle: dismissNextPromptOffer,
            onSelectLocale: onSelectDictationLocale
        )
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

    /// Route chip selections through manager-owned optimistic persistence and
    /// request ordering.
    private func apply(spec: ChipSpec, selectedId: String) {
        let sessionId = session.id
        switch spec.source {
        case .mode:
            manager.enqueueModeSelection(for: sessionId, modeId: selectedId)
        case .model:
            manager.enqueueModelSelection(for: sessionId, modelId: selectedId)
        case .configOption(let id):
            manager.setConfigOption(
                for: sessionId,
                configId: id,
                value: .string(selectedId)
            )
        }
    }

    private func apply(configOptionId id: String, value: ACPConfigValue) {
        manager.setConfigOption(for: session.id, configId: id, value: value)
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
            agentState: session.agentState,
            queueByDefault: sendOnEnter,
            hasCancellableBackgroundWork: session.hasCancellableBackgroundWork
        )
    }

    private func handlePrimary() {
        if let intent = primarySubmitIntent(for: currentAction, optionPressed: optionPressed, queueByDefault: sendOnEnter) {
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
        case .queue:
            actions.submitWithIntent?(.auto)
        case .steer:
            actions.submitWithIntent?(.steer)
        case .stop:
            stopTapped()
        }
    }
}

/// The narrow toolbar's "Options" popover: every chip that no longer fits
/// beside the model picker. Shared with the mirrored peer composer.
struct ACPComposerOptionsButton: View {
    struct AutoRun {
        let isEnabled: Bool
        let isDisabled: Bool
        let help: String
        let toggle: () -> Void
    }

    let chips: ACPComposerChips
    let autoRun: AutoRun
    var providerName: String?
    var authStatus: ACPAuthStatus?
    var onOpen: () -> Void = {}

    @Environment(\.theme) private var theme
    @State private var isPresented = false
    private let controlWidth: CGFloat = 164

    private var items: [ACPComposerOverflowItem] {
        ACPComposerOverflowItem.items(
            hasMode: chips.chipState.mode != nil,
            hasThinking: chips.chipState.thinking != nil,
            hasFastMode: chips.fastModeParameter != nil || chips.fastModeBooleanOption != nil,
            parameterIDs: chips.parameterChips.map(\.id),
            booleanIDs: chips.booleanConfigOptions.map(\.id),
            hasProvider: providerName != nil,
            hasAuthentication: authStatus != nil
        )
    }

    var body: some View {
        Button {
            onOpen()
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                if autoRun.isEnabled {
                    Circle()
                        .fill(theme.color("caution"))
                        .frame(width: 5, height: 5)
                }
                Text("Options")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(theme.color("fg"))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("bg-3")))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help("Session options")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Session settings")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.color("fg-muted"))
                        .padding(.bottom, 3)
                    ForEach(items, id: \.self) { item in
                        row(item)
                    }
                }
                .padding(12)
            }
            .frame(width: 310)
            .frame(maxHeight: 370)
            .background(theme.color("bg-1"))
        }
    }

    @ViewBuilder
    private func row(_ item: ACPComposerOverflowItem) -> some View {
        switch item {
        case .mode:
            if let mode = chips.chipState.mode {
                selectRow("Mode", spec: mode, accent: chips.modeAccent(mode))
            }
        case .thinking:
            if let thinking = chips.chipState.thinking {
                selectRow("Thinking", spec: thinking, accent: theme.color("warn"))
            }
        case .fastMode:
            fastModeRow
        case .autoRun:
            toggleRow(
                "Auto-run",
                isEnabled: autoRun.isEnabled,
                icon: ACPComposerControlPresentation.autoRunIconName(isEnabled: autoRun.isEnabled),
                foreground: ACPAutoRunToggle.foreground(isEnabled: autoRun.isEnabled, theme: theme),
                background: ACPAutoRunToggle.background(isEnabled: autoRun.isEnabled, theme: theme),
                border: ACPAutoRunToggle.border(isEnabled: autoRun.isEnabled, theme: theme),
                isDisabled: autoRun.isDisabled,
                help: autoRun.help,
                action: autoRun.toggle
            )
        case .parameter(let id):
            if let parameter = chips.parameterChips.first(where: { $0.id == id }) {
                selectRow(parameter.label, spec: parameter.spec, accent: theme.color("fg-muted"))
            }
        case .boolean(let id):
            if let option = chips.booleanConfigOptions.first(where: { $0.id == id }) {
                toggleRow(
                    option.name.isEmpty ? option.id : option.name,
                    isEnabled: option.currentBoolValue == true,
                    icon: option.currentBoolValue == true ? "checkmark.circle.fill" : "circle",
                    foreground: theme.color("fg-muted"),
                    background: theme.color("bg-3").opacity(0.7),
                    border: theme.color("line"),
                    action: { chips.onConfigValue(option.id, .boolean(option.currentBoolValue != true)) }
                )
            }
        case .provider:
            if let providerName {
                infoRow("Provider", value: providerName)
            }
        case .authentication:
            if let authStatus {
                infoRow("Sign-in", value: authStatus.label)
                    .help(ACPComposer.authStatusHoverText(authStatus))
            }
        }
    }

    private func selectRow(_ title: String, spec: ChipSpec, accent: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            chips.chip(spec: spec,
                 label: chips.selectedName(spec: spec, fallback: title),
                 placeholder: title,
                 accent: accent,
                 fillsWidth: true)
                .frame(width: controlWidth)
        }
        .frame(height: 24)
        .font(.system(size: 11, weight: .medium))
    }

    @ViewBuilder
    private var fastModeRow: some View {
        if let parameter = chips.fastModeParameter {
            toggleRow(
                "Fast mode",
                isEnabled: chips.isFastModeEnabled(parameter.spec),
                icon: ACPComposerControlPresentation.fastModeIconName(isEnabled: chips.isFastModeEnabled(parameter.spec)),
                foreground: chips.fastModeFg(isEnabled: chips.isFastModeEnabled(parameter.spec)),
                background: chips.fastModeBg(isEnabled: chips.isFastModeEnabled(parameter.spec)),
                border: chips.fastModeBorder(isEnabled: chips.isFastModeEnabled(parameter.spec)),
                isDisabled: chips.fastModeToggleTarget(for: parameter.spec) == nil,
                help: chips.fastModeHelp(isEnabled: chips.isFastModeEnabled(parameter.spec),
                                   canToggle: chips.fastModeToggleTarget(for: parameter.spec) != nil)
            ) {
                guard let targetId = chips.fastModeToggleTarget(for: parameter.spec) else { return }
                chips.onSelect(parameter.spec, targetId)
            }
        } else if let option = chips.fastModeBooleanOption {
            toggleRow(
                "Fast mode",
                isEnabled: option.currentBoolValue == true,
                icon: ACPComposerControlPresentation.fastModeIconName(isEnabled: option.currentBoolValue == true),
                foreground: chips.fastModeFg(isEnabled: option.currentBoolValue == true),
                background: chips.fastModeBg(isEnabled: option.currentBoolValue == true),
                border: chips.fastModeBorder(isEnabled: option.currentBoolValue == true),
                help: chips.fastModeHelp(isEnabled: option.currentBoolValue == true, canToggle: true)
            ) {
                chips.onConfigValue(option.id, .boolean(option.currentBoolValue != true))
            }
        }
    }

    private func toggleRow(
        _ title: String,
        isEnabled: Bool,
        icon: String,
        foreground: Color,
        background: Color,
        border: Color,
        isDisabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text(isEnabled ? "On" : "Off")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, 8)
                .frame(width: controlWidth, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(background))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(isEnabled ? "On" : "Off")")
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1)
            .help(help ?? title)
        }
        .frame(height: 24)
        .font(.system(size: 11, weight: .medium))
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
        }
        .frame(height: 24)
        .font(.system(size: 11, weight: .medium))
    }
}

/// The floating pill that frames the composer: tinted gradient under a
/// material, hairline border that warms when focused, and a soft drop
/// shadow. Shared with the mirrored peer composer.
struct ACPComposerPillChrome: ViewModifier {
    let focused: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background {
                // Two layered BACKGROUNDS — both sit behind the content. An
                // earlier version put the dark gradient as `.overlay`, which
                // painted it OVER the chips and text and washed them out.
                // Material goes closest to the content; the tint sits
                // behind it.
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
                    .strokeBorder(
                        focused ? theme.color("add").opacity(0.7) : theme.color("line"),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }
}

extension View {
    func acpComposerPill(focused: Bool) -> some View {
        modifier(ACPComposerPillChrome(focused: focused))
    }
}
