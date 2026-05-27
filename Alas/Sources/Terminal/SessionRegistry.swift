// SessionRegistry.swift
// Keyed dictionary of live TerminalSessions.

import Foundation
import Observation

/// `@Observable` so SwiftUI views that read from the registry
/// (e.g. `PaneLeafView` looking up its leaf's session) re-render when
/// `register` / `unregister` mutate `sessions`. Without this, the post-relaunch
/// restore path registers reattached sessions but the view stays on the
/// initial nil-lookup `Color.clear` until some other observable mutation
/// pokes the view tree.
@MainActor
@Observable
final class SessionRegistry {
    @ObservationIgnored
    private var _sessions: [String: TerminalSession] = [:]

    /// Backing access for the observable dictionary. Reads/writes funnel
    /// through this so the `@Observable` macro tracks dependencies on the
    /// dictionary as a whole — fine for our access pattern (single-key
    /// lookups + bounded full-collection scans).
    private var sessions: [String: TerminalSession] {
        get {
            access(keyPath: \.sessions)
            return _sessions
        }
        set {
            withMutation(keyPath: \.sessions) { _sessions = newValue }
        }
    }

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
