import Foundation
import SQLite3
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

package enum ACPSessionPersistenceError: Error, LocalizedError {
    case brokerValueOutOfRange(field: String, value: UInt64)

    package var errorDescription: String? {
        switch self {
        case .brokerValueOutOfRange(let field, let value):
            return "ACP broker \(field) is out of SQLite Int64 range: \(value)"
        }
    }
}

/// Why a lease was not taken.
public enum ACPSessionLeaseRefusal: Error, Equatable, Sendable {
    /// The session is archived; nobody drives it again.
    case archived
}
