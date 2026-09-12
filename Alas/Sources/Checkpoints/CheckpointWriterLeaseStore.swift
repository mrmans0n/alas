import Foundation

struct CheckpointWriterLeaseRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let instanceID: String
    let sessionID: String
    let pid: Int64
    let zmxSessionName: String?
    let remoteHost: String?
    let createdAt: Date
}

struct CheckpointWriterLeaseStore: Sendable {
    private let root: URL
    private let activePersistentSessionNames: @Sendable () -> Set<String>

    init(
        root: URL = Paths.checkpointsRoot.appendingPathComponent("writer-leases", isDirectory: true),
        activePersistentSessionNames: @escaping @Sendable () -> Set<String> = {
            Set(ZmxClient(env: ZmxEnv.resolve()).listSessions())
        }
    ) {
        self.root = root
        self.activePersistentSessionNames = activePersistentSessionNames
    }

    func acquire(
        lineageIDs: Set<String>,
        sessionID: String,
        instanceID: String,
        zmxSessionName: String?,
        remoteHost: String?,
        pid: Int64 = Int64(ProcessInfo.processInfo.processIdentifier)
    ) {
        guard !lineageIDs.isEmpty else { return }
        let record = CheckpointWriterLeaseRecord(
            schemaVersion: CheckpointWriterLeaseRecord.schemaVersion,
            instanceID: instanceID,
            sessionID: sessionID,
            pid: pid,
            zmxSessionName: zmxSessionName,
            remoteHost: remoteHost,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        for lineageID in lineageIDs where validLineageID(lineageID) {
            let directory = root.appendingPathComponent(lineageID, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: leaseURL(lineageID: lineageID, sessionID: sessionID, instanceID: instanceID), options: [.atomic])
        }
    }

    func release(sessionID: String, instanceID: String) {
        guard let lineageDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for directory in lineageDirectories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(safeFileName(sessionID: sessionID, instanceID: instanceID)))
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
        let persistentSessionNames = activePersistentSessionNames()
        var count = 0
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(CheckpointWriterLeaseRecord.self, from: data),
                  record.schemaVersion == CheckpointWriterLeaseRecord.schemaVersion
            else {
                continue
            }
            guard recordIsActive(record, persistentSessionNames: persistentSessionNames) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if record.instanceID != excludingInstanceID { count += 1 }
        }
        return count
    }

    private func recordIsActive(_ record: CheckpointWriterLeaseRecord, persistentSessionNames: Set<String>) -> Bool {
        if ACPProcessLiveness.pidMatchesLease(pid: record.pid, createdAt: record.createdAt) { return true }
        guard let zmxSessionName = record.zmxSessionName else { return false }
        if record.remoteHost != nil { return true }
        return persistentSessionNames.contains(zmxSessionName)
    }

    private func leaseURL(lineageID: String, sessionID: String, instanceID: String) -> URL {
        root
            .appendingPathComponent(lineageID, isDirectory: true)
            .appendingPathComponent(safeFileName(sessionID: sessionID, instanceID: instanceID))
    }

    private func safeFileName(sessionID: String, instanceID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let raw = "\(instanceID)-\(sessionID)"
        let sanitized = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(sanitized) + ".json"
    }

    private func validLineageID(_ lineageID: String) -> Bool {
        UUID(uuidString: lineageID)?.uuidString.lowercased() == lineageID
    }
}
