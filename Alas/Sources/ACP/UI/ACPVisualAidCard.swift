import AppKit
import Combine
import SwiftUI

/// What a visual aid card can ask its host to do.
struct ACPVisualAidActions {
    /// True once the answer is stored; the prompt is sent in the background and
    /// a failed send clears the answer on the transcript again.
    var answer: (UUID, ACPVisualAid.Answer) async -> Bool
    var popOut: (ACPVisualAid) -> Void
    var popOutLabel = "Open in a tab"
    /// False for visuals the tab cannot look up, such as ```` ```visual ```` fences in a message.
    var canPopOut = true
    /// True while this process may answer. Read live on every render and every action, never captured
    /// as a value: the rows that show a card are not re-created when writer ownership changes.
    var canAnswer: () -> Bool
    /// Fires when the host's state may have changed; the card re-reads `canAnswer`.
    var changes: AnyPublisher<Void, Never>

    /// For hosts that only display transcripts.
    static var readOnly: Self {
        .init(
            answer: { _, _ in false }, popOut: { _ in }, canAnswer: { false },
            changes: Empty(completeImmediately: false).eraseToAnyPublisher())
    }

    /// For a ```` ```visual ```` fence drawn inside a message: it asks nothing and has no stored copy to pop out.
    static var fenced: Self {
        var actions = readOnly
        actions.canPopOut = false
        return actions
    }

    /// Answers go through `manager`, and only while this process drives `session` (the same
    /// `isMirror` source the composer and the other callbacks use); a mirror shows the question read-only.
    @MainActor
    static func driven(
        by manager: ACPSessionManager, session: ACPSession, popOut: @escaping (ACPVisualAid) -> Void
    ) -> Self {
        let sessionId = session.id
        return .init(
            answer: { [manager] visualId, answer in
                await manager.answerVisualAid(id: visualId, answer: answer, in: sessionId)
            },
            popOut: popOut,
            canAnswer: { [manager] in !manager.isMirror(sessionId: sessionId) },
            // `objectWillChange` fires before the change lands, so hop to the next main-queue turn to re-read.
            changes: Publishers.Merge(manager.objectWillChange, session.objectWillChange)
                .map { _ in () }
                .receive(on: DispatchQueue.main)
                .eraseToAnyPublisher())
    }
}

/// A visual aid in the transcript (or filling a pop-out tab): the sandboxed
/// page plus, when it asks one, the native question card. An embedded visual
/// in the transcript drops the card: it is just the page, part of the reply.
struct ACPVisualAidCard: View {
    @Environment(\.designScale) private var scale
    let visual: ACPVisualAid
    let form: ACPUserInputFormState?
    let sendStatus: ACPVisualAidSendStatus
    let actions: ACPVisualAidActions
    var fillsHeight = false
    /// The transcript's font, which the page inherits through its layout variables.
    var typography: ACPChatTypography = .default

