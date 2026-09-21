import Foundation

enum SQLiteError: Error, LocalizedError {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String, sql: String)
    case bindFailed(code: Int32, message: String, index: Int)

    // Intentionally omits the `sql` payload: this description feeds
    // user-facing alerts (e.g. "Run History Failed"), and a raw multi-line
    // SQL statement isn't actionable there. The full statement is still
    // available via `String(describing:)` for diagnostic logging.
    var errorDescription: String? {
        switch self {
        case .openFailed(_, let m): return "sqlite open failed: \(m)"
        case .prepareFailed(_, let m, _): return "sqlite prepare failed: \(m)"
        case .stepFailed(_, let m, _): return "sqlite step failed: \(m)"
        case .bindFailed(_, let m, let i): return "sqlite bind failed at \(i): \(m)"
        }
    }
}
