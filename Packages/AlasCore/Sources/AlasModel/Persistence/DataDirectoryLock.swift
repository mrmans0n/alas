import Foundation
import AlasFoundation

/// The one process that may write a data directory: an exclusive `flock` on
/// `host.lock` in it, held for as long as this value lives. The kernel drops
/// it when the process dies, so a crash never leaves the directory locked.
/// The lock file holds the holder's pid, for the refusal to name it.
public final class DataDirectoryLock: Sendable {
    public enum Refusal: Error, Equatable, LocalizedError {
        /// Another live process holds it; its pid when it recorded one.
        case held(pid: Int32?)
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .held(let pid?): "Another Alas host (process \(pid)) is using this data directory."
            case .held(nil): "Another Alas host is using this data directory."
            case .unavailable(let reason): "The data directory cannot be locked: \(reason)"
            }
        }
    }

    public let url: URL
    let fd: Int32

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    /// Takes the lock of `directory`, which is created when missing. When
    /// `waiting`, blocks until the holder lets go instead of refusing.
    public static func acquire(in directory: URL = Paths.appSupportRoot, waiting: Bool = false) throws(Refusal) -> DataDirectoryLock {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .unavailable(error.localizedDescription)
        }
        let url = directory.appendingPathComponent("host.lock")
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .unavailable(String(cString: strerror(errno))) }
        var locked = flock(fd, LOCK_EX | (waiting ? 0 : LOCK_NB)) == 0
        while !locked, waiting, errno == EINTR {
            locked = flock(fd, LOCK_EX) == 0
        }
        guard locked else {
            let reason = errno
            let holder = recordedPID(fd)
            close(fd)
            if reason == EWOULDBLOCK { throw .held(pid: holder) }
            throw .unavailable(String(cString: strerror(reason)))
        }
        let pid = Data("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, pid.count, 0) }
        return DataDirectoryLock(url: url, fd: fd)
    }

    deinit {
        // Unlocked before closing: a child another thread is spawning right
        // now shares this descriptor until its exec closes it, and `close`
        // alone would leave the lock held until then.
        flock(fd, LOCK_UN)
        close(fd)
    }

    private static func recordedPID(_ fd: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return Int32(String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
