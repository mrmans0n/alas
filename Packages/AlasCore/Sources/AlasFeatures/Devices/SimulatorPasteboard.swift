import Foundation
import SQLite3

/// An app's "Paste from Other Apps" permission on a simulator, from its
/// `TCC.db`. Pasting with ⌘V sent as HID keys needs it: iOS doesn't count the
/// simulator's key events as a user paste.
public enum SimulatorPasteAccess: Equatable, Sendable {
    case notSet, allowed, denied

    /// Read-only: the simulator's tccd owns the database. Anything unreadable,
    /// and any value but allowed (2) or denied (0), counts as not set.
    public static func read(database: URL, bundleID: String) -> SimulatorPasteAccess {
        guard FileManager.default.fileExists(atPath: database.path) else { return .notSet }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return .notSet
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        let sql = "SELECT auth_value FROM access WHERE service = 'kTCCServicePasteboard' AND client = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return .notSet }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, bundleID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return .notSet }
        switch sqlite3_column_int(statement, 0) {
        case 2: return .allowed
        case 0: return .denied
        default: return .notSet
        }
    }

    /// What puts this state back after a grant; nil when the grant changed nothing.
    public var restore: SimulatorPrivacyAction? {
        switch self {
        case .notSet: .reset
        case .denied: .revoke
        case .allowed: nil
        }
    }
}

public protocol SimulatorPasteboardControl: Sendable {
    func read(udid: String) async throws -> String
    func write(udid: String, text: String) async throws
    func access(udid: String, bundleID: String) async -> SimulatorPasteAccess
    func setAccess(udid: String, bundleID: String, _ action: SimulatorPrivacyAction) async throws
}

public struct LiveSimulatorPasteboard: SimulatorPasteboardControl {
    public init() {}

    public func read(udid: String) async throws -> String { try await SimulatorControl.pbpaste(udid: udid) }

    public func write(udid: String, text: String) async throws { try await SimulatorControl.pbcopy(udid: udid, text: text) }

    public func access(udid: String, bundleID: String) async -> SimulatorPasteAccess {
        SimulatorPasteAccess.read(database: SimulatorControl.tccDatabase(udid: udid), bundleID: bundleID)
    }

    public func setAccess(udid: String, bundleID: String, _ action: SimulatorPrivacyAction) async throws {
        try await SimulatorControl.pasteboardPrivacy(udid: udid, action: action, bundleID: bundleID)
    }
}
