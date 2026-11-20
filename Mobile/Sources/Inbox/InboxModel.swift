import AlasRemoteKit
import Foundation
import Observation

/// Sessions waiting on the user, and the registry holds taken while the Inbox is on screen.
@MainActor @Observable
final class InboxModel {
    struct Entry: Identifiable, Equatable {
        let id: RemoteSessionCatalog.SessionID
        let route: SessionRoute
        let hostName: String
        let title: String
    }

    private(set) var sessions: [SessionRoute: TranscriptSession] = [:]
    /// Sessions whose request was answered here, hidden until their summary stops listing them.
    /// Pruned on every summary change, including while the Inbox is hidden, so a later wait shows.
    var answered: Set<SessionRoute> = []
    @ObservationIgnored private var tokens: [SessionRoute: ListenerToken] = [:]

    /// Active sessions awaiting permission or input, across every host. Summaries only, so the
    /// tab badge can use it without holding any session.
    static func entries(in hub: HostHub) -> [Entry] {
        RemoteSessionCatalog.attentionEntries(from: hub.sessionSources).map { entry in
            Entry(id: entry.id, route: SessionRoute(hostID: entry.route.hostID, sessionId: entry.route.sessionId),
                  hostName: entry.hostName, title: entry.title)
        }
    }

    /// Holds exactly the sessions in `entries`.
    func sync(_ entries: [Entry], registry: SessionRegistry) {
        let wanted = Set(entries.map(\.route))
        for route in tokens.keys where !wanted.contains(route) {
            tokens[route] = nil
            sessions[route] = nil
        }
        for route in wanted where tokens[route] == nil {
            let (session, token) = registry.acquire(hostID: route.hostID, sessionId: route.sessionId)
            tokens[route] = token
            sessions[route] = session
        }
    }

    func releaseAll() {
        tokens.removeAll()
        sessions.removeAll()
    }
}
