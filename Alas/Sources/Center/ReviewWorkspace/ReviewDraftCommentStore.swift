import Foundation

struct ReviewDraftCommentStore {
    private let store: any PersistenceStoreProtocol
    private let url: URL

    init(store: any PersistenceStoreProtocol = PersistenceStore(), url: URL = Paths.reviewDraftCommentsFile) {
        self.store = store
        self.url = url
    }

    func load(sessionID: ReviewDraftSessionID) throws -> [ReviewDraftComment] {
        let snapshot = try readSnapshot()
        return (snapshot.commentsBySessionID[sessionID.rawValue] ?? []).sorted(by: sortComments)
    }

    func save(_ comment: ReviewDraftComment) throws {
        var snapshot = try readSnapshot()
        var comments = snapshot.commentsBySessionID[comment.sessionID.rawValue] ?? []

        if let index = comments.firstIndex(where: { $0.id == comment.id }) {
            comments[index] = comment
        } else {
            comments.append(comment)
        }

        snapshot.commentsBySessionID[comment.sessionID.rawValue] = comments
        try store.write(snapshot, to: url)
    }

    func delete(commentID: String, sessionID: ReviewDraftSessionID) throws {
        var snapshot = try readSnapshot()
        var comments = snapshot.commentsBySessionID[sessionID.rawValue] ?? []
        comments.removeAll { $0.id == commentID }

        if comments.isEmpty {
            snapshot.commentsBySessionID.removeValue(forKey: sessionID.rawValue)
        } else {
            snapshot.commentsBySessionID[sessionID.rawValue] = comments
        }

        try store.write(snapshot, to: url)
    }

    func delete(sessionID: ReviewDraftSessionID) throws {
        var snapshot = try readSnapshot()
        snapshot.commentsBySessionID.removeValue(forKey: sessionID.rawValue)
        try store.write(snapshot, to: url)
    }

    private func readSnapshot() throws -> Snapshot {
        try store.readIfExists(Snapshot.self, from: url) ?? Snapshot(commentsBySessionID: [:])
    }

    private func sortComments(_ lhs: ReviewDraftComment, _ rhs: ReviewDraftComment) -> Bool {
        if lhs.path != rhs.path {
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        if lhs.normalizedLineRange.lowerBound != rhs.normalizedLineRange.lowerBound {
            return lhs.normalizedLineRange.lowerBound < rhs.normalizedLineRange.lowerBound
        }
        return lhs.createdAt < rhs.createdAt
    }

    private struct Snapshot: Codable, Equatable {
        var commentsBySessionID: [String: [ReviewDraftComment]]
    }
}
