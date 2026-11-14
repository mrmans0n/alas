import AlasRemoteKit
import SwiftUI

/// One session's live transcript.
struct TranscriptScreen: View {
    @Environment(SessionRegistry.self) private var registry
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

    var body: some View {
        Group {
            if let session = held?.session, let workspace {
                content(session, workspace)
            } else {
                Color(.systemBackground)
            }
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
                if visible || workspace?.hasPushedChild(screenID) == true { return }
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
        return TranscriptContent(session: session)
            // Kept alive under the other tabs so the scroll position survives a switch.
            .opacity(mode == .transcript ? 1 : 0)
            .allowsHitTesting(mode == .transcript)
            .accessibilityHidden(mode != .transcript)
            .overlay {
                switch mode {
                case .transcript: EmptyView()
                case .changes: ChangesView(workspace: workspace, owner: screenID).background(Color(.systemBackground))
                case .files: FilesView(workspace: workspace, owner: screenID).background(Color(.systemBackground))
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("View", selection: $mode) {
                    ForEach(available, id: \.self) { Text(label($0, session, workspace)) }
                }
                .pickerStyle(.segmented)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            // Destinations for views pushed from the tabs live here, on a view that stays mounted.
            .navigationDestination(isPresented: Binding(
                get: { workspace.diff != nil && workspace.pushedBy == screenID },
                set: { if !$0 { workspace.closeDiff() } })) {
                DiffView(workspace: workspace)
            }
            .navigationDestination(isPresented: Binding(
                get: { workspace.file != nil && workspace.pushedBy == screenID },
                set: { if !$0 { workspace.closeFile() } })) {
                FileViewer(workspace: workspace)
            }
            .onChange(of: session.streamingState, initial: true) { workspace.noteStreaming(session.streamingState) }
            .onChange(of: available) { if !available.contains(mode) { mode = .transcript } }
            .safeAreaInset(edge: .bottom) {
                if mode != .transcript {
                    EmptyView()
                } else if !session.hasEnded {
                    // One container, so the floating glass layers composite together over the stream.
                    GlassEffectContainer {
                        VStack(spacing: 0) {
                            RequestCard(session: session).environment(\.cardFloats, true).padding(.horizontal, 12).padding(.bottom, 4)
                            ComposerBar(session: session, onOpenSettings: { showSettings = true })
                        }
                    }
                } else {
                    Text("This session has ended.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.bar)
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(session.summary?.title ?? "Session")
            .navigationSubtitle(subtitle(session))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                if !session.hasEnded {
                    Button("Rename…", systemImage: "pencil") {
                        newTitle = session.summary?.title ?? ""
                        renaming = true
                    }
                    Button("Session Settings", systemImage: "slider.horizontal.3") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { SessionSettingsSheet(session: session) }
            .alert("Rename Session", isPresented: $renaming) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { session.rename(newTitle) }
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

    var body: some View {
        TranscriptCollectionView(
            items: session.items, expanded: $session.expanded, canLoadOlder: session.canLoadOlder,
            loadOlder: session.loadOlder, image: session.image(for:), session: session)
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
