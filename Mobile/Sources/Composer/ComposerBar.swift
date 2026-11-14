import AlasRemoteKit
import PhotosUI
import SwiftUI

/// The prompt composer, floating in glass over the transcript.
struct ComposerBar: View {
    @Bindable var session: TranscriptSession
    /// Task 7 opens the session settings sheet from the chips.
    var onOpenSettings: () -> Void = {}

    @State private var selection = NSRange(location: 0, length: 0)
    @State private var picked: [PhotosPickerItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var queueOpen = false

    private var config: RemoteSessionConfig? { session.config }
    private var text: String { session.draft.text }
    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.draft.images.isEmpty
    }

    private var slash: [RemoteSlashCommand]? {
        guard let token = RemoteComposerText.slashToken(in: text as NSString, caret: selection.location),
              let commands = config?.availableCommands else { return nil }
        let matches = RemoteComposerText.filterSlashCommands(commands, query: token.query)
        return matches.isEmpty ? nil : matches
    }

    private var mentionToken: (start: Int, query: String)? {
        guard config?.supportsMentions == true else { return nil }
        return RemoteComposerText.activeMentionToken(in: text as NSString, caret: selection.location)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let rejection = session.rejection { banner(rejection) }
            if !session.canDrive, session.hasSnapshot { takeOverPill }
            if let slash {
                SlashPicker(commands: slash) { command in
                    let name = command.command.hasPrefix("/") ? command.command : "/" + command.command
                    replaceToken(from: RemoteComposerText.slashToken(in: text as NSString, caret: selection.location)?.start,
                                 with: name + " ")
                }
            } else if let token = mentionToken, token.query == session.mentionCandidatesQuery,
                      !session.mentionCandidates.isEmpty {
                MentionPicker(candidates: session.mentionCandidates) { mention in
                    replaceToken(from: mentionToken?.start, with: "@" + mention.name + " ")
                    if !session.draft.mentions.contains(mention) { session.draft.mentions.append(mention) }
                }
            }
            if queueOpen { QueueTray(session: session).transition(.move(edge: .bottom).combined(with: .opacity)) }
            field
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onChange(of: mentionToken?.query) { _, query in searchMentions(query) }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await ImageStaging.stage(items, into: session) }
        }
    }

    // MARK: Pieces

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !session.draft.images.isEmpty { tiles }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Message").foregroundStyle(.tertiary).padding(.horizontal, 4).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $session.draft.text, selection: $selection)
            }
            HStack(spacing: 6) {
                if config?.acceptsImages == true { attachButton }
                chips
                QueueBadge(session: session, open: $queueOpen)
                Spacer(minLength: 0)
                if let usage = config?.usage, let context = usage.context { UsageRing(usage: usage, context: context) }
                actionButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var tiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.draft.images) { image in
                    Image(uiImage: image.thumbnail)
                        .resizable().scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { session.draft.images.removeAll { $0.id == image.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.system(size: 18))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove photo")
                        }
                        .padding(.top, 6).padding(.trailing, 6)
                }
            }
        }
        .padding(.top, 8)
    }

    private var attachButton: some View {
        PhotosPicker(selection: $picked, maxSelectionCount: max(1, RemoteAttachmentLimits.maxCount - session.draft.images.count),
                     matching: .images) {
            Image(systemName: "paperclip").font(.system(size: 17, weight: .medium))
                .frame(width: 32, height: 32).contentShape(Circle())
        }
        .disabled(session.draft.images.count >= RemoteAttachmentLimits.maxCount)
        .accessibilityLabel("Attach photo")
    }

    private var chips: some View {
        HStack(spacing: 6) {
            chip(name(config?.chips?.model, fallback: config?.currentModel, in: config?.models))
            chip(name(config?.chips?.thinking, fallback: nil, in: nil))
            chip(name(config?.chips?.mode, fallback: config?.currentMode, in: config?.modes))
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func chip(_ label: String?) -> some View {
        if let label {
            Button(action: onOpenSettings) {
                Text(label).font(.footnote.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func name(_ chip: RemoteChip?, fallback: String?, in infos: [RemoteModelInfo]?) -> String? {
        let id = chip?.currentId ?? fallback
        guard let id else { return nil }
        return chip?.options.first { $0.id == id }?.name ?? infos?.first { $0.id == id }?.name ?? id
    }

    @ViewBuilder
    private var actionButton: some View {
        switch (session.streamingState, hasContent) {
        case ("idle", true):
            circle("arrow.up", label: "Send", tint: .accentColor) { session.send(intent: "auto") }
        case ("idle", false):
            if session.hasCancellableBackgroundWork { stopButton }
        case (_, true):
            Menu {
                if config?.supportsSteering == true {
                    Button("Steer now", systemImage: "arrow.turn.down.right") { session.send(intent: "steer") }
                }
                Button("Stop", systemImage: "stop.fill", role: .destructive) { session.stop() }
                    .disabled(session.isStopping)
            } label: {
                glyph("text.line.last.and.arrowtriangle.forward", tint: .accentColor)
            } primaryAction: {
                session.send(intent: "auto")
            }
            .accessibilityLabel("Queue message")
        default:
            stopButton
        }
    }

    private var stopButton: some View {
        circle("stop.fill", label: "Stop", tint: .red) { session.stop() }.disabled(session.isStopping)
    }

    private func circle(_ symbol: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph(symbol, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func glyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint, in: Circle())
    }

    private var takeOverPill: some View {
        Button { session.takeOver() } label: {
            Label("Another device is driving. Take over", systemImage: "hand.raised")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button { session.rejection = nil } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Behaviour

    private func replaceToken(from start: Int?, with replacement: String) {
        let ns = text as NSString
        guard let start, selection.location <= ns.length, start <= selection.location else { return }
        let range = NSRange(location: start, length: selection.location - start)
        session.draft.text = ns.replacingCharacters(in: range, with: replacement)
        selection = NSRange(location: start + (replacement as NSString).length, length: 0)
    }

    /// First query goes out at once; later keystrokes wait for 120 ms of quiet.
    private func searchMentions(_ query: String?) {
        searchTask?.cancel()
        guard let query, query.count <= RemoteAttachmentLimits.maxMentionQueryLength else { return }
        searchTask = Task {
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            session.searchMentions(query)
        }
    }
}

/// A `UITextView` so the caret is readable. Grows to six lines, then scrolls.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    private static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 4
        view.isScrollEnabled = false
        view.accessibilityLabel = "Message"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if view.text != text { view.text = text }
        let length = (view.text as NSString).length
        let wanted = NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location)))
        if view.selectedRange != wanted, view.markedTextRange == nil { view.selectedRange = wanted }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let cap = (uiView.font?.lineHeight ?? 20) * Self.maxLines + 16
        let scrolls = fit > cap
        if uiView.isScrollEnabled != scrolls { uiView.isScrollEnabled = scrolls }
        return CGSize(width: width, height: min(fit, cap))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var updating = false

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            guard !updating else { return }
            if parent.text != view.text { parent.text = view.text }
            if parent.selection != view.selectedRange { parent.selection = view.selectedRange }
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating, parent.selection != view.selectedRange else { return }
            parent.selection = view.selectedRange
        }
    }
}
