import Foundation
import Observation

/// Sessions waiting on the user, and the registry holds taken while the Inbox is on screen.
@MainActor @Observable
final class InboxModel {
    struct Entry: Identifiable, Equatable {
        let route: SessionRoute
        let hostName: String
        let title: String
        var id: SessionRoute { route }
    }

    private(set) var sessions: [SessionRoute: TranscriptSession] = [:]
    @ObservationIgnored private var tokens: [SessionRoute: ListenerToken] = [:]

    /// Active sessions awaiting permission or input, across every host. Summaries only, so the
    /// tab badge can use it without holding any session.
    static func entries(in hub: HostHub) -> [Entry] {
        hub.hosts.flatMap { host in
            hub.sessions(of: host.id)
                .filter { $0.isActive && ($0.status == "awaitingPermission" || $0.status == "awaitingInput") }
                .map { Entry(route: SessionRoute(hostID: host.id, sessionId: $0.id), hostName: host.name, title: $0.title) }
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
