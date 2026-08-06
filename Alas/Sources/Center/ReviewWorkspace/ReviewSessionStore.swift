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
        if let record = snapshot.recordsByID[id.rawValue] {
            return record
        }
        var currentID = id.rawValue
        var seen: Set<String> = []
        while let replacementID = snapshot.replacementIDsByOldID[currentID],
              seen.insert(currentID).inserted {
            if let record = snapshot.recordsByID[replacementID] {
                return record
            }
            currentID = replacementID
        }
        return nil
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
            snapshot.replacementIDsByOldID[oldID.rawValue] = record.id.rawValue
            for (alias, replacementID) in snapshot.replacementIDsByOldID where replacementID == oldID.rawValue {
                snapshot.replacementIDsByOldID[alias] = record.id.rawValue
            }
        }
        snapshot.recordsByID[record.id.rawValue] = record
        try store.write(snapshot, to: url)
    }

    func delete(id: ReviewSessionID) throws {
        var snapshot = try readSnapshot()
        snapshot.recordsByID[id.rawValue] = nil
        snapshot.replacementIDsByOldID[id.rawValue] = nil
        try store.write(snapshot, to: url)
    }

    private func readSnapshot() throws -> Snapshot {
        try store.readIfExists(Snapshot.self, from: url) ?? Snapshot(recordsByID: [:], replacementIDsByOldID: [:])
    }

    private func sortSessions(_ lhs: ReviewSessionRecord, _ rhs: ReviewSessionRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private struct Snapshot: Codable, Equatable {
        var recordsByID: [String: ReviewSessionRecord]
        var replacementIDsByOldID: [String: String] = [:]

        init(recordsByID: [String: ReviewSessionRecord], replacementIDsByOldID: [String: String] = [:]) {
            self.recordsByID = recordsByID
            self.replacementIDsByOldID = replacementIDsByOldID
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            recordsByID = try container.decode([String: ReviewSessionRecord].self, forKey: .recordsByID)
            replacementIDsByOldID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .replacementIDsByOldID
            ) ?? [:]
        }
    }
}
