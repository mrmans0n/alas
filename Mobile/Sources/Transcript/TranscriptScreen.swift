import AlasRemoteKit
import SwiftUI

/// One session's live transcript.
struct TranscriptScreen: View {
    @Environment(SessionRegistry.self) private var registry
    let hostID: UUID
    let sessionId: String
    @State private var held: (session: TranscriptSession, token: ListenerToken)?
    @State private var showSettings = false
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        Group {
            if let session = held?.session {
                content(session)
            } else {
                Color(.systemBackground)
            }
        }
        .onAppear { acquire() }
        .onDisappear { held = nil }
    }

    private func acquire() {
        let (session, token) = registry.acquire(hostID: hostID, sessionId: sessionId)
        held = (session, token)
    }

    private func content(_ session: TranscriptSession) -> some View {
        TranscriptContent(session: session)
            .safeAreaInset(edge: .bottom) {
                if !session.hasEnded {
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
            loadOlder: session.loadOlder, image: session.image(for:))
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
