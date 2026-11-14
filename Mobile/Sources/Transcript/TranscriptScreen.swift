import AlasRemoteKit
import SwiftUI

/// One session's live transcript.
struct TranscriptScreen: View {
    @State private var session: TranscriptSession

    init(hub: HostHub, hostID: UUID, sessionId: String) {
        _session = State(initialValue: TranscriptSession(hub: hub, hostID: hostID, sessionId: sessionId))
    }

    var body: some View {
        TranscriptContent(session: session)
            .safeAreaInset(edge: .bottom) {
                if session.hasEnded {
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
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { session.open() }
            .onDisappear { session.close() }
    }

    private var subtitle: String {
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
                } else {
                    ProgressView()
                }
            }
        }
    }
}
