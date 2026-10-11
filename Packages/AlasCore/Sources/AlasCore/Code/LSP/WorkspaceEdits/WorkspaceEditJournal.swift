import Foundation

/// A manifest includes the snapshots so one atomic, owner-only file publishes
/// both the recovery instructions and their bytes. Contents never enter logs.
@MainActor
public final class WorkspaceEditJournal {
    public enum StepState: String, Codable, Sendable { case pending, started, confirmed, restored, unknown }
    public enum Status: String, Codable, Sendable { case prepared, applying, applied, recovered, recoveryRequired }

    public struct Entry: Codable, Sendable {
        public let id: Int
        public let step: WorkspaceEditPlanStep
        public var state: StepState
        public var observedAfter: [WorkspaceFileSnapshot]?

        public init(id: Int, step: WorkspaceEditPlanStep, state: StepState, observedAfter: [WorkspaceFileSnapshot]? = nil) {
            self.id = id
            self.step = step
            self.state = state
            self.observedAfter = observedAfter
        }
    }

    public struct Record: Codable, Sendable {
        public let id: UUID
        public var status: Status
        public var entries: [Entry]

        public init(id: UUID, status: Status, entries: [Entry]) {
            self.id = id
            self.status = status
            self.entries = entries
        }
    }

    nonisolated public let root: URL

    public init(root: URL = Paths.appSupportRoot.appendingPathComponent("workspace-edits", isDirectory: true)) {
        self.root = root
    }

    public func recordPrepared(_ plan: WorkspaceEditPlan) throws -> Record {
        let record = Record(id: UUID(), status: .prepared, entries: plan.steps.enumerated().map {
            Entry(id: $0.offset, step: $0.element, state: .pending)
        })
        try save(record)
        return record
    }

    public func save(_ record: Record) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let data = try JSONEncoder().encode(record)
        let temporary = root.appendingPathComponent(".\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close() }
        catch { try? handle.close()
        throw error }
        guard Darwin.rename(temporary.path, url(record.id).path) == 0 else { throw POSIXError(.EIO) }
        let directory = Darwin.open(root.path, O_RDONLY)
        guard directory >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(directory) }
        guard Darwin.fsync(directory) == 0 else { throw POSIXError(.EIO) }
    }

    public func record(_ id: UUID) throws -> Record {
        try JSONDecoder().decode(Record.self, from: Data(contentsOf: url(id)))
    }

    /// Retire only the specified owner's confirmed history. Other worktrees
    /// may share this journal directory and still hold their own markers.
    public func retireSuccessfulRecord(_ id: UUID) throws {
        let record = try record(id)
        guard record.status == .applied || record.status == .recovered else { return }
        try FileManager.default.removeItem(at: url(id))
    }

    public func records() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .map { try JSONDecoder().decode(Record.self, from: Data(contentsOf: $0)) }
    }

    /// Call once at launch with no live undo owners, and whenever live history
    /// discards an operation. Pending and uncertain records are never pruned.
    public func cleanSuccessfulRecords(retaining liveUndoIDs: Set<UUID>) throws {
        for record in try records() where !liveUndoIDs.contains(record.id) {
            if record.status == .applied || record.status == .recovered {
                try FileManager.default.removeItem(at: url(record.id))
            }
        }
    }

    private func url(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }
}
