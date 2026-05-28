import Foundation
import Combine

/// Narrow observable holder for the rapidly-mutating slice of session
/// state (transcript + stream state + pending permission). Lives inside
/// `ACPSession`. Views that only care about the transcript can observe
/// this instead of the full `ACPSession`, so updates to model/mode/setup
/// state no longer invalidate the message list.
@MainActor
final class ACPTranscript: ObservableObject {
    @Published var messages: [ACPMessage] = []
    @Published var streamingState: ACPSession.StreamingState = .idle
    @Published var pendingPermission: ACPSession.PendingPermission?
}
