import Foundation
import Observation

/// One `TranscriptSession` per open transcript, shared by every screen showing it so the
/// draft and pending requests are the same everywhere. Opened by the first holder, closed
/// when the last token is released; a closed session stays so its draft survives a tab switch.
/// ponytail: closed sessions live for the app's life; evict idle ones if memory ever matters.
@MainActor @Observable
final class SessionRegistry {
    @ObservationIgnored private let hub: HostHub
    @ObservationIgnored private var entries: [Key: (session: TranscriptSession, holders: Int)] = [:]

    private struct Key: Hashable {
        let hostID: UUID
        let sessionId: String
    }

    init(hub: HostHub) {
        self.hub = hub
    }

    func acquire(hostID: UUID, sessionId: String) -> (TranscriptSession, ListenerToken) {
        let key = Key(hostID: hostID, sessionId: sessionId)
        var entry = entries[key] ?? (TranscriptSession(hub: hub, hostID: hostID, sessionId: sessionId), 0)
        if entry.holders == 0 { entry.session.open() }
        entry.holders += 1
        entries[key] = entry
        let session = entry.session
        return (session, ListenerToken { [weak self] in
            guard let self, let current = entries[key] else { return }
            entries[key]?.holders -= 1
            if current.holders == 1 { current.session.close() }
        })
    }

    func live(hostID: UUID, sessionId: String) -> TranscriptSession? {
        entries[Key(hostID: hostID, sessionId: sessionId)]?.session
    }
}
