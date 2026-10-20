import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public struct CheckpointWriterLeaseRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let instanceID: String
    public let sessionID: String
    public let pid: Int64
    public let zmxSessionName: String?
    public let remoteHost: String?
    public let createdAt: Date

    public init(schemaVersion: Int, instanceID: String, sessionID: String, pid: Int64, zmxSessionName: String?, remoteHost: String?, createdAt: Date) {
        self.schemaVersion = schemaVersion
        self.instanceID = instanceID
        self.sessionID = sessionID
        self.pid = pid
        self.zmxSessionName = zmxSessionName
        self.remoteHost = remoteHost
        self.createdAt = createdAt
    }
}

public struct CheckpointWriterLeaseStore: Sendable {
    private let root: URL
    private let activePersistentSessionNames: @Sendable () -> Set<String>

    public init(
        root: URL = Paths.checkpointsRoot.appendingPathComponent("writer-leases", isDirectory: true),
        activePersistentSessionNames: @escaping @Sendable () -> Set<String> = {
            Set(ZmxClient(env: ZmxEnv.resolve()).listSessions())
        }
    ) {
        self.root = root
        self.activePersistentSessionNames = activePersistentSessionNames
    }

    public func acquire(
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
        for storageKey in lineageIDs.compactMap(CheckpointLineage.storageKey(for:)) {
            let directory = root.appendingPathComponent(storageKey, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(safeFileName(sessionID: sessionID, instanceID: instanceID)), options: [.atomic])
        }
    }

    public func release(sessionID: String, instanceID: String) {
        guard let lineageDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for directory in lineageDirectories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(safeFileName(sessionID: sessionID, instanceID: instanceID)))
        }
    }

    public func activeLeaseCount(lineageID: String, excludingInstanceID: String) -> Int {
        guard let storageKey = CheckpointLineage.storageKey(for: lineageID) else { return 0 }
        let directory = root.appendingPathComponent(storageKey, isDirectory: true)
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

    private func safeFileName(sessionID: String, instanceID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let raw = "\(instanceID)-\(sessionID)"
        let sanitized = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(sanitized) + ".json"
    }
}
