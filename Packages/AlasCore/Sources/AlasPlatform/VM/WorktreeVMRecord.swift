import Darwin
import Foundation

public enum VMGuestOS: String, Codable, Sendable {
    case macOS
}

/// The process currently running a VM. Identified by pid plus process start
/// time so a recycled pid is not mistaken for the original owner.
public struct VMRunOwner: Codable, Equatable, Sendable {
    public var pid: Int32
    public var processStart: Date
    public var label: String

    public init(pid: Int32, processStart: Date, label: String) {
        self.pid = pid
        self.processStart = processStart
        self.label = label
    }

    /// The current process as an owner.
    public static func current(label: String) -> VMRunOwner {
        let pid = getpid()
        return VMRunOwner(pid: pid, processStart: startTime(of: pid) ?? Date(), label: label)
    }

    /// True when `owner.pid` exists and started at `owner.processStart`.
    public static func isAlive(_ owner: VMRunOwner) -> Bool {
        guard kill(owner.pid, 0) == 0 || errno == EPERM else { return false }
        guard let start = startTime(of: owner.pid) else { return false }
        return abs(start.timeIntervalSince(owner.processStart)) < 0.01
    }

    /// Same process, ignoring the display label.
    public func isSameProcess(as other: VMRunOwner) -> Bool {
        pid == other.pid && abs(processStart.timeIntervalSince(other.processStart)) < 0.01
    }

    private static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}

public struct WorktreeVMRecord: Codable, Equatable, Sendable, Identifiable {
    /// Worktree id.
    public var id: String
    public var guestOS: VMGuestOS
    public var goldenBuild: String
    public var bundlePath: String
    public var createdAt: Date
    public var lastUsedAt: Date
    public var runOwner: VMRunOwner?

    public init(
        id: String, guestOS: VMGuestOS = .macOS, goldenBuild: String, bundlePath: String,
        createdAt: Date, lastUsedAt: Date, runOwner: VMRunOwner? = nil
    ) {
        self.id = id
        self.guestOS = guestOS
        self.goldenBuild = goldenBuild
        self.bundlePath = bundlePath
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.runOwner = runOwner
    }
}
