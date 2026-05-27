import Foundation

enum SQLiteError: Error, LocalizedError {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String, sql: String)
    case bindFailed(code: Int32, message: String, index: Int)

    var errorDescription: String? {
        switch self {
        case .openFailed(_, let m): return "sqlite open failed: \(m)"
        case .prepareFailed(_, let m, let sql): return "sqlite prepare failed (\(m)) for: \(sql)"
        case .stepFailed(_, let m, let sql): return "sqlite step failed (\(m)) for: \(sql)"
        case .bindFailed(_, let m, let i): return "sqlite bind failed at \(i): \(m)"
        }
    }
}
