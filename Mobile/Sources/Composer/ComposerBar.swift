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
    /// Opens chip cards; nil shows none.
    var actions: ChipActions?

    @State private var selection = NSRange(location: 0, length: 0)
    @State private var picked: [PhotosPickerItem] = []
    @State private var showingGoal = false
    @State private var showingMCP = false
    @State private var pickingPhotos = false
    @State private var takingPhoto = false
    @State private var searchTask: Task<Void, Never>?
    @State private var queueOpen = false

    private var config: RemoteSessionConfig? { session.config }
    private var text: String { session.draft.text }
    /// What the editor shows, chips as one character each: the `/` and `@` tokens are read from it.
    private var display: String { session.draft.content.displayText }
    private var hasContent: Bool { session.draft.hasContent }
    /// The host's suggestion, while the composer is empty.
    private var suggestion: String? {
        session.draft.content.isEmpty && session.draft.images.isEmpty ? session.nextPromptSuggestion : nil
    }

    /// The commands the picker offers. Alas intercepts /ship before the agent
    /// could see it, so the agent's own is hidden.
    private var commands: [RemoteSlashCommand] {
        let agent = config?.availableCommands ?? []
        guard onShip != nil else { return agent }
        return [ChipActions.ship] + agent.filter { !["ship", "/ship"].contains($0.command) }
    }

    private var rules: ChipRules {
        ChipRules(commands: commands.map(\.command), codeHost: config?.codeHost)
    }

    private var slash: [RemoteSlashCommand]? {
        guard let token = RemoteComposerText.slashToken(in: display as NSString, caret: selection.location) else { return nil }
        let matches = RemoteComposerText.filterSlashCommands(commands, query: token.query)
        return matches.isEmpty ? nil : matches
    }

    private var mentionToken: (start: Int, query: String)? {
        guard config?.supportsMentions == true else { return nil }
        return RemoteComposerText.activeMentionToken(in: display as NSString, caret: selection.location)
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
                    let start = RemoteComposerText.slashToken(in: display as NSString, caret: selection.location)?.start
                    // Inside code a command stays text, as on the Mac.
                    let inCode = start.map { SlashCommandText.isInCode($0, in: display as NSString) } ?? false
                    replaceToken(from: start, with: inCode ? [.text(name + " ")] : [.chip(.command(name)), .text(" ")])
                }
            } else if let token = mentionToken, token.query.count <= RemoteAttachmentLimits.maxMentionQueryLength {
                // Rows from an earlier query stay up, dimmed and inert, until this one is answered.
                MentionPicker(candidates: session.mentionCandidates,
                              searching: token.query != session.mentionCandidatesQuery) { mention in
                    replaceToken(from: mentionToken?.start, with: [.chip(.mention(mention)), .text(" ")])
                }
            }
            if queueOpen { QueueTray(session: session).transition(.move(edge: .bottom).combined(with: .opacity)) }
            field
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onChange(of: mentionToken?.query) { _, query in searchMentions(query) }
        .onChange(of: RemoteQueueRules.waiting(session.queue).isEmpty) { _, empty in if empty { queueOpen = false } }
        .onChange(of: session.composerFocusRequest) { selection = NSRange(location: (display as NSString).length, length: 0) }
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
                if session.draft.content.isEmpty {
                    Text(suggestion ?? "Message").foregroundStyle(.tertiary).lineLimit(4)
                        .padding(.horizontal, 4).padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ComposerTextView(draft: $session.draft.content, selection: $selection, rules: rules,
                                 references: session.references, actions: actions,
                                 focusRequest: session.composerFocusRequest,
                                 onPasteImages: config?.acceptsImages == true ? { images in
                                     Task { for data in images { await ImageStaging.stage(data, into: session) } }
                                 } : nil)
            }
            HStack(spacing: 6) {
                if config?.acceptsImages == true { attachButton }
                chips
                QueueBadge(session: session, open: $queueOpen)
                if let suggestion {
                    Button("Use suggestion", systemImage: "text.insert") { session.acceptNextPromptSuggestion() }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityValue(suggestion)
                }
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
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: "camera") { takingPhoto = true }
            }
        } label: {
            Image(systemName: "paperclip").font(.system(size: 17, weight: .medium))
                .frame(width: 32, height: 32).contentShape(Circle())
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $picked,
                      maxSelectionCount: max(1, RemoteAttachmentLimits.maxCount - session.draft.images.count), matching: .images)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in Task { await ImageStaging.stage(data, into: session) } }
                .ignoresSafeArea()
        }
        .disabled(session.draft.images.count >= RemoteAttachmentLimits.maxCount)
        .accessibilityLabel("Attach photo")
    }

    /// Scrolls sideways when the row is crowded, so no chip, the model above all, truncates.
    private var chips: some View {
        let row = HStack(spacing: 6) {
            if let goal = config?.goal { goalChip(goal) }
            autoRunChip
            chip(name(config?.chips?.model, fallback: config?.currentModel, in: config?.models))
            chip(name(config?.chips?.thinking, fallback: nil, in: nil))
            chip(name(config?.chips?.mode, fallback: config?.currentMode, in: config?.modes))
            if let mcp = config?.mcp { mcpChip(mcp) }
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

    /// The Mac's goal pill: what the session is working towards and its token spend. Tapping shows it whole.
    private func goalChip(_ goal: RemoteSessionGoal) -> some View {
        Button { showingGoal = true } label: {
            HStack(spacing: 4) {
                Image(systemName: goal.isPaused ? "pause.fill" : "target").imageScale(.small)
                Text(goal.objective).frame(maxWidth: 160, alignment: .leading)
                if let tokens = goal.tokenText { Text(tokens).monospacedDigit().foregroundStyle(.secondary) }
            }
            .font(.footnote.weight(.medium)).lineLimit(1)
            .foregroundStyle(goal.isRunning ? Color.accentColor : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.accentColor.opacity(goal.isRunning ? 0.15 : 0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Goal: \(goal.objective)")
        .alert("Goal", isPresented: $showingGoal) {
            Button("OK", role: .cancel) {}
        } message: {
            Text([goal.objective, goal.status?.replacingOccurrences(of: "_", with: " "), goal.tokenText]
                .compactMap { $0 }.joined(separator: "\n"))
        }
    }

    /// The Mac's MCP pill: the servers Alas asked the agent to attach, marked when one was skipped.
    private func mcpChip(_ mcp: RemoteMCPStatus) -> some View {
        Button { showingMCP = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "server.rack").imageScale(.small)
                Text("MCP \(mcp.requested)").monospacedDigit()
                if mcp.needsAttention { Image(systemName: "exclamationmark.triangle.fill").imageScale(.small).foregroundStyle(.orange) }
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("MCP: \(mcp.requested) requested" + (mcp.skipped > 0 ? ", \(mcp.skipped) skipped" : ""))
        .sheet(isPresented: $showingMCP) {
            NavigationStack {
                List {
                    if let warning = mcp.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Section {
                        ForEach(Array(mcp.servers.enumerated()), id: \.offset) { _, server in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text("\(server.transport) · \(server.detail)").font(.footnote)
                                    .foregroundStyle(server.requested ? Color.secondary : .orange)
                            }
                        }
                    } footer: {
                        Text("What Alas asked the agent to attach when this session started. Change servers on the Mac.")
                    }
                }
                .navigationTitle("MCP Servers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingMCP = false } } }
            }
            .presentationDetents([.medium, .large])
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

    /// Replaces the `/` or `@` token from `start` to the caret, in display units.
    private func replaceToken(from start: Int?, with replacement: [RemoteDraftSegment]) {
        guard let start, selection.location <= (display as NSString).length, start <= selection.location else { return }
        let range = NSRange(location: start, length: selection.location - start)
        session.draft.content = session.draft.content.replacing(range, with: replacement)
        let length = replacement.reduce(0) { sum, segment in
            if case .text(let value) = segment { sum + value.utf16.count } else { sum + 1 }
        }
        selection = NSRange(location: start + length, length: 0)
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
