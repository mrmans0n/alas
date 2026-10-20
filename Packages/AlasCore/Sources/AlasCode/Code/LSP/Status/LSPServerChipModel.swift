import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public enum LSPChipSeverity: Int, Comparable, Sendable {
    case ready
    case loading
    case problem

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Plain view of one chip, so ordering and collapsing stay pure.
public struct LSPChipSnapshot: Equatable, Sendable {
    public let id: String
    public let language: String
    public let root: String
    public let severity: LSPChipSeverity

    public init(id: String, language: String, root: String, severity: LSPChipSeverity) {
        self.id = id
        self.language = language
        self.root = root
        self.severity = severity
    }
}

public enum LSPServerChipAggregation: Sendable {
    public static let inlineLimit = 3

    public enum Presentation: Equatable, Sendable {
        case inline
        case summary(ready: Int, total: Int, worst: LSPChipSeverity)
    }

    /// One entry per id, ordered by language, then root, then id.
    public static func ordered(_ snapshots: [LSPChipSnapshot]) -> [LSPChipSnapshot] {
        var seen = Set<String>()
        return snapshots
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.language, $0.root, $0.id) < ($1.language, $1.root, $1.id) }
    }

    public static func isInline(count: Int) -> Bool { count <= inlineLimit }

    public static func isExpandedByDefault(count: Int) -> Bool { count <= 8 }

    public static func presentation(_ snapshots: [LSPChipSnapshot]) -> Presentation {
        guard !isInline(count: snapshots.count) else { return .inline }
        return .summary(
            ready: snapshots.filter { $0.severity == .ready }.count,
            total: snapshots.count,
            worst: snapshots.map(\.severity).max() ?? .ready
        )
    }
}

/// What one toolbar chip shows: a live server, or why no server runs.
public enum LSPServerChipModel: Identifiable, Sendable {
    case serving(LSPServerStatus)
    case unavailable(language: String, reason: LSPServerUnavailableReason)

    public var id: String {
        switch self {
        case .serving(let status): status.id.uuidString
        case .unavailable(let language, let reason): "unavailable|\(language)|\(reason.rawValue)"
        }
    }
}

@MainActor
extension LSPServerChipModel {
    public var language: String {
        switch self {
        case .serving(let status): status.language
        case .unavailable(let language, _): language
        }
    }

    public var snapshot: LSPChipSnapshot {
        switch self {
        case .serving(let status):
            let severity: LSPChipSeverity = switch status.phase {
            case .starting, .indexing: .loading
            case .ready: .ready
            case .crashed: .problem
            }
            return LSPChipSnapshot(id: id, language: status.language, root: status.root, severity: severity)
        case .unavailable(let language, _):
            return LSPChipSnapshot(id: id, language: language, root: "", severity: .problem)
        }
    }
}
