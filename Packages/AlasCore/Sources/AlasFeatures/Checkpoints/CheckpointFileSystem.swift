import CryptoKit
import Darwin
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public enum CheckpointFileSystemError: Error, Equatable, Sendable {
    case invalidRelativePath
    case unsafePath
    case unsupportedLeaf
    case invalidSymlinkTarget
    case posix(operation: String, code: Int32)
}

public enum CheckpointLeafRead: Equatable, Sendable {
    case regular(data: Data, executable: Bool)
    case symlink(Data)
}

public struct CheckpointLeafMetadata: Equatable, Sendable {
    public let kind: CheckpointLeafKind
    public let executable: Bool
    public let byteCount: Int64
    /// Nil when the file system can't tell; such a leaf is always re-read.
    public let identity: CheckpointStatIdentity?

    public init(kind: CheckpointLeafKind, executable: Bool, byteCount: Int64, identity: CheckpointStatIdentity? = nil) {
        self.kind = kind
        self.executable = executable
        self.byteCount = byteCount
        self.identity = identity
    }
}

/// What `lstat` says about a leaf. Any write changes the ctime, which can't be
/// set back, so an equal identity means unchanged bytes unless the change fell
/// within the timestamp granularity: callers re-read recently changed leaves.
public struct CheckpointStatIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    /// Nanoseconds since 1970.
    public let modified: Int64
    /// Nanoseconds since 1970.
    public let changed: Int64

    public init(device: UInt64, inode: UInt64, byteCount: Int64, modified: Int64, changed: Int64) {
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
        self.modified = modified
        self.changed = changed
    }

    /// Whether the leaf last changed before `date`.
    public func changedBefore(_ date: Date) -> Bool {
        let limit = Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded(.down))
        return max(modified, changed) < limit
    }
}

/// How much of a write must reach stable storage before it returns.
public enum CheckpointWriteDurability: Sendable {
    /// Sync the file and then its parent directory.
    case fileAndDirectory
    /// Sync the file only. The caller syncs the directory once for a batch.
    case file
    /// Sync nothing. Only for scratch files that nothing reads after a crash.
    case none
}

public protocol CheckpointFileSystem: Sendable {
    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead
    /// The reference of a regular file's bytes, without keeping them.
    func regularFileReference(root: URL, relativePath: String) throws -> CheckpointBlobReference
    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata?
    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL
    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws
    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws
    func createSymlink(target: Data, at url: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func moveExclusively(_ source: URL, to destination: URL) throws
    func removeIfPresent(_ url: URL) throws
    func list(_ url: URL) throws -> [URL]
    func fileData(_ url: URL) throws -> Data
    func synchronizeDirectory(_ url: URL) throws
    func write(_ data: Data, to url: URL, mode: mode_t, durability: CheckpointWriteDurability) throws
    func moveExclusively(_ source: URL, to destination: URL, synchronizingParent: Bool) throws
    func removeIfPresent(_ url: URL, synchronizingParent: Bool) throws
}

/// Test doubles that only implement the durable operations stay durable.
extension CheckpointFileSystem {
    public func regularFileReference(root: URL, relativePath: String) throws -> CheckpointBlobReference {
        guard case .regular(let data, _) = try readLeaf(root: root, relativePath: relativePath) else {
            throw CheckpointFileSystemError.unsupportedLeaf
        }
        return CheckpointBlobReference.make(for: data)
    }

    public func write(_ data: Data, to url: URL, mode: mode_t, durability: CheckpointWriteDurability) throws {
        try writeDurable(data, to: url, mode: mode)
    }

    public func moveExclusively(_ source: URL, to destination: URL, synchronizingParent: Bool) throws {
        try moveExclusively(source, to: destination)
    }

    public func removeIfPresent(_ url: URL, synchronizingParent: Bool) throws {
        try removeIfPresent(url)
    }
}

public struct LiveCheckpointFileSystem: CheckpointFileSystem, Sendable {
    public func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead {
        let leaf = try validateRelativePath(relativePath, under: root)
        let attributes = try lstat(at: leaf)
        if isRegular(attributes) {
            return .regular(data: try readData(at: leaf), executable: attributes.st_mode & 0o111 != 0)
        }
        if isSymlink(attributes) {
            return .symlink(try readLink(at: leaf, initialSize: Int(attributes.st_size)))
        }
        throw CheckpointFileSystemError.unsupportedLeaf
    }

