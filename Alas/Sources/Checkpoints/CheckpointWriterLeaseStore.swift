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
    private let activePersistentSessionNames: @Sendable () -> Set<String>?

    init(
        root: URL = Paths.checkpointsRoot.appendingPathComponent("writer-leases", isDirectory: true),
        activePersistentSessionNames: @escaping @Sendable () -> Set<String>? = {
            guard let names = ZmxClient(env: ZmxEnv.resolve()).listSessionsIfAvailable() else { return nil }
            return Set(names)
        }
    ) {
        self.root = root
        self.activePersistentSessionNames = activePersistentSessionNames
    }

    /// Acquires a writer lease. Returns `false` when admission must be
    /// refused — either a scheduled cleanup holds the deletion lock, or the
    /// lease could not be persisted (unwritable cache, full disk). Both mean
    /// cleanup would observe zero writers; the caller treats this as a
    /// failed launch.
    @discardableResult
    func acquire(
        lineageIDs: Set<String>,
        sessionID: String,
        instanceID: String,
        zmxSessionName: String?,
        remoteHost: String?,
        pid: Int64 = Int64(ProcessInfo.processInfo.processIdentifier)
    ) -> Bool {
        guard !lineageIDs.isEmpty else { return true }
        let validIDs = lineageIDs.filter(validLineageID)
        guard !validIDs.isEmpty else { return true }
        // Scheduled cleanup holds the per-lineage deletion lock across its
        // final lease checks and the staging rename. The lock is held from
        // the admission probe through the lease write so a cleanup racing
        // after the probe cannot rename the worktree while a lease-less
        // writer is launching; without it cleanup would observe zero
        // writers and destroy the checkout underneath the new session.
        let admissionLease = holdDeletionLock(
            lineageIDs: validIDs,
            instanceID: instanceID,
            sessionID: sessionID
        )
        guard admissionLease != nil else { return false }
        defer { _ = admissionLease }
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
        guard let data = try? encoder.encode(record) else { return false }
        for lineageID in validIDs {
            let directory = root.appendingPathComponent(lineageID, isDirectory: true)
            let leaseFile = leaseURL(lineageID: lineageID, sessionID: sessionID, instanceID: instanceID)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: leaseFile, options: [.atomic])
            } catch {
                // An unwritten lease is indistinguishable from no writer:
                // scheduled cleanup would count zero and remove the
                // worktree underneath this session. Roll back this lineage
                // and any earlier ones, then refuse admission.
                for writtenID in [lineageID] + validIDs.prefix(while: { $0 != lineageID }) {
                    try? FileManager.default.removeItem(
                        at: leaseURL(lineageID: writtenID, sessionID: sessionID, instanceID: instanceID)
                    )
                }
                return false
            }
        }
        return true
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

    // MARK: - Deletion coordination

    /// Held by scheduled worktree cleanup across its final lease checks and
    /// the staging rename; also locked (non-blocking) by writer admission
    /// before a lease file is written. This serializes the two operations
    /// across processes: a writer either admits while cleanup holds the
    /// lock (cleanup sees the lease file and refuses), or after cleanup
    /// finished (the worktree is already unregistered) — never during the
    /// rename, where a fresh lease would be invisible to the check and the
    /// worktree would be destroyed underneath the new writer.
    private func deletionLockURL(lineageID: String) -> URL {
        root.appendingPathComponent(lineageID, isDirectory: true)
            .appendingPathComponent("deletion.lock", isDirectory: false)
    }

    func holdDeletionLock(
        lineageIDs: Set<String>,
        instanceID: String,
        sessionID: String
    ) -> CheckpointDeletionLease? {
        let validIDs = lineageIDs.filter(validLineageID)
        guard !validIDs.isEmpty else { return nil }
        var acquiredHandles: [FileHandle] = []
        for lineageID in validIDs {
            let url = deletionLockURL(lineageID: lineageID)
            let directory = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forUpdating: url)
                guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                    let error = errno
                    try? handle.close()
                    throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
                }
                acquiredHandles.append(handle)
            } catch {
                for held in acquiredHandles {
                    _ = flock(held.fileDescriptor, LOCK_UN)
                    try? held.close()
                }
                return nil
            }
        }
        return CheckpointDeletionLease(
            handles: acquiredHandles,
            instanceID: instanceID,
            sessionID: sessionID
        )
    }

    /// Non-blocking admission probe: returns `false` while any scheduled
    /// cleanup holds the deletion lock for these lineages, so a terminal or
    /// ACP session cannot attach to a worktree that is about to be renamed
    /// away. Called before the lease file is written.
    func admissionIsAllowed(lineageIDs: Set<String>) -> Bool {
        for lineageID in lineageIDs where validLineageID(lineageID) {
            guard let handle = try? FileHandle(forUpdating: deletionLockURL(lineageID: lineageID)) else {
                continue
            }
            let blocked = flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) != 0
            if !blocked {
                _ = flock(handle.fileDescriptor, LOCK_UN)
            }
            try? handle.close()
            if blocked {
                return false
            }
        }
        return true
    }
}

/// Closes (and thereby releases) the flock handles when it leaves scope.
final class CheckpointDeletionLease: @unchecked Sendable {
    private let handles: [FileHandle]

    init(handles: [FileHandle], instanceID: String, sessionID: String) {
        self.handles = handles
        self.instanceID = instanceID
        self.sessionID = sessionID
    }

    let instanceID: String
    let sessionID: String

    deinit {
        for handle in handles {
            _ = flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
        }
    }
}

extension CheckpointWriterLeaseStore {
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

    /// Returns nil when cleanup cannot reliably inspect every terminal lease.
    /// Missing lineage directories are safe: no writer has created a lease there.
    func activeLeaseCountIfReadable(lineageID: String, excludingInstanceID: String) -> Int? {
        guard validLineageID(lineageID) else { return nil }
        let directory = root.appendingPathComponent(lineageID, isDirectory: true)
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return 0
        } catch {
            return nil
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
                return nil
            }
            guard recordIsActive(record, persistentSessionNames: persistentSessionNames) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if record.instanceID != excludingInstanceID { count += 1 }
        }
        return count
    }

    private func recordIsActive(_ record: CheckpointWriterLeaseRecord, persistentSessionNames: Set<String>?) -> Bool {
        if ACPProcessLiveness.pidMatchesLease(pid: record.pid, createdAt: record.createdAt) { return true }
        guard let zmxSessionName = record.zmxSessionName else { return false }
        if record.remoteHost != nil { return true }
        guard let persistentSessionNames else { return true }
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
