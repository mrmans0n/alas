import SwiftUI

enum ACPComposerControlPresentation {
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

    @Environment(\.theme) private var theme
    @State private var inputFocused = false
    @State private var hasText: Bool = false
    @State private var composerNotice: String?
    @State private var showingCompactOptions = false
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
        self.onSubmit = onSubmit
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

    private var composerRow: some View {
        HStack {
            Spacer(minLength: 0)
            pill.frame(maxWidth: contentMaxWidth)
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
                filesProvider: filesProvider
            )
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
                // guard `selectDictationLocale` applies for changes made
                // through the mic's own menu.
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

            ViewThatFits(in: .horizontal) {
                expandedToolbar
                compactToolbar
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
            queueBadgeCount: session.visibleQueueCount
        )
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private var expandedToolbar: some View {
        HStack(spacing: 8) {
            hint
            Spacer(minLength: 0)
            contextUsageButton
            if dictation.state != .unavailable { micButton }
            attachButton
            if let fastMode = fastModeParameter {
                selectFastModeToggle(fastMode)
            } else if let fastMode = fastModeBooleanOption {
                booleanFastModeToggle(fastMode)
            }
            autoRunToggle
            if let thinking = session.chipState.thinking {
                thinkingChip(thinking).fixedSize(horizontal: true, vertical: false)
            }
            ForEach(parameterChips) { parameter in
                parameterChip(parameter).fixedSize(horizontal: true, vertical: false)
            }
            ForEach(booleanConfigOptions) { option in
                booleanConfigToggle(option).fixedSize(horizontal: true, vertical: false)
            }
            if let providerName = session.currentProviderDisplayName {
                providerPill(providerName).fixedSize(horizontal: true, vertical: false)
            }
            if let status = visibleAuthStatus {
                authStatusPill(status).fixedSize(horizontal: true, vertical: false)
            }
            if let mode = session.chipState.mode {
                modeChip(mode).fixedSize(horizontal: true, vertical: false)
            }
            if let models = session.chipState.models {
                modelChip(models).fixedSize(horizontal: true, vertical: false)
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
                modelChip(models)
                    .frame(maxWidth: 160)
            }
            compactOptionsButton
            actionButton
        }
    }

    private var visibleAuthStatus: ACPAuthStatus? {
        guard let status = session.authStatus, status.kind != .none else { return nil }
        return status
    }

    private var overflowItems: [ACPComposerOverflowItem] {
        ACPComposerOverflowItem.items(
            hasMode: session.chipState.mode != nil,
            hasThinking: session.chipState.thinking != nil,
            hasFastMode: fastModeParameter != nil || fastModeBooleanOption != nil,
            parameterIDs: parameterChips.map(\.id),
            booleanIDs: booleanConfigOptions.map(\.id),
            hasProvider: session.currentProviderDisplayName != nil,
            hasAuthentication: visibleAuthStatus != nil
        )
    }

    private var compactOptionsButton: some View {
        Button {
            showingCompactOptions.toggle()
        } label: {
            HStack(spacing: 6) {
                if session.autoRunEnabled {
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
        .popover(isPresented: $showingCompactOptions, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Session settings")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.color("fg-muted"))
                        .padding(.bottom, 3)
                    ForEach(overflowItems, id: \.self) { item in
                        compactOptionRow(item)
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
    private func compactOptionRow(_ item: ACPComposerOverflowItem) -> some View {
        switch item {
        case .mode:
            if let mode = session.chipState.mode {
                compactSelectRow("Mode", spec: mode, accent: theme.color("accent"))
            }
        case .thinking:
            if let thinking = session.chipState.thinking {
                compactSelectRow("Thinking", spec: thinking, accent: theme.color("warn"))
            }
        case .fastMode:
            compactFastModeRow
        case .autoRun:
            HStack {
                Text("Auto-run")
                Spacer(minLength: 8)
                Button(session.autoRunEnabled ? "On" : "Off", action: toggleAutoRun)
                    .disabled(autoRunDisabled)
                    .help(autoRunHelp)
            }
        case .parameter(let id):
            if let parameter = parameterChips.first(where: { $0.id == id }) {
                compactSelectRow(parameter.label, spec: parameter.spec, accent: theme.color("fg-muted"))
            }
        case .boolean(let id):
            if let option = booleanConfigOptions.first(where: { $0.id == id }) {
                booleanConfigToggle(option)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .provider:
            if let name = session.currentProviderDisplayName {
                compactInfoRow("Provider", value: name)
            }
        case .authentication:
            if let status = visibleAuthStatus {
                compactInfoRow("Sign-in", value: status.label)
                    .help(authStatusHoverText(status))
            }
        }
    }

    private func compactSelectRow(_ title: String, spec: ChipSpec, accent: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            chip(spec: spec,
                 label: selectedName(spec: spec, fallback: title),
                 placeholder: title,
                 accent: accent)
                .frame(maxWidth: 170)
        }
        .font(.system(size: 11, weight: .medium))
    }

    @ViewBuilder
    private var compactFastModeRow: some View {
        if let parameter = fastModeParameter {
            HStack {
                Text("Fast mode")
                Spacer(minLength: 8)
                Button(isFastModeEnabled(parameter.spec) ? "On" : "Off") {
                    guard let targetId = fastModeToggleTarget(for: parameter.spec) else { return }
                    apply(spec: parameter.spec, selectedId: targetId)
                }
                .disabled(fastModeToggleTarget(for: parameter.spec) == nil)
            }
        } else if let option = fastModeBooleanOption {
            HStack {
                Text("Fast mode")
                Spacer(minLength: 8)
                Button(option.currentBoolValue == true ? "On" : "Off") {
                    apply(configOptionId: option.id, value: .boolean(option.currentBoolValue != true))
                }
            }
        }
    }

    private func compactInfoRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
    }

    private var hint: some View {
        ViewThatFits(in: .horizontal) {
            hintContent(showShortcuts: true)
            hintContent(showShortcuts: false)
        }
    }

    private func hintContent(showShortcuts: Bool) -> some View {
        HStack(spacing: 6) {
            if showShortcuts {
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
            .help(authStatusHoverText(status))
    }

    private func authStatusHoverText(_ status: ACPAuthStatus) -> String {
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

    private var borderColor: Color {
        inputFocused ? theme.color("add").opacity(0.7) : theme.color("line")
    }

    // MARK: - Auto-run pill (was in the toolbar)

    private var autoRunToggle: some View {
        Button(action: toggleAutoRun) {
            Image(systemName: ACPComposerControlPresentation.autoRunIconName(isEnabled: session.autoRunEnabled))
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

    private var micButton: some View {
        Button {
            dictation.toggle()
        } label: {
            Image(systemName: ACPComposerControlPresentation.micIconName(for: dictation.state))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    dictation.state == .listening
                        ? Color.blend(theme.color("caution"), .white, t: 0.55)
                        : theme.color("fg-muted")
                )
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            dictation.state == .listening
                                ? theme.color("caution").opacity(0.55)
                                : theme.color("bg-3").opacity(0.7)
                        )
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictate")
        .help(ACPComposerControlPresentation.micHelp(for: dictation.state))
        .contextMenu {
            ForEach(ACPComposerControlPresentation.dictationMenuItems(
                installed: installedDictationLocales,
                selected: dictationLocale
            )) { item in
                Button {
                    selectDictationLocale(item.localeIdentifier)
                } label: {
                    // A checkmark prefix rather than a Toggle: these are
                    // mutually exclusive and Toggle rows in a context menu
                    // read as independently switchable.
                    Text(item.isSelected ? "✓ \(item.title)" : item.title)
                }
            }
        }
    }

    /// Applies a language picked from the mic's menu. Any active dictation
    /// stops first, so a session never keeps running under a language the
    /// menu no longer shows as current.
    private func selectDictationLocale(_ identifier: String) {
        dictation.stop()
        onSelectDictationLocale(identifier)
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

    private func selectFastModeToggle(_ parameter: ACPParameterChip) -> some View {
        Button {
            guard let targetId = fastModeToggleTarget(for: parameter.spec) else { return }
            apply(spec: parameter.spec, selectedId: targetId)
        } label: {
            fastModeIcon(isEnabled: isFastModeEnabled(parameter.spec))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fast mode")
        .disabled(fastModeToggleTarget(for: parameter.spec) == nil)
        .opacity(fastModeToggleTarget(for: parameter.spec) == nil ? 0.5 : 1.0)
        .help(fastModeHelp(isEnabled: isFastModeEnabled(parameter.spec),
                           canToggle: fastModeToggleTarget(for: parameter.spec) != nil))
    }

    private func booleanFastModeToggle(_ option: ACPConfigOption) -> some View {
        let isEnabled = option.currentBoolValue ?? false
        return Button {
            apply(configOptionId: option.id, value: .boolean(!isEnabled))
        } label: {
            fastModeIcon(isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fast mode")
        .help(fastModeHelp(isEnabled: isEnabled, canToggle: true))
    }

    private func fastModeIcon(isEnabled: Bool) -> some View {
        Image(systemName: ACPComposerControlPresentation.fastModeIconName(isEnabled: isEnabled))
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(fastModeFg(isEnabled: isEnabled))
            .frame(width: 28, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(fastModeBg(isEnabled: isEnabled))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(fastModeBorder(isEnabled: isEnabled), lineWidth: 0.75)
            )
    }

    private func fastModeHelp(isEnabled: Bool, canToggle: Bool) -> String {
        ACPComposerControlPresentation.fastModeHelp(isEnabled: isEnabled, canToggle: canToggle)
    }

    private var fastModeParameter: ACPParameterChip? {
        session.chipState.parameters.first {
            $0.presentation == .fastMode
                && ACPComposerControlPresentation.canRenderFastModeButton(for: $0.spec)
        }
    }

    private var fastModeBooleanOption: ACPConfigOption? {
        session.availableConfigOptions.first {
            $0.type == "boolean"
                && $0.currentBoolValue != nil
                && ACPChipState.isFastModeConfigOption($0)
        }
    }

    private var parameterChips: [ACPParameterChip] {
        session.chipState.parameters.filter {
            $0.presentation != .fastMode
                || !ACPComposerControlPresentation.canRenderFastModeButton(for: $0.spec)
        }
    }

    private func fastModeToggleTarget(for spec: ChipSpec) -> String? {
        ACPComposerControlPresentation.fastModeToggleTarget(for: spec)
    }

    private func isFastModeEnabled(_ spec: ChipSpec) -> Bool {
        ACPComposerControlPresentation.isFastModeEnabled(spec)
    }

    private func fastModeBg(_ spec: ChipSpec) -> Color {
        fastModeBg(isEnabled: isFastModeEnabled(spec))
    }

    private func fastModeBg(isEnabled: Bool) -> Color {
        isEnabled
            ? cursorFastAccent.opacity(0.20)
            : theme.color("bg-3").opacity(0.7)
    }

    private func fastModeBorder(_ spec: ChipSpec) -> Color {
        fastModeBorder(isEnabled: isFastModeEnabled(spec))
    }

    private func fastModeBorder(isEnabled: Bool) -> Color {
        isEnabled
            ? cursorFastAccent.opacity(0.55)
            : theme.color("line")
    }

    private func fastModeFg(_ spec: ChipSpec) -> Color {
        fastModeFg(isEnabled: isFastModeEnabled(spec))
    }

    private func fastModeFg(isEnabled: Bool) -> Color {
        isEnabled
            ? Color.blend(cursorFastAccent, .white, t: 0.45)
            : theme.color("fg-muted")
    }

    // MARK: - Chip builders driven by ACPChipState

    private func modeChip(_ spec: ChipSpec) -> some View {
        let currentKind = spec.options.first(where: { $0.id == spec.currentId })?.kind
        return chip(spec: spec,
             label: chipLabel(prefix: "Mode", spec: spec),
             placeholder: "Mode",
             // `fullAccess` (bypassPermissions / agent-full-access) bypasses
             // per-action approval, so the chip switches to the warning
             // tint as a passive heads-up. Every other kind — including no
             // kind at all — keeps the standard accent.
             accent: currentKind == .fullAccess ? theme.color("warn") : theme.color("accent"))
    }

    private func thinkingChip(_ spec: ChipSpec) -> some View {
        chip(spec: spec,
             label: iconChipLabel(icon: "🧠", spec: spec, fallback: "Thinking"),
             placeholder: "Thinking",
             accent: theme.color("warn"))
    }

    private func modelChip(_ spec: ChipSpec) -> some View {
        chip(spec: spec,
             label: spec.options.first(where: { $0.id == spec.currentId })?.name
                    ?? spec.currentId
                    ?? "Model",
             placeholder: "Model",
             accent: theme.color("syntax-keyword"),
             searchDescriptions: false,
             searchIdentifiers: false)
    }

    @ViewBuilder
    private func parameterChip(_ parameter: ACPParameterChip) -> some View {
        switch parameter.presentation {
        case .cursorContextWindow:
            chip(spec: parameter.spec,
                 label: iconChipLabel(icon: "🪟", spec: parameter.spec, fallback: parameter.label),
                 placeholder: parameter.label,
                 accent: cursorContextAccent)
        case .fastMode:
            chip(spec: parameter.spec,
                 label: chipLabel(prefix: parameter.label, spec: parameter.spec),
                 placeholder: parameter.label,
                 accent: cursorFastAccent)
        case .standard:
            chip(spec: parameter.spec,
                 label: chipLabel(prefix: parameter.label, spec: parameter.spec),
                 placeholder: parameter.label,
                 accent: theme.color("fg-muted"))
        }
    }

    private var cursorContextAccent: Color {
        Color(.sRGB, red: 0.28, green: 0.72, blue: 0.88, opacity: 1)
    }

    private var cursorFastAccent: Color {
        Color(.sRGB, red: 0.48, green: 0.82, blue: 0.42, opacity: 1)
    }

    private var booleanConfigOptions: [ACPConfigOption] {
        session.availableConfigOptions.filter {
            $0.type == "boolean" && $0.currentBoolValue != nil
                && !ACPChipState.isFastModeConfigOption($0)
        }
    }

    private func booleanConfigToggle(_ option: ACPConfigOption) -> some View {
        Toggle(isOn: Binding(
            get: { option.currentBoolValue ?? false },
            set: { apply(configOptionId: option.id, value: .boolean($0)) }
        )) {
            Text(option.name.isEmpty ? option.id : option.name)
                .font(.system(size: 11, weight: .medium))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(option.name.isEmpty ? option.id : option.name)
    }

    private func iconChipLabel(icon: String, spec: ChipSpec, fallback: String) -> String {
        "\(icon) \(selectedName(spec: spec, fallback: fallback))"
    }

    private func selectedName(spec: ChipSpec, fallback: String) -> String {
        if let id = spec.currentId,
           let item = spec.options.first(where: { $0.id == id }) {
            return item.name
        }
        return spec.currentId ?? fallback
    }

    private func chip(spec: ChipSpec,
                      label: String,
                      placeholder: String,
                      accent: Color,
                      searchDescriptions: Bool = true,
                      searchIdentifiers: Bool = true) -> some View {
        ACPSelectChip(
            label: label,
            placeholder: placeholder,
            accent: accent,
            items: spec.options.map {
                ACPSelectChip.Item(
                    id: $0.id, name: $0.name, description: $0.description,
                    iconSystemName: $0.kind?.iconSystemName)
            },
            selectedId: spec.currentId,
            searchDescriptions: searchDescriptions,
            searchIdentifiers: searchIdentifiers,
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
        if case .configOption(let id) = spec.source {
            manager.setConfigOption(
                for: session.id,
                configId: id,
                value: .string(selectedId)
            )
            return
        }

        let sid = session.id
        let remoteId = session.remoteSessionId ?? sid
        switch spec.source {
        case .mode:
            session.currentMode = selectedId
        case .model:
            session.currentModel = selectedId
        case .configOption:
            return
        }
        manager.persist(session)

        Task { @MainActor in
            guard let runner = manager.runners[sid] else {
                switch spec.source {
                case .mode: manager.pendingMode[sid] = selectedId
                case .model: manager.pendingModel[sid] = selectedId
                case .configOption: break
                }
                return
            }
            switch spec.source {
            case .mode:
                try? await runner.connection.setMode(sessionId: remoteId, modeId: selectedId)
            case .model:
                try? await runner.connection.setModel(sessionId: remoteId, modelId: selectedId)
            case .configOption:
                break
            }
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
