import AlasRemoteKit
import SwiftUI

/// One session's live transcript.
struct TranscriptScreen: View {
    @Environment(SessionRegistry.self) private var registry
    @Environment(\.horizontalSizeClass) private var sizeClass
    let hostID: UUID
    let sessionId: String
    @State private var held: (session: TranscriptSession, token: ListenerToken)?
    @State private var workspace: SessionWorkspace?
    @State private var workspaceToken: ListenerToken?
    /// Owns this screen's pushed diff or file: the same session may be open in another tab too.
    @State private var screenID = UUID()
    @State private var visible = false
    @State private var mode = SessionMode.transcript
    @State private var showSettings = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var renamingBranch = false
    @State private var newBranch = ""
    /// The branch the Rename Branch dialog opened on.
    @State private var renamedBranch = ""
    @State private var confirmingArchive = false
    @State private var actionError: String?
    /// What a slow worktree or session action is doing, shown until the host answers.
    @State private var progress: String?
    /// The worktree a Delete awaits confirmation for, as it was when the user asked.
    @State private var deleting: SessionWorkspace.RemovalTarget?
    /// A worktree removal the host refused in a way the user may overrule.
    @State private var overruling: Overruling?
    @Environment(\.dismiss) private var dismiss
    /// The worktree whose terminals are pushed from this screen.
    @State private var terminalsWorktree: String?
    /// The subagent whose transcript is pushed from this screen; it reads through this screen's session.
    @State private var openedSubagent: RemoteWireMessage.Subagent?
    /// The delegated child, or the delegating parent, pushed from this screen.
    @State private var delegated: String?

    var body: some View {
        Group {
            if let session = held?.session, let workspace {
                content(session, workspace)
            } else {
                Color(.systemBackground)
            }
        }
        // On the view that stays mounted: a destination owned by the conditional content would go
        // with it.
        .navigationDestination(item: $terminalsWorktree) { worktreeId in
            TerminalsList(hub: registry.hub, hostID: hostID, worktreeId: worktreeId)
        }
        .navigationDestination(isPresented: Binding(
            get: { openedSubagent != nil }, set: { if !$0 { openedSubagent = nil } })) {
            if let openedSubagent, let session = held?.session {
                SubagentScreen(session: session, subagent: openedSubagent)
            }
        }
        .navigationDestination(item: $delegated) { id in
            TranscriptScreen(hostID: hostID, sessionId: id)
        }
        .onAppear {
            visible = true
            acquire()
        }
        .onDisappear {
            visible = false
            // A view pushed from this screen (a diff, a file) covers it and fires this too; keep
            // the session and workspace alive until the screen itself leaves the stack.
            // Checked a turn later so a pushed view popped along with this screen has cleared
            // its state first (DiffView's own onDisappear), and so a screen that came straight
            // back keeps what it holds.
            Task { @MainActor in
                if visible || terminalsWorktree != nil || openedSubagent != nil || delegated != nil || workspace?.hasPushedChild(screenID) == true { return }
                held = nil
                workspaceToken = nil
            }
        }
    }

    private enum SessionMode: String, CaseIterable {
        case transcript = "Transcript", changes = "Changes", files = "Files"
    }

    private func modes(_ session: TranscriptSession) -> [SessionMode] {
        session.summary?.worktree?.isFolder == true ? [.transcript, .files] : SessionMode.allCases
    }

    private func acquire() {
        guard held == nil else { return }
        let (session, token) = registry.acquire(hostID: hostID, sessionId: sessionId)
        held = (session, token)
        let workspace = registry.workspace(hostID: hostID, sessionId: sessionId)
        workspaceToken = workspace.activate()
        self.workspace = workspace
    }