    @State private var canAnswer: Bool
    @Environment(\.theme) private var theme
    @State private var slot = UUID()
    @State private var page: VisualAidWebPage?
    @State private var paused = false
    /// The page's height when the budget paused it, which keeps the row steady while paused. The picture
    /// itself stays in `VisualAidSnapshotStore`, whose limits would mean nothing if each card held one.
    @State private var savedHeight: CGFloat?
    @State private var sending = false
    @State private var hovered = false
    /// VoiceOver and keyboard users never hover, so for them the embedded actions stay visible.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    init(
        visual: ACPVisualAid, form: ACPUserInputFormState?, sendStatus: ACPVisualAidSendStatus,
        actions: ACPVisualAidActions, fillsHeight: Bool = false, typography: ACPChatTypography = .default
    ) {
        self.visual = visual
        self.form = form
        self.sendStatus = sendStatus
        self.actions = actions
        self.fillsHeight = fillsHeight
        self.typography = typography
        _canAnswer = State(initialValue: actions.canAnswer())
    }

    /// The pop-out tab keeps the card for every visual.
    private var isEmbedded: Bool { visual.presentation == .embedded && !fillsHeight }

    private var layoutVariables: [String: String] {
        VisualAidWebPolicy.layoutVariables(fontFamily: typography.fontFamily, fontSize: typography.paragraphSize)
    }

    var body: some View {
        content
            .onAppear(perform: openPage)
            .onDisappear(perform: closePage)
            .onChange(of: theme) { page?.applyTheme(theme, layoutVariables: layoutVariables) }
            .onChange(of: typography) { page?.applyTheme(theme, layoutVariables: layoutVariables) }
            .onReceive(actions.changes) { canAnswer = actions.canAnswer() }
            .onChange(of: canAnswer) { installChoiceHandler() }
            .onChange(of: page?.status) { syncSelection() }
            .onChange(of: form?.selectionValues[ACPVisualAidQuestionForm.choiceKey]) { syncSelection() }
            .onChange(of: visual.answer) {
                installChoiceHandler()
                syncSelection()
            }
    }

    @ViewBuilder private var content: some View {
        if isEmbedded {
            embedded
        } else {
            card
        }
    }

    /// No header, frame or background: the page sits in the prose column, and Copy HTML and
    /// Open in a tab appear over its top-trailing corner while the row is hovered.
    private var embedded: some View {
        embeddedSurface
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                let visible = hovered || voiceOverEnabled || NSApp.isFullKeyboardAccessEnabled
                HStack(spacing: scale.space[1]) {
                    overlayButton("doc.on.doc", help: "Copy HTML", action: copyHTML)
                    if actions.canPopOut {
                        overlayButton("arrow.up.forward.square", help: actions.popOutLabel) { actions.popOut(visual) }
                    }
                }
                .padding(scale.space[2])
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .animation(.easeOut(duration: 0.12), value: visible)
            }
            .acpRowHover { hovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(visual.title)
    }

    @ViewBuilder private var embeddedSurface: some View {
        if let page {
            switch page.status {
            case .sandboxFailed:
                embeddedPlaceholder("Couldn't set up the visual's sandbox")
            case .stopped(let canReload):
                embeddedPlaceholder("Visual stopped", button: canReload ? ("Reload", { page.reload() }) : nil)
            case .loading, .ready:
                VisualAidWebSurface(webView: page.webView)
                    .frame(height: VisualAidWebPolicy.contentHeight(
                        forContentHeight: page.contentHeight, presentation: .embedded))
            }
        } else if let snapshot = pausedSnapshotImage {
            pausedSnapshot(snapshot)
        } else {
            embeddedPlaceholder(
                paused ? "Visual paused to save memory" : "Visual not loaded", button: ("Show visual", openPage),
                minHeight: pausedHeight.map { VisualAidWebPolicy.contentHeight(forContentHeight: $0, presentation: .embedded) })
        }
    }

    /// A paused page's last picture. Clicking it makes the page live again, which may pause another.
    private func pausedSnapshot(_ image: NSImage) -> some View {
        Button(action: openPage) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: image.size.width, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Paused to save memory. Click to make it interactive.")
        .accessibilityLabel("\(visual.title), paused")
        .accessibilityHint("Makes the visual interactive")
    }

    private func embeddedPlaceholder(
        _ text: String, button: (String, () -> Void)? = nil, minHeight: CGFloat? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            Text(text).foregroundStyle(theme.color("fg-muted"))
            if let button {
                Button(button.0, action: button.1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(minHeight ?? 0, VisualAidWebPolicy.minCardHeight), alignment: .leading)
    }

    /// Styled like the transcript code block's copy button.
    private func overlayButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: typography.labelSize))
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[1])
                .background(theme.color("bg-3").opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                .overlay(RoundedRectangle(cornerRadius: scale.radius.small).strokeBorder(theme.color("line"), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            surface
                .frame(height: fillsHeight ? nil : VisualAidWebPolicy.contentHeight(
                    forContentHeight: page?.contentHeight ?? pausedHeight ?? VisualAidWebPolicy.minCardHeight,
                    presentation: .card))
                .frame(maxHeight: fillsHeight ? .infinity : nil)
            if let question = visual.question {
                Divider()
                questionArea(question)
            }
        }
        .background(theme.color("bg-1"))
        .clipShape(.rect(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(theme.color("accent"))
            Text(visual.title)
                .font(scale.meta.font(weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: copyHTML) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy HTML")
            if !fillsHeight && actions.canPopOut {
                Button { actions.popOut(visual) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help(actions.popOutLabel)
            }
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
    }

    @ViewBuilder private var surface: some View {
        if let page {
            switch page.status {
            case .sandboxFailed:
                placeholder("Couldn't set up the visual's sandbox")
            case .stopped(let canReload):
                placeholder("Visual stopped", button: canReload ? ("Reload", { page.reload() }) : nil)
            case .loading, .ready:
                VisualAidWebSurface(webView: page.webView)
            }
        } else if let snapshot = pausedSnapshotImage {
            pausedSnapshot(snapshot)
        } else {
            placeholder(paused ? "Visual paused to save memory" : "Visual not loaded", button: ("Show visual", openPage))
        }
    }

    private func placeholder(_ text: String, button: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: scale.space[2]) {
            Text(text).foregroundStyle(theme.color("fg-muted"))
            if let button {
                Button(button.0, action: button.1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func questionArea(_ question: ACPVisualAid.Question) -> some View {
        switch visual.answer {
        case .answered(let ids, let note, _):
            let labels = Dictionary(uniqueKeysWithValues: question.options.map { ($0.id, $0.label) })
            VStack(alignment: .leading, spacing: scale.space[1]) {
                Text("Answered: " + ids.map { "\($0), \(labels[$0] ?? $0)" }.joined(separator: "; "))
                if let note { Text("Note: \(note)").foregroundStyle(theme.color("fg-muted")) }
            }
            .font(.callout)
            .padding(scale.space[3])
        case .dismissed:
            Text("Dismissed").font(.callout).foregroundStyle(theme.color("fg-muted")).padding(scale.space[3])
        case nil:
            if !ACPVisualAidQuestionForm.isEditable(answer: visual.answer, canAnswer: canAnswer) {
                readOnlyQuestion(question)
            } else if let form {
                VStack(alignment: .leading, spacing: scale.space[2]) {
                    ACPUserInputPrompt(
                        formState: form,
                        onRespond: { _, action in respond(action, question: question) },
                        onOpenURL: { _ in false },
                        headerLabel: "Question"
                    )
                    .disabled(sending)
                    if let sendError = sendStatus.error {
                        Text(sendError).font(.callout).foregroundStyle(theme.color("del"))
                    }
                }
                .padding(scale.space[2])
            }
        }
    }

    /// A mirror cannot answer, so it shows what is asked and where to answer instead of the form.
    private func readOnlyQuestion(_ question: ACPVisualAid.Question) -> some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            Text(question.prompt).font(.callout.weight(.semibold))
            ForEach(question.options, id: \.id) { option in
                Text("• " + option.label)
            }
            Text("Answer from the window that owns this session.").foregroundStyle(theme.color("fg-muted"))
        }
        .font(.callout)
        .padding(scale.space[3])
    }

    private func respond(_ action: ACPUserInputAction, question: ACPVisualAid.Question) {
        let answer: ACPVisualAid.Answer
        switch action {
        case .submit(let content):
            guard let answered = ACPVisualAidQuestionForm.answer(from: content, question: question, at: Date()) else { return }
            answer = answered
        case .decline, .cancel:
            answer = .dismissed(at: Date())
        }
        guard !sending, actions.canAnswer() else { return }
        sending = true
        sendStatus.error = nil
        let visualID = visual.id
        Task {
            let stored = await actions.answer(visualID, answer)
            sending = false
            if !stored { sendStatus.error = ACPVisualAidSendStatus.failureMessage }
        }
    }

    /// The pop-out tab fills its own height and has no transcript row to keep steady.
    private var usesSnapshots: Bool { !fillsHeight }

    private var pausedHeight: CGFloat? { paused && usesSnapshots ? savedHeight : nil }

    /// The paused page's picture, only in the theme it was drawn in.
    private var pausedSnapshotImage: NSImage? {
        guard paused, usesSnapshots else { return nil }
        return VisualAidSnapshotStore.shared.image(for: visual.id, theme: theme)
    }

    private func openPage() {
        guard page == nil else { return }
        let page = VisualAidWebPage(
            visualID: visual.id, html: visual.html, theme: theme, layoutVariables: layoutVariables,
            initialHeight: usesSnapshots ? VisualAidSnapshotStore.shared.entry(for: visual.id)?.height : nil,
            locksNetworkAfterLoad: visual.question != nil, presentation: isEmbedded ? .embedded : .card)
        self.page = page
        paused = false
        installChoiceHandler()
        let pageBinding = $page
        let pausedBinding = $paused
        let savedHeightBinding = $savedHeight
        let visualID = visual.id
        let usesSnapshots = usesSnapshots
        VisualAidPageBudget.shared.admit(slot) {
            // The budget has already let this slot go; the picture is taken before the page closes, and
            // only if a later open or close has not replaced the page meanwhile.
            Task { @MainActor in
                if usesSnapshots {
                    let captured = await page.snapshot()
                    savedHeightBinding.wrappedValue = VisualAidSnapshotStore.shared.record(
                        visualID, height: page.contentHeight, image: captured?.image, theme: captured?.theme ?? page.theme
                    ).height
                }
                page.close()
                guard pageBinding.wrappedValue === page else { return }
                pageBinding.wrappedValue = nil
                pausedBinding.wrappedValue = true
            }
        }
    }

    private func closePage() {
        if let page, usesSnapshots, page.status == .ready {
            VisualAidSnapshotStore.shared.record(visual.id, height: page.contentHeight, image: nil, theme: page.theme)
        }
        page?.close()
        page = nil
        VisualAidPageBudget.shared.release(slot)
    }

    /// Page clicks edit the native form only while the question is open and this process may answer it,
    /// and links open only once it is not.
    private func installChoiceHandler() {
        guard let page else { return }
        page.externalLinksEnabled = RemoteVisualAidWebPolicy.allowsExternalLinks(
            hasQuestion: visual.question != nil, answer: visual.answer)
        guard ACPVisualAidQuestionForm.isEditable(answer: visual.answer, canAnswer: canAnswer), let form else {
            page.onChoice = { _ in }
            return
        }
        page.onChoice = { [actions] choice in
            guard actions.canAnswer(), let field = ACPVisualAidQuestionForm.choiceField(for: choice, in: form.request) else { return }
            form.toggle(choice, for: field)
        }
    }

    private func syncSelection() {
        guard let page else { return }
        if case .answered(let ids, _, _) = visual.answer {
            page.setSelected(ids)
        } else {
            page.setSelected(Array(form?.selectionValues[ACPVisualAidQuestionForm.choiceKey] ?? []))
        }
    }

    private func copyHTML() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visual.html, forType: .string)
    }
}
