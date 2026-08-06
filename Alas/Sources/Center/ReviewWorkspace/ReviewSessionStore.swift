import Foundation

struct ReviewSessionStore {
    private let store: any PersistenceStoreProtocol
    private let url: URL

    init(store: any PersistenceStoreProtocol = PersistenceStore(), url: URL = Paths.reviewSessionsFile) {
        self.store = store
        self.url = url
    }

    func load(id: ReviewSessionID) throws -> ReviewSessionRecord? {
        let snapshot = try readSnapshot()
        return snapshot.recordsByID[id.rawValue]
    }

    func list(worktreeID: String) throws -> [ReviewSessionRecord] {
        let snapshot = try readSnapshot()
        return snapshot.recordsByID.values
            .filter { $0.target.worktreeID == worktreeID }
            .sorted(by: sortSessions)
    }

    func findActive(targetID: ReviewSessionID, excluding excludedID: ReviewSessionID? = nil) throws -> ReviewSessionRecord? {
        let snapshot = try readSnapshot()
        return snapshot.recordsByID.values
            .filter {
                $0.target.id == targetID &&
                    $0.id != excludedID &&
                    $0.status != .archived &&
                    $0.status != .reviewed
            }
            .sorted(by: sortSessions)
            .first
    }

    func save(_ record: ReviewSessionRecord) throws {
        var snapshot = try readSnapshot()
        snapshot.recordsByID[record.id.rawValue] = record
        try store.write(snapshot, to: url)
    }

    func replace(id oldID: ReviewSessionID, with record: ReviewSessionRecord) throws {
        var snapshot = try readSnapshot()
        if oldID != record.id {
            snapshot.recordsByID[oldID.rawValue] = nil
        }
        snapshot.recordsByID[record.id.rawValue] = record
        try store.write(snapshot, to: url)
    }

    func delete(id: ReviewSessionID) throws {
        var snapshot = try readSnapshot()
        snapshot.recordsByID[id.rawValue] = nil
        try store.write(snapshot, to: url)
    }

    private func readSnapshot() throws -> Snapshot {
        try store.readIfExists(Snapshot.self, from: url) ?? Snapshot(recordsByID: [:])
    }

    private func sortSessions(_ lhs: ReviewSessionRecord, _ rhs: ReviewSessionRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private struct Snapshot: Codable, Equatable {
        var recordsByID: [String: ReviewSessionRecord]
    }
}
