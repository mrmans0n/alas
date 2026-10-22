import Darwin
import Foundation
import Synchronization
import AlasFoundation
import AlasModel

/// The one ACP session on this machine that may drive computer use: an
/// exclusive non-blocking `flock` on a fixed file shared by every Alas
/// instance (release, dev, isolated profiles). The kernel drops it when the
/// process dies. The file holds `<pid>\n<label>` so a refusal can name the
/// holder.
public final class ComputerUseDriverLock: @unchecked Sendable {
    public enum Refusal: Error, Equatable {
        /// Another holder has it; its label when it recorded one.
        case held(label: String?)
        case unavailable(String)
    }

    public static var defaultURL: URL {
        Paths.standardAppSupportRoot.appendingPathComponent("computer-use.lock")
    }

    private let fd: Mutex<Int32?>

    private init(fd: Int32) {
        self.fd = Mutex(fd)
    }

    /// Takes the lock without blocking and records `label` for refusals.
    public static func acquire(at url: URL = defaultURL, label: String) throws(Refusal) -> ComputerUseDriverLock {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .unavailable(error.localizedDescription)
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .unavailable(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            let holder = recordedLabel(fd)
            close(fd)
            if reason == EWOULDBLOCK { throw .held(label: holder) }
            throw .unavailable(String(cString: strerror(reason)))
        }
        let record = Data("\(getpid())\n\(label)".utf8)
        _ = ftruncate(fd, 0)
        _ = record.withUnsafeBytes { pwrite(fd, $0.baseAddress, record.count, 0) }
        return ComputerUseDriverLock(fd: fd)
    }

    /// Idempotent. Unlocked before closing: a forked child shares the
    /// descriptor until its exec, and `close` alone would keep the lock held.
    public func release() {
        guard let fd = fd.withLock({ state -> Int32? in
            defer { state = nil }
            return state
        }) else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    deinit { release() }

    private static func recordedLabel(_ fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let lines = String(decoding: buffer[0..<count], as: UTF8.self)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count > 1 else { return nil }
        let label = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }
}
