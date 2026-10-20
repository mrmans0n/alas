import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

@MainActor
public protocol WorkspaceEditFileAccess {
    func snapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot
    func replace(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot) async throws
    func move(from: EditorDocumentID, to: EditorDocumentID, expectedSource: WorkspaceFileSnapshot, expectedDestination: WorkspaceFileSnapshot) async throws
}

public enum WorkspaceEditAccessError: LocalizedError, Sendable {
    case conflict(EditorDocumentID)
    case unsupportedTarget(EditorDocumentID)
    case ambiguousMutation(EditorDocumentID)

    public var errorDescription: String? {
        switch self {
        case .conflict: return "A workspace edit target changed. No conflicting content was overwritten."
        case .unsupportedTarget: return "This workspace edit path is unsupported. Targets must use the worktree's exact canonical path spelling; aliases such as /tmp versus /private/tmp are not supported."
        case .ambiguousMutation: return "The workspace edit result could not be confirmed. Explicit recovery is required."
        }
    }
}

/// A descriptor fingerprint also detects replacement or modification while a
/// bounded read is in flight. Final path checks still have an external-writer race.
public struct WorkspaceEditLocalSnapshot: Sendable {
    public struct Fingerprint: Equatable, Sendable {
        public let device: dev_t
        public let inode: ino_t
        public let size: off_t
        public let mode: mode_t
        public let modifiedSeconds: Int
        public let modifiedNanoseconds: Int
        public let changedSeconds: Int
        public let changedNanoseconds: Int

        public init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            mode = value.st_mode
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    public let snapshot: WorkspaceFileSnapshot
    public let fingerprint: Fingerprint?

    public static func fingerprint(at url: URL) throws -> Fingerprint? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Fingerprint(value)
    }

    public func revalidate(at url: URL) throws {
        guard try Self.fingerprint(at: url) == fingerprint else { throw WorkspaceEditAccessError.conflict(snapshot.document) }
    }

    public static func read(_ url: URL, _ document: EditorDocumentID) throws -> Self {
        guard let before = try fingerprint(at: url) else {
            return Self(snapshot: WorkspaceFileSnapshot(document: document, content: nil), fingerprint: nil)
        }
        guard before.mode & S_IFMT == S_IFREG else { throw WorkspaceEditAccessError.unsupportedTarget(document) }
        try WorkspaceEditSnapshotBudget.validateSize(Int(before.size))
        // O_NONBLOCK prevents a replaced FIFO from blocking open before fstat.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        guard fstat(descriptor, &value) == 0, Fingerprint(value) == before else { throw WorkspaceEditAccessError.conflict(document) }
        var data = Data()
        let cap = WorkspaceEditSnapshotBudget.fileBytes + 1
        while data.count < cap {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(64 * 1024, cap - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        try WorkspaceEditSnapshotBudget.validateSize(data.count)
        guard fstat(descriptor, &value) == 0, Fingerprint(value) == before else { throw WorkspaceEditAccessError.conflict(document) }
        let result = Self(snapshot: WorkspaceFileSnapshot(document: document, content: data, permissions: Int(before.mode & 0o7777)), fingerprint: before)
        try result.revalidate(at: url)
        return result
    }

    public init(snapshot: WorkspaceFileSnapshot, fingerprint: Fingerprint?) {
        self.snapshot = snapshot
        self.fingerprint = fingerprint
    }
}
