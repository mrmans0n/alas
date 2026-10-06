import Foundation

enum LSPChipSeverity: Int, Comparable, Sendable {
    case ready
    case loading
    case problem

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Plain view of one chip, so ordering and collapsing stay pure.
struct LSPChipSnapshot: Equatable, Sendable {
    let id: String
    let language: String
    let root: String
    let severity: LSPChipSeverity
}

enum LSPServerChipAggregation {
    static let inlineLimit = 3

    enum Presentation: Equatable, Sendable {
        case inline
        case summary(ready: Int, total: Int, worst: LSPChipSeverity)
    }

    /// One entry per id, ordered by language, then root, then id.
    static func ordered(_ snapshots: [LSPChipSnapshot]) -> [LSPChipSnapshot] {
        var seen = Set<String>()
        return snapshots
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.language, $0.root, $0.id) < ($1.language, $1.root, $1.id) }
    }

    static func isInline(count: Int) -> Bool { count <= inlineLimit }

    static func presentation(_ snapshots: [LSPChipSnapshot]) -> Presentation {
        guard !isInline(count: snapshots.count) else { return .inline }
        return .summary(
            ready: snapshots.filter { $0.severity == .ready }.count,
            total: snapshots.count,
            worst: snapshots.map(\.severity).max() ?? .ready
        )
    }
}

/// What one toolbar chip shows: a live server, or why no server runs.
enum LSPServerChipModel: Identifiable {
    case serving(LSPServerStatus)
    case unavailable(language: String, reason: LSPServerUnavailableReason)

    var id: String {
        switch self {
        case .serving(let status): status.id.uuidString
        case .unavailable(let language, let reason): "unavailable|\(language)|\(reason.rawValue)"
        }
    }
}

@MainActor
extension LSPServerChipModel {
    var language: String {
        switch self {
        case .serving(let status): status.language
        case .unavailable(let language, _): language
        }
    }

    var snapshot: LSPChipSnapshot {
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
