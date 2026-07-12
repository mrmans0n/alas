import Foundation

/// Project MCP servers for remote sessions: stdio entries name commands on
/// the local machine, so a remote agent cannot execute them reliably. URL-based
/// servers remain reachable from the remote agent and are passed through.
enum ACPRemoteMCPFilter {
    static func split(_ servers: [ACPMCPServer]) -> (
        kept: [ACPMCPServer],
        droppedStdio: [String]
    ) {
        var kept: [ACPMCPServer] = []
        var droppedStdio: [String] = []

        for server in servers {
            switch server {
            case let .stdio(name, _, _, _):
                droppedStdio.append(name)
            case .http, .sse:
                kept.append(server)
            }
        }

        return (kept, droppedStdio)
    }
}
