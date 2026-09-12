import Foundation

struct CheckpointWriterLeaseRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let instanceID: String
    let sessionID: String
    let pid: Int64
    let createdAt: Date
}

struct CheckpointWriterLeaseStore: Sendable {
    private let root: URL

    init(root: URL = Paths.checkpointsRoot.appendingPathComponent("writer-leases", isDirectory: true)) {
        self.root = root
    }

    func acquire(lineageIDs: Set<String>, sessionID: String, instanceID: String) {
        guard !lineageIDs.isEmpty else { return }
        let record = CheckpointWriterLeaseRecord(
            schemaVersion: CheckpointWriterLeaseRecord.schemaVersion,
            instanceID: instanceID,
            sessionID: sessionID,
            pid: Int64(ProcessInfo.processInfo.processIdentifier),
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        for lineageID in lineageIDs where validLineageID(lineageID) {
            let directory = root.appendingPathComponent(lineageID, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: leaseURL(lineageID: lineageID, sessionID: sessionID), options: [.atomic])
        }
    }

    func release(sessionID: String) {
        guard let lineageDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for directory in lineageDirectories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(safeFileName(sessionID)))
        }
    }

    func activeLeaseCount(lineageID: String, excludingInstanceID: String) -> Int {
        guard validLineageID(lineageID) else { return 0 }
        let directory = root.appendingPathComponent(lineageID, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var count = 0
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(CheckpointWriterLeaseRecord.self, from: data),
                  record.schemaVersion == CheckpointWriterLeaseRecord.schemaVersion
            else {
                continue
            }
            guard ACPProcessLiveness.pidAlive(record.pid) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if record.instanceID != excludingInstanceID { count += 1 }
        }
        return count
    }

    private func leaseURL(lineageID: String, sessionID: String) -> URL {
        root
            .appendingPathComponent(lineageID, isDirectory: true)
            .appendingPathComponent(safeFileName(sessionID))
    }

    private func safeFileName(_ sessionID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = sessionID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(sanitized) + ".json"
    }

    private func validLineageID(_ lineageID: String) -> Bool {
        UUID(uuidString: lineageID)?.uuidString.lowercased() == lineageID
    }
}
