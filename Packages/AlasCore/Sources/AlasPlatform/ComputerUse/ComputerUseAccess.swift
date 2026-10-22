import Foundation

public struct ComputerUseAppIdentity: Hashable, Sendable {
    public var name: String
    public var bundleID: String?
    public var pid: Int32

    public init(name: String, bundleID: String?, pid: Int32) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
    }

    public var approvalKey: String { bundleID ?? "pid:\(pid)" }
}

public enum ComputerUseApprovalChoice: Sendable { case allowForTurn, allowForSession, alwaysAllow, deny }

public enum ComputerUseGrantScope: String, Sendable { case turn, session, always }

public enum ComputerUseAppAccess: Equatable, Sendable {
    case blocked, allowed(ComputerUseGrantScope), denied, needsApproval
}

public enum ComputerUseBlocklist {
    public static let bundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
    ]

    public static func isBlocked(_ app: ComputerUseAppIdentity, hostPID: Int32) -> Bool {
        if app.pid == hostPID { return true }
        if let bundleID = app.bundleID { return bundleIDs.contains(bundleID) }
        return false
    }
}

/// Per-process approval state for all computer-use sessions. No I/O: the
/// caller persists "always allow" and supplies the persisted set.
@MainActor
public final class ComputerUseAccess {
    private struct SessionState {
        var turnGrants: Set<String> = []
        var sessionGrants: Set<String> = []
        var denied: Set<String> = []
        var stopped = false
    }

    private struct PendingEntry {
        var id: UUID
        var session: String
        var app: ComputerUseAppIdentity
    }

    private let hostPID: Int32
    private let alwaysAllowed: () -> Set<String>
    private var sessions: [String: SessionState] = [:]
    private var pendingEntries: [PendingEntry] = []

    public init(hostPID: Int32, alwaysAllowed: @escaping () -> Set<String>) {
        self.hostPID = hostPID
        self.alwaysAllowed = alwaysAllowed
    }

    public func access(for app: ComputerUseAppIdentity, session: String) -> ComputerUseAppAccess {
        if ComputerUseBlocklist.isBlocked(app, hostPID: hostPID) { return .blocked }
        let key = app.approvalKey
        let state = sessions[session] ?? SessionState()
        if state.denied.contains(key) { return .denied }
        if let bundleID = app.bundleID, alwaysAllowed().contains(bundleID) { return .allowed(.always) }
        if state.sessionGrants.contains(key) { return .allowed(.session) }
        if state.turnGrants.contains(key) { return .allowed(.turn) }
        return .needsApproval
    }

    public func record(_ choice: ComputerUseApprovalChoice, for app: ComputerUseAppIdentity, session: String) {
        let key = app.approvalKey
        var state = sessions[session] ?? SessionState()
        switch choice {
        case .allowForTurn:
            state.denied.remove(key)
            state.turnGrants.insert(key)
        case .allowForSession:
            state.denied.remove(key)
            state.sessionGrants.insert(key)
        case .alwaysAllow:
            state.denied.remove(key)
            // Persisting is the caller's job; a pid-only app can only be remembered for the session.
            if app.bundleID == nil { state.sessionGrants.insert(key) }
        case .deny:
            state.denied.insert(key)
        }
        sessions[session] = state
    }

    public func turnEnded(session: String) {
        guard var state = sessions[session] else { return }
        state.turnGrants = []
        state.denied = []
        sessions[session] = state
    }

    public func sessionEnded(session: String) {
        sessions[session] = nil
        pendingEntries.removeAll { $0.session == session }
    }

    public func stop(session: String) {
        sessions[session, default: SessionState()].stopped = true
    }

    public func resume(session: String) {
        sessions[session]?.stopped = false
    }

    public func isStopped(session: String) -> Bool {
        sessions[session]?.stopped ?? false
    }

    public func pendingApproval(session: String, app: ComputerUseAppIdentity) -> UUID {
        if let existing = pendingEntries.first(where: { $0.session == session && $0.app.approvalKey == app.approvalKey }) {
            return existing.id
        }
        let entry = PendingEntry(id: UUID(), session: session, app: app)
        pendingEntries.append(entry)
        return entry.id
    }

    public func resolvePending(_ id: UUID) -> (session: String, app: ComputerUseAppIdentity)? {
        guard let index = pendingEntries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = pendingEntries.remove(at: index)
        return (entry.session, entry.app)
    }

    public var pending: [(id: UUID, session: String, app: ComputerUseAppIdentity)] {
        pendingEntries.map { ($0.id, $0.session, $0.app) }
    }
}
