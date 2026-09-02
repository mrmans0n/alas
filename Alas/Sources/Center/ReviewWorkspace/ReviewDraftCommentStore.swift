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

    func loadAll() throws -> [ReviewDraftComment] {
        let snapshot = try readSnapshot()
        return snapshot.commentsBySessionID.values.flatMap { $0 }.sorted(by: sortComments)
    }

    func snapshot() throws -> ReviewDraftCommentStoreSnapshot {
        let snapshot = try readSnapshot()
        return ReviewDraftCommentStoreSnapshot(commentsBySessionID: snapshot.commentsBySessionID)
    }

    func restore(_ saved: ReviewDraftCommentStoreSnapshot) throws {
        try store.write(Snapshot(commentsBySessionID: saved.commentsBySessionID), to: url)
    }

    func find(commentID: String) throws -> ReviewDraftComment? {
        let snapshot = try readSnapshot()
        for comments in snapshot.commentsBySessionID.values {
            if let match = comments.first(where: { $0.id == commentID }) {
                return match
            }
        }
        return nil
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

    func migrate(from sourceID: ReviewDraftSessionID, to targetID: ReviewDraftSessionID) throws {
        guard sourceID != targetID else { return }
        var snapshot = try readSnapshot()
        let moved = snapshot.commentsBySessionID.removeValue(forKey: sourceID.rawValue) ?? []
        guard !moved.isEmpty else {
            try store.write(snapshot, to: url)
            return
        }

        var mergedByID: [String: ReviewDraftComment] = [:]
        for comment in snapshot.commentsBySessionID[targetID.rawValue] ?? [] {
            mergedByID[comment.id] = comment
        }
        for comment in moved {
            var rekeyed = comment
            rekeyed.sessionID = targetID
            mergedByID[rekeyed.id] = rekeyed
        }
        snapshot.commentsBySessionID[targetID.rawValue] = Array(mergedByID.values)
        try store.write(snapshot, to: url)
    }

    private func readSnapshot() throws -> Snapshot {
        try store.readIfExists(Snapshot.self, from: url) ?? Snapshot(commentsBySessionID: [:])
    }

    private func sortComments(_ lhs: ReviewDraftComment, _ rhs: ReviewDraftComment) -> Bool {
        if lhs.path != rhs.path {
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        if let lhsRange = lhs.normalizedLineRange, let rhsRange = rhs.normalizedLineRange {
            if lhsRange.lowerBound != rhsRange.lowerBound {
                return lhsRange.lowerBound < rhsRange.lowerBound
            }
            if lhsRange.upperBound != rhsRange.upperBound {
                return lhsRange.upperBound < rhsRange.upperBound
            }
        } else if lhs.normalizedLineRange != nil {
            return false
        } else if rhs.normalizedLineRange != nil {
            return true
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    private struct Snapshot: Codable, Equatable {
        var commentsBySessionID: [String: [ReviewDraftComment]]
    }
}

struct ReviewDraftCommentStoreSnapshot: Equatable {
    fileprivate var commentsBySessionID: [String: [ReviewDraftComment]]
}
