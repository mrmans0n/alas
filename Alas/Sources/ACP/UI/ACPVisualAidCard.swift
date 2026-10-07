import AppKit
import SwiftUI

/// What a visual aid card can ask its host to do.
struct ACPVisualAidActions {
    /// True once the answer is stored; the prompt is sent in the background and
    /// a failed send clears the answer on the transcript again.
    var answer: (UUID, ACPVisualAid.Answer) async -> Bool
    var popOut: (ACPVisualAid) -> Void

    /// For hosts that only display transcripts.
    static var readOnly: Self { .init(answer: { _, _ in false }, popOut: { _ in }) }
}

/// A visual aid in the transcript (or filling a pop-out tab): the sandboxed
/// page plus, when it asks one, the native question card.
struct ACPVisualAidCard: View {
    let visual: ACPVisualAid
    let form: ACPUserInputFormState?
    let sendStatus: ACPVisualAidSendStatus
    let actions: ACPVisualAidActions
    var fillsHeight = false

    @Environment(\.theme) private var theme
    @State private var slot = UUID()
    @State private var page: VisualAidWebPage?
    @State private var paused = false
    @State private var sending = false

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
            if let form {
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

    private func respond(_ action: ACPUserInputAction, question: ACPVisualAid.Question) {
        let answer: ACPVisualAid.Answer
        switch action {
        case .submit(let content):
            guard let answered = ACPVisualAidQuestionForm.answer(from: content, question: question, at: Date()) else { return }
            answer = answered
        case .decline, .cancel:
            answer = .dismissed(at: Date())
        }
        guard !sending else { return }
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
        let page = VisualAidWebPage(visualID: visual.id, html: visual.html, theme: theme)
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

    /// Page clicks edit the native form only while the question is open.
    private func installChoiceHandler() {
        guard let page else { return }
        guard visual.answer == nil, let form else {
            page.onChoice = { _ in }
            return
        }
        page.onChoice = { choice in
            guard let field = ACPVisualAidQuestionForm.choiceField(for: choice, in: form.request) else { return }
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
