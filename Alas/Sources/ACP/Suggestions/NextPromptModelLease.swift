import Darwin
import Foundation
import Synchronization

/// The descriptor remains open until the model container has finished using its files.
final class NextPromptModelLease: Sendable {
    let directory: URL
    let generation: UInt64
    private let handle: Mutex<FileHandle?>

    init(directory: URL, generation: UInt64, handle: FileHandle) {
        self.directory = directory
        self.generation = generation
        self.handle = Mutex(handle)
    }

    func close() {
        handle.withLock { value in
            try? value?.close()
            value = nil
        }
    }

    deinit { close() }
}

/// All traversal and deletion is relative to held directory descriptors.
/// Checkpoint publication uses the same no-follow, chunked-I/O and fsync pattern.
enum NextPromptModelFiles {
    static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    static func openRoot(_ root: URL) throws -> FileHandle {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else {
            throw NextPromptModelFailure.invalidPath
        }
        let components = root.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw NextPromptModelFailure.invalidPath
        }
        var current = try directory(parent: AT_FDCWD, name: "/")
        for component in components {
            let name = String(component)
            if mkdirat(current.fileDescriptor, name, 0o700) != 0, errno != EEXIST { throw posix() }
            let next = try directory(parent: current.fileDescriptor, name: name)
            try current.close()
            current = next
        }
        return current
    }

    static func directory(parent: Int32, name: String) throws -> FileHandle {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw NextPromptModelFailure.invalidPath }
            throw posix()
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func regular(parent: Int32, name: String, create: Bool = false) throws -> FileHandle {
        let flags = (create ? O_RDWR | O_CREAT | O_EXCL : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let fd = openat(parent, name, flags, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP { throw NextPromptModelFailure.invalidPath }
            throw posix()
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posix() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw NextPromptModelFailure.invalidPath }
        return handle
    }

    static func lock(root: Int32, exclusive: Bool) throws -> FileHandle {
        let fd = openat(root, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP { throw NextPromptModelFailure.invalidPath }
            throw posix()
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posix() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw NextPromptModelFailure.invalidPath }
        let operation = exclusive ? LOCK_EX | LOCK_NB : LOCK_SH | LOCK_NB
        if flock(fd, operation) != 0 {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { throw NextPromptModelFailure.busy }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return handle
    }

    static func synchronize(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw posix() }
    }

    static func entries(_ fd: Int32) throws -> [String] {
        // Open a new description so readdir does not change the caller's directory offset.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw posix() }
        guard let stream = fdopendir(copy) else {
            Darwin.close(copy)
            throw posix()
        }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posix() }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
        }
    }

    static func removeDirectory(parent: Int32, name: String) throws {
        let handle: FileHandle
        do { handle = try directory(parent: parent, name: name) }
        catch let error as POSIXError where error.code == .ENOENT { return }
        defer { try? handle.close() }
        for child in try entries(handle.fileDescriptor) {
            var info = stat()
            guard fstatat(handle.fileDescriptor, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix() }
            if info.st_mode & S_IFMT == S_IFDIR {
                try removeDirectory(parent: handle.fileDescriptor, name: child)
            } else {
                // unlinkat never follows a leaf link, including one swapped in after fstatat.
                guard unlinkat(handle.fileDescriptor, child, 0) == 0 else { throw posix() }
            }
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posix() }
    }
}
