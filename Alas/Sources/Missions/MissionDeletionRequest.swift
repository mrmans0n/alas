import Foundation

/// A pending Mission deletion awaiting confirmation, together with its dialog copy.
enum MissionDeletionRequest: Equatable, Identifiable {
    case single(id: MissionID, title: String)
    case completed([MissionID])

    static let consequence = """
    This removes the Mission and its history from Alas. Worktrees, branches, \
    and running agents are left untouched.
    """

    var id: String {
        switch self {
        case .single(let id, _):
            "single:\(id.rawValue)"
        case .completed(let ids):
            "completed:\(ids.map(\.rawValue).joined(separator: ","))"
        }
    }

    var missionIDs: [MissionID] {
        switch self {
        case .single(let id, _): [id]
        case .completed(let ids): ids
        }
    }

    var confirmationTitle: String {
        switch self {
        case .single(_, let title):
            "Delete \"\(title)\"?"
        case .completed(let ids):
            "Delete \(ids.count) completed \(Self.missionNoun(ids.count))?"
        }
    }

    var confirmationButtonTitle: String {
        switch self {
        case .single:
            "Delete Mission"
        case .completed(let ids):
            "Delete \(ids.count) \(Self.missionNoun(ids.count))"
        }
    }

    private static func missionNoun(_ count: Int) -> String {
        count == 1 ? "Mission" : "Missions"
    }
}