    public func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata? {
        let leaf = try validateRelativePath(relativePath, under: root)
        var attributes = stat()
        guard Darwin.lstat(leaf.path, &attributes) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError("lstat")
        }
        if isRegular(attributes) {
            return .init(kind: .regular, executable: attributes.st_mode & 0o111 != 0, byteCount: attributes.st_size,
                         identity: .init(device: UInt64(attributes.st_dev), inode: UInt64(attributes.st_ino),
                                         byteCount: attributes.st_size,
                                         modified: nanoseconds(attributes.st_mtimespec), changed: nanoseconds(attributes.st_ctimespec)))
        }
        if isSymlink(attributes) {
            return .init(kind: .symlink, executable: false, byteCount: attributes.st_size)
        }
        throw CheckpointFileSystemError.unsupportedLeaf
    }

    public func regularFileReference(root: URL, relativePath: String) throws -> CheckpointBlobReference {
        let leaf = try validateRelativePath(relativePath, under: root)
        let descriptor = Darwin.open(leaf.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError("open") }
        defer { _ = Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0 else { throw posixError("fstat") }
        guard isRegular(attributes) else { throw CheckpointFileSystemError.unsupportedLeaf }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("read")
            }
            byteCount += Int64(count)
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0 ..< count])) }
        }
        return CheckpointBlobReference(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: byteCount)
    }

    public func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw CheckpointFileSystemError.invalidRelativePath }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw CheckpointFileSystemError.invalidRelativePath }

        let safeRoot = root.standardizedFileURL
        let rootAttributes = try lstat(at: safeRoot)
        guard isDirectory(rootAttributes), !isSymlink(rootAttributes) else {
            throw CheckpointFileSystemError.unsafePath
        }

        var parent = safeRoot
        for component in components.dropLast() {
            parent.appendPathComponent(String(component), isDirectory: true)
            var attributes = stat()
            guard Darwin.lstat(parent.path, &attributes) == 0 else {
                if errno == ENOENT { break }
                throw posixError("lstat")
            }
            guard isDirectory(attributes), !isSymlink(attributes) else {
                throw CheckpointFileSystemError.unsafePath
            }
        }

        let result = components.reduce(safeRoot) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL
        guard result.path.hasPrefix(safeRoot.path + "/") else {
            throw CheckpointFileSystemError.unsafePath
        }
        return result
    }

    public func createDirectoryExclusively(_ url: URL, mode: mode_t) throws {
        try requireSafeParent(of: url)
        guard Darwin.mkdir(url.path, mode) == 0 else { throw posixError("mkdir") }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    public func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws {
        try write(data, to: url, mode: mode, durability: .fileAndDirectory)
    }

    public func write(_ data: Data, to url: URL, mode: mode_t, durability: CheckpointWriteDurability) throws {
        try requireSafeParent(of: url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".alas-checkpoint-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else { throw posixError("open") }
        var descriptorIsOpen = true

        do {
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fchmod(descriptor, mode) == 0 else { throw posixError("fchmod") }
            if durability != .none {
                guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync") }
            }
            guard Darwin.close(descriptor) == 0 else { throw posixError("close") }
            descriptorIsOpen = false
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError("rename") }
            if durability == .fileAndDirectory { try synchronizeDirectory(url.deletingLastPathComponent()) }
        } catch {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            _ = Darwin.unlink(temporary.path)
            throw error
        }
    }

    public func createSymlink(target: Data, at url: URL) throws {
        try requireSafeParent(of: url)
        guard !target.contains(0) else { throw CheckpointFileSystemError.invalidSymlinkTarget }
        let bytes = Array(target) + [0]
        let result = bytes.withUnsafeBufferPointer { pointer in
            Darwin.symlink(pointer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { $0 }, url.path)
        }
        guard result == 0 else { throw posixError("symlink") }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    public func move(_ source: URL, to destination: URL) throws {
        try requireSafeParent(of: source)
        try requireSafeParent(of: destination)
        let sourceDirectory = try lstat(at: source.deletingLastPathComponent().standardizedFileURL)
        let destinationDirectory = try lstat(at: destination.deletingLastPathComponent().standardizedFileURL)
        guard sourceDirectory.st_dev == destinationDirectory.st_dev else {
            throw CheckpointFileSystemError.unsafePath
        }
        guard Darwin.rename(source.path, destination.path) == 0 else { throw posixError("rename") }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    public func moveExclusively(_ source: URL, to destination: URL) throws {
        try moveExclusively(source, to: destination, synchronizingParent: true)
    }

    public func moveExclusively(_ source: URL, to destination: URL, synchronizingParent: Bool) throws {
        try requireSafeParent(of: source)
        try requireSafeParent(of: destination)
        let sourceDirectory = try lstat(at: source.deletingLastPathComponent())
        let destinationDirectory = try lstat(at: destination.deletingLastPathComponent())
        guard sourceDirectory.st_dev == destinationDirectory.st_dev else { throw CheckpointFileSystemError.unsafePath }
        guard Darwin.link(source.path, destination.path) == 0 else { throw posixError("link") }
        guard Darwin.unlink(source.path) == 0 else { throw posixError("unlink") }
        if synchronizingParent { try synchronizeDirectory(destination.deletingLastPathComponent()) }
    }

    public func removeIfPresent(_ url: URL) throws {
        try removeIfPresent(url, synchronizingParent: true)
    }

    public func removeIfPresent(_ url: URL, synchronizingParent: Bool) throws {
        try requireSafeParent(of: url)
        if Darwin.unlink(url.path) == 0 {
            if synchronizingParent { try synchronizeDirectory(url.deletingLastPathComponent()) }
            return
        }
        if errno == ENOENT { return }
        if errno == EISDIR || errno == EPERM {
            guard Darwin.rmdir(url.path) == 0 else { throw posixError("rmdir") }
            if synchronizingParent { try synchronizeDirectory(url.deletingLastPathComponent()) }
            return
        }
        throw posixError("unlink")
    }

    public func list(_ url: URL) throws -> [URL] {
        try requireSafeDirectoryTree(at: url)
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
    }

    public func fileData(_ url: URL) throws -> Data {
        try requireSafeParent(of: url)
        return try readData(at: url)
    }

    public func synchronizeDirectory(_ url: URL) throws {
        try requireSafeDirectoryTree(at: url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw posixError("open") }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync") }
    }

    private func requireSafeParent(of url: URL) throws {
        try requireSafeDirectoryTree(at: url.deletingLastPathComponent())
    }

    private func requireSafeDirectoryTree(at url: URL) throws {
        let path = url.path
        guard path.hasPrefix("/") else { throw CheckpointFileSystemError.unsafePath }

        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            let attributes = try lstat(at: current)
            guard isDirectory(attributes), !isSymlink(attributes) else {
                throw CheckpointFileSystemError.unsafePath
            }
        }
    }

    private func readData(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError("open") }
        defer { _ = Darwin.close(descriptor) }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("read")
            }
            result.append(contentsOf: buffer[0 ..< Int(count)])
        }
    }

    private func readLink(at url: URL, initialSize: Int) throws -> Data {
        var capacity = max(initialSize + 1, 256)
        while true {
            var buffer = [UInt8](repeating: 0, count: capacity)
            let count = Darwin.readlink(url.path, &buffer, buffer.count)
            guard count >= 0 else { throw posixError("readlink") }
            if count < buffer.count { return Data(buffer[0 ..< Int(count)]) }
            capacity *= 2
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            while offset < rawBuffer.count {
                let pointer = rawBuffer.baseAddress!.advanced(by: offset)
                let count = Darwin.write(descriptor, pointer, rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write")
                }
                offset += Int(count)
            }
        }
    }

    private func lstat(at url: URL) throws -> stat {
        var attributes = stat()
        guard Darwin.lstat(url.path, &attributes) == 0 else { throw posixError("lstat") }
        return attributes
    }

    private func nanoseconds(_ time: timespec) -> Int64 { Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }
    private func isDirectory(_ attributes: stat) -> Bool { attributes.st_mode & S_IFMT == S_IFDIR }
    private func isRegular(_ attributes: stat) -> Bool { attributes.st_mode & S_IFMT == S_IFREG }
    private func isSymlink(_ attributes: stat) -> Bool { attributes.st_mode & S_IFMT == S_IFLNK }

    private func posixError(_ operation: String) -> CheckpointFileSystemError {
        .posix(operation: operation, code: errno)
    }

    public init() {
    }
}