    private func content(_ session: TranscriptSession, _ workspace: SessionWorkspace) -> some View {
        let available = modes(session)
        let base = TranscriptContent(session: session, openSubagent: { openedSubagent = $0 })
            // Kept alive under the other tabs so the scroll position survives a switch.
            .opacity(mode == .transcript ? 1 : 0)
            .allowsHitTesting(mode == .transcript)
            .accessibilityHidden(mode != .transcript)
            .overlay {
                switch mode {
                case .transcript: EmptyView()
                case .changes: ChangesView(workspace: workspace, owner: screenID).background(Color(.systemBackground))
                case .files: FilesView(workspace: workspace, session: session, owner: screenID).background(Color(.systemBackground))
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    Picker("View", selection: $mode) {
                        ForEach(available, id: \.self) { Text(label($0, session, workspace)) }
                    }
                    .pickerStyle(.segmented)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    ConnectionBanner(hub: registry.hub, hostID: hostID)
                }
            }
            // Destinations for views pushed from the tabs live here, on a view that stays mounted.
            .navigationDestination(isPresented: Binding(
                get: { workspace.diff != nil && workspace.diff?.key.sha == nil && workspace.pushedBy == screenID },
                set: { if !$0 { workspace.closeDiff() } })) {
                DiffView(workspace: workspace)
            }
            // A commit's own diffs push from its file list.
            .navigationDestination(isPresented: Binding(
                get: { workspace.commit != nil && workspace.pushedBy == screenID },
                set: { if !$0 { workspace.closeCommit() } })) {
                CommitFilesView(workspace: workspace)
            }
            .navigationDestination(isPresented: Binding(
                get: { workspace.file != nil && workspace.pushedBy == screenID },
                set: { if !$0 { workspace.closeFile() } })) {
                FileViewer(workspace: workspace, session: session)
            }
            .onChange(of: session.streamingState, initial: true) { workspace.noteStreaming(session.streamingState) }
            .onChange(of: available) { if !available.contains(mode) { mode = .transcript } }
            .safeAreaInset(edge: .bottom) {
                if !session.hasEnded {
                    // One container, so the floating glass layers composite together over the stream.
                    GlassEffectContainer {
                        VStack(spacing: 0) {
                            // On every tab, so a request that arrives while reading a diff isn't missed.
                            RequestCard(session: session).environment(\.cardFloats, true).padding(.horizontal, 12).padding(.bottom, 4)
                            if mode == .transcript {
                                ComposerBar(session: session, onOpenSettings: { showSettings = true },
                                            onShip: session.canDrive && workspace.canShepherd ? { ship(workspace) } : nil)
                            }
                        }
                    }
                } else if mode == .transcript {
                    EndedBar(session: session)
                }
            }
            // Below the request cards, so links in a plan under review route too. A file link opens in the
            // file viewer; one outside the worktree opens nothing.
            .environment(\.openURL, OpenURLAction { url in
                switch RemoteTranscriptLink.route(url, worktreeRoot: session.worktreeRoot) {
                case .file(let path):
                    workspace.openFile(path, by: screenID)
                    return .handled
                case .system: return .systemAction
                case .discard: return .discarded
                }
            })
            .background(Color(.systemBackground))
            .navigationTitle(session.summary?.title ?? "Session")
            .navigationSubtitle(subtitle(session))
            .navigationBarTitleDisplayMode(.inline)
            // On the iPhone a conversation gets the whole screen, as in Messages; the composer takes the
            // tab bar's place. Where the session sits beside its list (iPad), the tabs stay.
            .toolbar(sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
            .toolbarTitleMenu {
                if !session.hasEnded {
                    Button("Rename…", systemImage: "pencil") {
                        newTitle = session.summary?.title ?? ""
                        renaming = true
                    }
                    Button("Session Settings", systemImage: "slider.horizontal.3") { showSettings = true }
                    if let branch = workspace.renamableBranch {
                        Button("Rename Branch…", systemImage: "arrow.triangle.branch") {
                            newBranch = branch
                            renamedBranch = branch
                            renamingBranch = true
                        }
                    }
                    if session.supportsSessionTabs {
                        Button("Close Session", systemImage: "xmark.circle") { session.closeTab() }
                            .disabled(session.tabAction != nil)
                    }
                }
                if let parentId = session.summary?.parentSessionId,
                   let parent = registry.hub.sessions(of: hostID).first(where: { $0.id == parentId }) {
                    Button("Delegated by \(parent.title)", systemImage: "arrow.turn.left.up") { delegated = parent.id }
                }
                if let worktree = session.summary?.worktree {
                    CopyWorktreeButtons(summary: worktree)
                }
                if workspace.canArchive {
                    Button("Archive Session", systemImage: "archivebox", role: .destructive) { confirmingArchive = true }
                }
                if let target = workspace.removalTarget {
                    Section {
                        Button("Archive Worktree", systemImage: "archivebox") { removeWorktree(workspace, .archive, of: target) }
                        Button("Delete Worktree…", systemImage: "trash", role: .destructive) { deleting = target }
                    }
                }
            }
            .toolbar {
                if !session.hasEnded, workspace.canShepherd, workspace.shepherdLoaded {
                    ToolbarItem(placement: .primaryAction) { ShepherdMenu(workspace: workspace) }
                }
                let children = registry.hub.sessions(of: hostID).filter { $0.parentSessionId == sessionId }
                if !children.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Delegated Sessions", systemImage: "arrow.triangle.branch") {
                            ForEach(children, id: \.id) { child in
                                Button(child.title) { delegated = child.id }
                            }
                        }
                    }
                }
                if workspace.canRun, !workspace.runScripts.isEmpty {
                    // ponytail: no run state, since the host only pushes it as events; a run's output
                    // shows in its console under Terminals.
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Run", systemImage: "play") {
                            ForEach(workspace.runScripts, id: \.key) { script in
                                Menu(script.name) {
                                    Button("Run", systemImage: "play") { run(workspace, .start, script) }
                                    Button("Restart", systemImage: "arrow.clockwise") { run(workspace, .restart, script) }
                                    Button("Stop", systemImage: "stop", role: .destructive) { run(workspace, .stop, script) }
                                }
                            }
                        }
                    }
                }
                if let worktreeId = session.summary?.worktreeId,
                   registry.hub.supports(PeerConsoleCapability.phoneV1, on: hostID) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Terminals", systemImage: "terminal") { terminalsWorktree = worktreeId }
                    }
                }
            }
            .overlay {
                if let busy = progress ?? (session.tabAction == .close ? "Closing session…" : nil) {
                    ProgressView(busy)
                        .padding(20)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .disabled(progress != nil)
            .sheet(isPresented: $showSettings) { SessionSettingsSheet(session: session) }
            .alert("Couldn't do that", isPresented: Binding { session.tabActionError != nil } set: { if !$0 { session.tabActionError = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.tabActionError ?? "")
            }
            .alert("Rename Session", isPresented: $renaming) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { session.rename(newTitle) }
            }
        return lifecycleDialogs(base, workspace)
    }

    /// The title menu's lifecycle prompts, apart so the screen's modifier chain type-checks in time.
    private func lifecycleDialogs(_ view: some View, _ workspace: SessionWorkspace) -> some View {
        view
            .alert("Rename Branch", isPresented: $renamingBranch) {
                TextField("Branch", text: $newBranch).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let branch = newBranch.trimmingCharacters(in: .whitespaces)
                    guard !branch.isEmpty, branch != renamedBranch else { return }
                    Task { actionError = await workspace.renameBranch(from: renamedBranch, to: branch) }
                }
            }
            .confirmationDialog("Archive this session?", isPresented: $confirmingArchive, titleVisibility: .visible) {
                Button("Archive", role: .destructive) {
                    Task {
                        progress = "Archiving session…"
                        defer { progress = nil }
                        if let error = await workspace.archiveSession() { actionError = error } else { dismiss() }
                    }
                }
            } message: {
                Text("The session stops and leaves the session list.")
            }
            .confirmationDialog("Delete this worktree?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
                                titleVisibility: .visible, presenting: deleting) { target in
                Button("Delete", role: .destructive) { removeWorktree(workspace, .delete, of: target) }
            } message: { _ in
                Text("Its folder is removed from the machine. The branch is deleted too once it's merged.")
            }
            .confirmationDialog(overruling?.failure.message ?? "", isPresented: Binding { overruling != nil } set: { if !$0 { overruling = nil } },
                                titleVisibility: .visible, presenting: overruling) { held in
                Button(held.failure.overrule == .force ? "Delete Anyway" : "Discard Changes", role: .destructive) {
                    removeWorktree(workspace, held.removal, of: held.target, force: held.force || held.failure.overrule == .force,
                                   discard: held.discard || held.failure.overrule == .discardUnsavedEdits)
                }
            }
            .alert("Couldn't do that", isPresented: Binding { actionError != nil } set: { if !$0 { actionError = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
    }

    private struct Overruling {
        let removal: SessionWorkspace.WorktreeRemoval
        let target: SessionWorkspace.RemovalTarget
        let failure: RemoteGitFailure
        let force: Bool
        let discard: Bool
    }

    /// `/ship` from the composer: the Ship menu's action, refused while the session already shepherds a PR.
    private func ship(_ workspace: SessionWorkspace) -> String? {
        if let shepherd = workspace.shepherd {
            return shepherd.number.map { "This session already shepherds \($0)." } ?? "This session already shepherds a pull request."
        }
        Task { if let error = await workspace.shepherd(.ship) { actionError = error } }
        return nil
    }

    private func run(_ workspace: SessionWorkspace, _ action: RemoteRunAction, _ script: RemoteRunScript) {
        Task { if let error = await workspace.run(action, script) { actionError = error } }
    }

    /// Sends the removal; a refusal the user may overrule asks again, any other shows.
    private func removeWorktree(_ workspace: SessionWorkspace, _ removal: SessionWorkspace.WorktreeRemoval,
                                of target: SessionWorkspace.RemovalTarget, force: Bool = false, discard: Bool = false) {
        Task {
            progress = removal == .delete ? "Deleting worktree…" : "Archiving worktree…"
            defer { progress = nil }
            guard let failure = await workspace.removeWorktree(removal, of: target, force: force, discard: discard) else { return dismiss() }
            if failure.overrule != nil {
                overruling = Overruling(removal: removal, target: target, failure: failure, force: force, discard: discard)
            } else {
                actionError = failure.message
            }
        }
    }

    /// Changes carries the web's tab badge: the loaded count, else the worktree summary's.
    private func label(_ mode: SessionMode, _ session: TranscriptSession, _ workspace: SessionWorkspace) -> String {
        guard mode == .changes else { return mode.rawValue }
        let loaded: ChangeListReply? = if case .loaded(let reply) = workspace.changes, reply.metricsAvailable { reply } else { nil }
        let badge = RemoteChangesRules.badge(
            loaded: loaded?.changedFiles.count, truncated: loaded?.truncated ?? false,
            fallback: session.summary?.worktree?.changedFileCount ?? 0)
        return badge.map { "\(mode.rawValue) \($0)" } ?? mode.rawValue
    }

    private func subtitle(_ session: TranscriptSession) -> String {
        let status: String? = switch session.streamingState {
        case "streaming": "Working"
        case "awaitingPermission": "Needs permission"
        case "awaitingInput": "Waiting for input"
        default: nil
        }
        return [session.summary?.worktree?.branch, status].compactMap(\.self).joined(separator: " · ")
    }
}

/// Its own view so a streamed delta re-evaluates only the scroller, not the screen around it.
private struct TranscriptContent: View {
    @Bindable var session: TranscriptSession
    let openSubagent: (RemoteWireMessage.Subagent) -> Void

    var body: some View {
        TranscriptCollectionView(
            items: session.items, expanded: $session.expanded, canLoadOlder: session.canLoadOlder,
            loadOlder: session.loadOlder, image: session.image(for:), session: session,
            sendCount: session.sendCount, openSubagent: openSubagent)
        // Rows scroll on under the glass tab picker and composer; the collection view's
        // safe-area content insets still let the first and last rows rest clear of them.
        .ignoresSafeArea(edges: .vertical)
        .overlay {
            if session.items.isEmpty, !session.hasEnded {
                if session.hasSnapshot {
                    ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right")
                } else if session.hostState != .online {
                    ContentUnavailableView("Waiting for \(session.hostName) to come online…", systemImage: "wifi.slash",
                                           description: Text(session.hostState.label))
                } else {
                    ProgressView()
                }
            }
        }
    }
}

/// Under an ended session: says so, with Reopen where the host reopens session tabs.
private struct EndedBar: View {
    let session: TranscriptSession

    var body: some View {
        HStack(spacing: 12) {
            Text("This session has ended.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if session.supportsSessionTabs {
                Button(session.tabAction == .reopen ? "Reopening…" : "Reopen") { session.reopenTab() }
                    .font(.footnote.weight(.semibold))
                    .disabled(session.tabAction != nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
