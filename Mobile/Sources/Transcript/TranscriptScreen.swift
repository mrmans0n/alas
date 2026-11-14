import AlasRemoteKit
import SwiftUI

/// One session's live transcript.
struct TranscriptScreen: View {
    @Environment(SessionRegistry.self) private var registry
    let hostID: UUID
    let sessionId: String
    @State private var held: (session: TranscriptSession, token: ListenerToken)?

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
                    ComposerBar(session: session)
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
