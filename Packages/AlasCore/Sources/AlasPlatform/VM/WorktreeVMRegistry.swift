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
        try withLock { records, _ in try body(&records) }
    }

    /// Keeps a stub record with `worktree`'s plain id while it has a Linux VM and no macOS VM, so
    /// builds that predate Linux guests (and see neither id they know) still count it as having a
    /// VM. The stub's guest OS no build decodes, so every build preserves it verbatim.
    public func syncLinuxAlias(worktree: String) throws {
        try withLock { records, foreign in
            foreign.removeAll { element in
                guard let object = element as? [String: Any] else { return false }
                return object["id"] as? String == worktree
                    && object["guestOS"] as? String == VMIdentity.aliasGuestRaw
            }
            let ids = Set(records.map(\.id))
            guard ids.contains(VMIdentity.recordID(worktree: worktree, guest: .linux)),
                !ids.contains(VMIdentity.recordID(worktree: worktree, guest: .macOS))
            else { return }
            foreign.append([
                "id": worktree, "guestOS": VMIdentity.aliasGuestRaw, "goldenBuild": "", "bundlePath": "",
                "createdAt": 0, "lastUsedAt": 0,
            ] as [String: Any])
        }
    }

    private func withLock<T>(_ body: (inout [WorktreeVMRecord], inout [Any]) throws -> T) throws -> T {
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
        var (records, foreign) = try load()
        for index in records.indices {
            if let owner = records[index].runOwner, !isAlive(owner) { records[index].runOwner = nil }
        }
        let result = try body(&records, &foreign)
        try write(records, foreign: foreign)
        return result
    }

    public func snapshot() throws -> [WorktreeVMRecord] {
        try update { $0 }
    }

    /// The id of every record, including ones this build cannot decode: a record from a newer
    /// build still means its worktree has a VM. Read without taking the lock or writing, since
    /// writes are atomic renames and a reader sees one whole file; an unparseable file throws
    /// instead of being quarantined.
    public func recordIDs() throws -> Set<String> {
        let (known, foreign) = try load(quarantining: false)
        let foreignIDs = foreign.compactMap { ($0 as? [String: Any])?["id"] as? String }
        return Set(known.map(\.id) + foreignIDs)
    }

    /// Records this build decodes, plus raw JSON of those it cannot (for
    /// example a newer build's guest OS), which are preserved verbatim.
    /// Foreign records are not visible to `update` bodies or slot accounting.
    /// An unparseable file is quarantined as `registry.json.corrupt`, or throws when not quarantining.
    private func load(quarantining: Bool = true) throws -> ([WorktreeVMRecord], [Any]) {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ([], [])
        }
        guard let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            guard !data.isEmpty else { return ([], []) }
            guard quarantining else { throw CocoaError(.fileReadCorruptFile) }
            try quarantine()
            return ([], [])
        }
        var known: [WorktreeVMRecord] = []
        var foreign: [Any] = []
        for element in elements {
            if JSONSerialization.isValidJSONObject(element),
                let raw = try? JSONSerialization.data(withJSONObject: element),
                let record = try? Self.decoder.decode(WorktreeVMRecord.self, from: raw)
            {
                known.append(record)
            } else {
                foreign.append(element)
            }
        }
        return (known, foreign)
    }

    private func quarantine() throws {
        let corrupt = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: corrupt)
        try FileManager.default.moveItem(at: fileURL, to: corrupt)
    }

    private func write(_ records: [WorktreeVMRecord], foreign: [Any]) throws {
        let encoded = try JSONSerialization.jsonObject(with: Self.encoder.encode(records)) as? [Any] ?? []
        let data = try JSONSerialization.data(
            withJSONObject: encoded + foreign, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
