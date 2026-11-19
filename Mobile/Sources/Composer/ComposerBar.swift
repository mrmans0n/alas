import AlasRemoteKit
import PhotosUI
import SwiftUI

/// The prompt composer, floating in glass over the transcript.
struct ComposerBar: View {
    @Bindable var session: TranscriptSession
    /// Task 7 opens the session settings sheet from the chips.
    var onOpenSettings: () -> Void = {}
    /// Runs the session's Ship for `/ship`, as the Mac's peer composer does; returns why it can't.
    /// Nil where `/ship` isn't offered, and the text goes to the agent.
    var onShip: (() -> String?)?

    @State private var selection = NSRange(location: 0, length: 0)
    @State private var picked: [PhotosPickerItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var queueOpen = false

    private var config: RemoteSessionConfig? { session.config }
    private var text: String { session.draft.text }
    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.draft.images.isEmpty
    }

    private static let ship = RemoteSlashCommand(
        command: "/ship", description: "Have this session open a PR for the branch, or shepherd the open one.")

    private var slash: [RemoteSlashCommand]? {
        guard let token = RemoteComposerText.slashToken(in: text as NSString, caret: selection.location) else { return nil }
        var commands = config?.availableCommands ?? []
        // Alas intercepts /ship before the agent could see it, so the agent's own is hidden.
        if onShip != nil { commands = [Self.ship] + commands.filter { !["ship", "/ship"].contains($0.command) } }
        let matches = RemoteComposerText.filterSlashCommands(commands, query: token.query)
        return matches.isEmpty ? nil : matches
    }

    private var mentionToken: (start: Int, query: String)? {
        guard config?.supportsMentions == true else { return nil }
        return RemoteComposerText.activeMentionToken(in: text as NSString, caret: selection.location)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let rejection = session.rejection {
                banner(rejection)
            } else if let issue = config?.agentIssue {
                issueBanner(issue)
            }
            if !session.canDrive, session.hasSnapshot { takeOverPill }
            if let slash {
                SlashPicker(commands: slash) { command in
                    let name = command.command.hasPrefix("/") ? command.command : "/" + command.command
                    replaceToken(from: RemoteComposerText.slashToken(in: text as NSString, caret: selection.location)?.start,
                                 with: name + " ")
                }
            } else if let token = mentionToken, token.query.count <= RemoteAttachmentLimits.maxMentionQueryLength {
                // Rows from an earlier query stay up, dimmed and inert, until this one is answered.
                MentionPicker(candidates: session.mentionCandidates,
                              searching: token.query != session.mentionCandidatesQuery) { mention in
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
        .onChange(of: RemoteQueueRules.waiting(session.queue).isEmpty) { _, empty in if empty { queueOpen = false } }
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
                        .accessibilityHidden(true)
                }
                ComposerTextView(text: $session.draft.text, selection: $selection,
                                 onPasteImages: config?.acceptsImages == true ? { images in
                                     Task { for data in images { await ImageStaging.stage(data, into: session) } }
                                 } : nil)
            }
            HStack(spacing: 6) {
                if config?.acceptsImages == true { attachButton }
                chips
                QueueBadge(session: session, open: $queueOpen)
                Spacer(minLength: 0)
                if let usage = config?.usage, usage.context != nil || !usage.lastTurn.isEmpty || !usage.cumulative.isEmpty {
                    UsageRing(usage: usage)
                }
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

    /// Scrolls sideways when the row is crowded, so no chip, the model above all, truncates.
    private var chips: some View {
        let row = HStack(spacing: 6) {
            autoRunChip
            chip(name(config?.chips?.model, fallback: config?.currentModel, in: config?.models))
            chip(name(config?.chips?.thinking, fallback: nil, in: nil))
            chip(name(config?.chips?.mode, fallback: config?.currentMode, in: config?.modes))
        }
        .lineLimit(1)
        .fixedSize()
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
    }

    /// The Mac's auto-run toggle, shown only while on: turning it on stays in Session Settings, where
    /// the row has room to say what it does.
    @ViewBuilder
    private var autoRunChip: some View {
        if let config, config.autoRunEnabled, config.chips?.autoRun != "ignored" {
            Button { session.setAutoRun(false) } label: {
                Label("Auto-run", systemImage: "bolt.fill").font(.footnote.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(.orange)
                    .background(.orange.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auto-run is on")
            .accessibilityHint("Turns auto-run off. The agent runs tools without asking while it is on.")
        }
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
            circle("arrow.up", label: "Send", tint: .accentColor) { send("auto") }
        case ("idle", false):
            if session.hasCancellableBackgroundWork { stopButton }
        case (_, true):
            Menu {
                if config?.supportsSteering == true {
                    Button("Steer now", systemImage: "arrow.turn.down.right") { send("steer") }
                }
                Button("Stop", systemImage: "stop.fill", role: .destructive) { session.stop() }
                    .disabled(session.isStopping)
            } label: {
                glyph("text.line.last.and.arrowtriangle.forward", tint: .accentColor)
            } primaryAction: {
                send("auto")
            }
            .accessibilityLabel("Queue message")
        default:
            stopButton
        }
    }

    /// `/ship` alone ships; anything more is refused, as on the Mac.
    private func send(_ intent: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let onShip, trimmed.hasPrefix("/ship"), trimmed.dropFirst(5).first?.isWhitespace ?? true else {
            return session.send(intent: intent)
        }
        let refusal = if trimmed != "/ship" {
            "/ship doesn't take arguments."
        } else if !session.draft.images.isEmpty {
            "/ship doesn't take attachments. Remove them to ship."
        } else {
            onShip()
        }
        if let refusal {
            session.rejection = refusal
        } else {
            session.draft = ComposerDraft()
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
            Label("Take over to drive this session", systemImage: "hand.raised")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    /// Why the agent can't run, kept up until the host clears it, with Install when the host can fix it.
    private func issueBanner(_ issue: RemoteAgentIssue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(issue.message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            if session.offersAdapterInstall {
                let installing = session.adapterInstallRequested == issue
                Button(installing ? "Installing…" : "Install") { session.installAdapter() }
                    .font(.footnote.weight(.semibold))
                    .disabled(installing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    /// Takes pasted images; nil leaves Paste to text only.
    var onPasteImages: (([Data]) -> Void)?
    private static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = PastingTextView()
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
        (view as? PastingTextView)?.onPasteImages = onPasteImages
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

/// A text view whose Paste also takes images, as the Mac composer does.
private final class PastingTextView: UITextView {
    var onPasteImages: (([Data]) -> Void)?

    private var pastedImages: [Data] {
        guard onPasteImages != nil, UIPasteboard.general.hasImages else { return [] }
        return (UIPasteboard.general.images ?? []).compactMap { $0.pngData() }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteImages != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let images = pastedImages
        guard !images.isEmpty else { return super.paste(sender) }
        onPasteImages?(images)
    }
}
