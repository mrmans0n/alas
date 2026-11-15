import AlasRemoteKit
import SwiftUI

/// A visual aid in the transcript: the sandboxed page, and for a question the native answer controls
/// (`app.js` renderVisualAnswer). A card is flat; an embedded visual is part of the reply.
struct VisualAidCard: View {
    let aid: ACPVisualAid
    let session: TranscriptSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Sandbox and crash failures are this cell's; a blocked page is remembered on the session.
    @State private var failure: VisualAidPage.Failure?
    @State private var generation = 0
    /// Crashes reloaded without asking; iOS often ends a page's process while the app is away.
    @State private var autoReloads = 0
    /// The answer draft, held here so a pick redraws the card at once and a keystroke redraws only
    /// this card; written through to the session so it survives cell reuse.
    @State private var selected: [String]
    @State private var note: String

    /// As the Mac's visual-aid page.
    private static let maxAutoReloads = 3
    /// Theme variables per appearance; resolving every color on each body pass is wasted work.
    @MainActor private static var themes: [String: [String: String]] = [:]

    init(aid: ACPVisualAid, session: TranscriptSession) {
        self.aid = aid
        self.session = session
        let saved = session.visualAids[aid.id]
        _selected = State(initialValue: saved?.selected ?? [])
        _note = State(initialValue: saved?.note ?? "")
    }

    private var state: VisualAidCardState { session.visualAids[aid.id] ?? .init() }

    var body: some View {
        if aid.presentation == .embedded {
            surface
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(aid.title).font(.subheadline.weight(.semibold)).padding(12)
                surface
                if let question = aid.question {
                    answer(question).padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private var surface: some View {
        if state.blocked {
            notice("Visual blocked: it tried to leave the page.")
        } else if failure == .sandbox {
            notice("Couldn't set up the visual's sandbox")
        } else if failure == .stopped {
            notice("Visual stopped", reload: true)
        } else {
            let id = aid.id
            VisualAidWebView(
                visual: aid,
                themeVariables: themeVariables,
                selected: shownSelection,
                linksEnabled: RemoteVisualAidWebPolicy.allowsExternalLinks(hasQuestion: aid.question != nil, answer: aid.answer),
                onHeight: { [session] height in
                    // Sub-point changes would only relayout the transcript for nothing.
                    if abs((session.visualAids[id]?.height ?? 0) - height) >= 1 {
                        session.visualAids[id, default: .init()].height = height
                    }
                },
                onChoice: { [session, aid] option in
                    guard let question = aid.question, aid.answer == nil, session.visualAids[id]?.pendingRequestId == nil,
                          question.options.contains(where: { $0.id == option })
                    else { return }
                    toggle(option, allowMultiple: question.allowMultiple)
                },
                onFailure: { [session] failure in
                    if failure == .blocked {
                        session.visualAids[id, default: .init()].blocked = true
                    } else if failure == .stopped, autoReloads < Self.maxAutoReloads {
                        autoReloads += 1
                        generation += 1
                    } else {
                        self.failure = failure
                    }
                })
            .id(generation)
            .frame(height: state.height ?? RemoteVisualAidWebPolicy.minCardHeight)
            .accessibilityLabel(aid.title)
        }
    }

    private var shownSelection: [String] {
        if case .answered(let ids, _, _) = aid.answer { return ids }
        return selected
    }

    private var themeVariables: [String: String] {
        let key = "\(colorScheme)-\(dynamicTypeSize)"
        if let cached = Self.themes[key] { return cached }
        let made = VisualAidWebView.themeVariables(UITraitCollection { traits in
            traits.userInterfaceStyle = colorScheme == .dark ? .dark : .light
            traits.preferredContentSizeCategory = UIContentSizeCategory(dynamicTypeSize)
        })
        Self.themes[key] = made
        return made
    }

    private func toggle(_ option: String, allowMultiple: Bool) {
        session.toggleVisualAidChoice(aid.id, option: option, allowMultiple: allowMultiple)
        selected = session.visualAids[aid.id]?.selected ?? []
    }

    private func notice(_ text: String, reload: Bool = false) -> some View {
        HStack {
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if reload {
                Button("Reload") {
                    failure = nil
                    generation += 1
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func answer(_ question: ACPVisualAid.Question) -> some View {
        switch aid.answer {
        case .dismissed:
            Text("Dismissed").font(.callout).foregroundStyle(.secondary)
        case .answered(let ids, let note, _):
            VStack(alignment: .leading, spacing: 4) {
                Text("Answered: " + question.options.filter { ids.contains($0.id) }.map(\.label).joined(separator: ", "))
                    .font(.callout)
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            }
        case nil:
            openQuestion(question)
        }
    }

    private func openQuestion(_ question: ACPVisualAid.Question) -> some View {
        let state = state
        let pending = state.pendingRequestId != nil
        let canSubmit = !pending && RemoteVisualAidAnswer.answer(
            to: question, action: "answer", selectedOptionIds: selected, note: note) != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(question.prompt).font(.subheadline.weight(.semibold))
            ForEach(question.options, id: \.id) { option in
                optionRow(question, option, on: selected.contains(option.id))
            }
            TextField("Add a note (optional)", text: $note, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 8) {
                Button(pending ? "Sending…" : "Submit") {
                    session.answerVisualAid(aid.id, action: "answer", selectedOptionIds: selected, note: note)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                Button("Dismiss") {
                    session.answerVisualAid(aid.id, action: "dismiss", selectedOptionIds: [], note: nil)
                }
                .buttonStyle(.bordered)
            }
            if let error = state.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .disabled(pending)
        .onChange(of: note) { session.visualAids[aid.id, default: .init()].note = note }
    }

    private func optionRow(_ question: ACPVisualAid.Question, _ option: ACPVisualAid.Option, on: Bool) -> some View {
        let symbol = question.allowMultiple ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
        return Button {
            toggle(option.id, allowMultiple: question.allowMultiple)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(on ? Color.accentColor : .secondary)
                Text(option.label).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
