// SessionRegistry.swift
// Keyed dictionary of live TerminalSessions.

import Foundation

@MainActor
final class SessionRegistry {
    private var sessions: [String: TerminalSession] = [:]

    func session(for id: String) -> TerminalSession? { sessions[id] }
    func register(_ session: TerminalSession) { sessions[session.id] = session }

    func unregister(id: String) {
        sessions.removeValue(forKey: id)
    }

    func sessions(forWorktree worktreeId: String) -> [TerminalSession] {
        sessions.values.filter { $0.worktreeId == worktreeId }
    }

    var all: [TerminalSession] { Array(sessions.values) }
}
