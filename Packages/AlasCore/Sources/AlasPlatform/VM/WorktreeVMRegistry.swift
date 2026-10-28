import Darwin
import Foundation
import AlasModel

/// Cross-process registry of worktree VMs, shared by every Alas instance.
/// Mutations run under an exclusive `flock` on `registry.json.lock`; owners
/// whose process died are cleared on every read so their slot frees itself.
public final class WorktreeVMRegistry: @unchecked Sendable {
    private let fileURL: URL
    private let lockURL: URL
    private let isAlive: @Sendable (VMRunOwner) -> Bool

    public init(
        fileURL: URL = Paths.vmsRoot.appendingPathComponent("registry.json"),
        isAlive: @escaping @Sendable (VMRunOwner) -> Bool = VMRunOwner.isAlive
    ) {
        self.fileURL = fileURL
        self.lockURL = fileURL.appendingPathExtension("lock")
        self.isAlive = isAlive
    }

    public func update<T>(_ body: (inout [WorktreeVMRecord]) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer {
            // Unlock before close: a forked child shares the descriptor.
            flock(fd, LOCK_UN)
            close(fd)
        }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var records = try read()
        for index in records.indices {
            if let owner = records[index].runOwner, !isAlive(owner) { records[index].runOwner = nil }
        }
        let result = try body(&records)
        try Self.encoder.encode(records).write(to: fileURL, options: .atomic)
        return result
    }

    public func snapshot() throws -> [WorktreeVMRecord] {
        try update { $0 }
    }

    private func read() throws -> [WorktreeVMRecord] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return try Self.decoder.decode([WorktreeVMRecord].self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
