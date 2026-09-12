import Darwin
import Foundation

enum CheckpointFileSystemError: Error, Equatable, Sendable {
    case invalidRelativePath
    case unsafePath
    case unsupportedLeaf
    case invalidSymlinkTarget
    case posix(operation: String, code: Int32)
}

enum CheckpointLeafRead: Equatable, Sendable {
    case regular(data: Data, executable: Bool)
    case symlink(Data)
}

struct CheckpointLeafMetadata: Equatable, Sendable {
    let kind: CheckpointLeafKind
    let executable: Bool
    let byteCount: Int64
}

protocol CheckpointFileSystem: Sendable {
    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead
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
}

struct LiveCheckpointFileSystem: CheckpointFileSystem, Sendable {
    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead {
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

    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata? {
        let leaf = try validateRelativePath(relativePath, under: root)
        var attributes = stat()
        guard Darwin.lstat(leaf.path, &attributes) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError("lstat")
        }
        if isRegular(attributes) {
            return .init(kind: .regular, executable: attributes.st_mode & 0o111 != 0, byteCount: attributes.st_size)
        }
        if isSymlink(attributes) {
            return .init(kind: .symlink, executable: false, byteCount: attributes.st_size)
        }
        throw CheckpointFileSystemError.unsupportedLeaf
    }

    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL {
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

    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws {
        try requireSafeParent(of: url)
        guard Darwin.mkdir(url.path, mode) == 0 else { throw posixError("mkdir") }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws {
        try requireSafeParent(of: url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".alas-checkpoint-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else { throw posixError("open") }
        var descriptorIsOpen = true

        do {
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fchmod(descriptor, mode) == 0 else { throw posixError("fchmod") }
            guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync") }
            guard Darwin.close(descriptor) == 0 else { throw posixError("close") }
            descriptorIsOpen = false
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError("rename") }
            try synchronizeDirectory(url.deletingLastPathComponent())
        } catch {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            _ = Darwin.unlink(temporary.path)
            throw error
        }
    }

    func createSymlink(target: Data, at url: URL) throws {
        try requireSafeParent(of: url)
        guard !target.contains(0) else { throw CheckpointFileSystemError.invalidSymlinkTarget }
        let bytes = Array(target) + [0]
        let result = bytes.withUnsafeBufferPointer { pointer in
            Darwin.symlink(pointer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { $0 }, url.path)
        }
        guard result == 0 else { throw posixError("symlink") }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    func move(_ source: URL, to destination: URL) throws {
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

    func moveExclusively(_ source: URL, to destination: URL) throws {
        try requireSafeParent(of: source)
        try requireSafeParent(of: destination)
        let sourceDirectory = try lstat(at: source.deletingLastPathComponent())
        let destinationDirectory = try lstat(at: destination.deletingLastPathComponent())
        guard sourceDirectory.st_dev == destinationDirectory.st_dev else { throw CheckpointFileSystemError.unsafePath }
        guard Darwin.link(source.path, destination.path) == 0 else { throw posixError("link") }
        guard Darwin.unlink(source.path) == 0 else { throw posixError("unlink") }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    func removeIfPresent(_ url: URL) throws {
        try requireSafeParent(of: url)
        if Darwin.unlink(url.path) == 0 {
            try synchronizeDirectory(url.deletingLastPathComponent())
            return
        }
        if errno == ENOENT { return }
        if errno == EISDIR || errno == EPERM {
            guard Darwin.rmdir(url.path) == 0 else { throw posixError("rmdir") }
            try synchronizeDirectory(url.deletingLastPathComponent())
            return
        }
        throw posixError("unlink")
    }

    func list(_ url: URL) throws -> [URL] {
        try requireSafeDirectoryTree(at: url)
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
    }

    func fileData(_ url: URL) throws -> Data {
        try requireSafeParent(of: url)
        return try readData(at: url)
    }

    func synchronizeDirectory(_ url: URL) throws {
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

    private func isDirectory(_ attributes: stat) -> Bool { attributes.st_mode & S_IFMT == S_IFDIR }
    private func isRegular(_ attributes: stat) -> Bool { attributes.st_mode & S_IFMT == S_IFREG }
    private func isSymlink(_ attributes: stat) -> Bool { attributes.st_mode & S_IFMT == S_IFLNK }

    private func posixError(_ operation: String) -> CheckpointFileSystemError {
        .posix(operation: operation, code: errno)
    }
}
