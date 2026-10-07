import AppKit
import Combine
import SwiftUI

/// What a visual aid card can ask its host to do.
struct ACPVisualAidActions {
    /// True once the answer is stored; the prompt is sent in the background and
    /// a failed send clears the answer on the transcript again.
    var answer: (UUID, ACPVisualAid.Answer) async -> Bool
    var popOut: (ACPVisualAid) -> Void
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
/// page plus, when it asks one, the native question card.
struct ACPVisualAidCard: View {
    let visual: ACPVisualAid
    let form: ACPUserInputFormState?
    let sendStatus: ACPVisualAidSendStatus
    let actions: ACPVisualAidActions
    var fillsHeight = false

    @State private var canAnswer: Bool
    @Environment(\.theme) private var theme
    @State private var slot = UUID()
    @State private var page: VisualAidWebPage?
    @State private var paused = false
    @State private var sending = false

    init(
        visual: ACPVisualAid, form: ACPUserInputFormState?, sendStatus: ACPVisualAidSendStatus,
        actions: ACPVisualAidActions, fillsHeight: Bool = false
    ) {
        self.visual = visual
        self.form = form
        self.sendStatus = sendStatus
        self.actions = actions
        self.fillsHeight = fillsHeight
        _canAnswer = State(initialValue: actions.canAnswer())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            surface
                .frame(height: fillsHeight ? nil : VisualAidWebPolicy.cardHeight(
                    forContentHeight: page?.contentHeight ?? VisualAidWebPolicy.minCardHeight))
                .frame(maxHeight: fillsHeight ? .infinity : nil)
            if let question = visual.question {
                Divider()
                questionArea(question)
            }
        }
        .background(theme.color("bg-1"))
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 1))
        .onAppear(perform: openPage)
        .onDisappear(perform: closePage)
        .onChange(of: theme) { page?.applyTheme(theme) }
        .onReceive(actions.changes) { canAnswer = actions.canAnswer() }
        .onChange(of: canAnswer) { installChoiceHandler() }
        .onChange(of: page?.status) { syncSelection() }
        .onChange(of: form?.selectionValues[ACPVisualAidQuestionForm.choiceKey]) { syncSelection() }
        .onChange(of: visual.answer) {
            installChoiceHandler()
            syncSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(theme.color("accent"))
            Text(visual.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: copyHTML) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy HTML")
            if !fillsHeight {
                Button { actions.popOut(visual) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help("Open in a tab")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        } else {
            placeholder(paused ? "Visual paused to save memory" : "Visual not loaded", button: ("Show visual", openPage))
        }
    }

    private func placeholder(_ text: String, button: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Answered: " + ids.map { "\($0), \(labels[$0] ?? $0)" }.joined(separator: "; "))
                if let note { Text("Note: \(note)").foregroundStyle(theme.color("fg-muted")) }
            }
            .font(.callout)
            .padding(12)
        case .dismissed:
            Text("Dismissed").font(.callout).foregroundStyle(theme.color("fg-muted")).padding(12)
        case nil:
            if !ACPVisualAidQuestionForm.isEditable(answer: visual.answer, canAnswer: canAnswer) {
                readOnlyQuestion(question)
            } else if let form {
                VStack(alignment: .leading, spacing: 6) {
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
                .padding(8)
            }
        }
    }

    /// A mirror cannot answer, so it shows what is asked and where to answer instead of the form.
    private func readOnlyQuestion(_ question: ACPVisualAid.Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.prompt).font(.callout.weight(.semibold))
            ForEach(question.options, id: \.id) { option in
                Text("• " + option.label)
            }
            Text("Answer from the window that owns this session.").foregroundStyle(theme.color("fg-muted"))
        }
        .font(.callout)
        .padding(12)
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

    private func openPage() {
        guard page == nil else { return }
        let page = VisualAidWebPage(
            visualID: visual.id, html: visual.html, theme: theme, locksNetworkAfterLoad: visual.question != nil)
        self.page = page
        paused = false
        installChoiceHandler()
        let pageBinding = $page
        let pausedBinding = $paused
        VisualAidPageBudget.shared.admit(slot) {
            pageBinding.wrappedValue?.close()
            pageBinding.wrappedValue = nil
            pausedBinding.wrappedValue = true
        }
    }

    private func closePage() {
        page?.close()
        page = nil
        VisualAidPageBudget.shared.release(slot)
    }

    /// Page clicks edit the native form only while the question is open and this process may answer it,
    /// and links open only once it is not.
    private func installChoiceHandler() {
        guard let page else { return }
        page.externalLinksEnabled = VisualAidWebPolicy.allowsExternalLinks(
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
