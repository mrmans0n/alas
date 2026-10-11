#if DEBUG
import Foundation

/// One pull-tick of memory accounting for the Alas process.
///
/// Each byte field is an *estimate* — Swift's `String` byte cost is approximated as
/// UTF-8 length, attributed strings as their plain text byte length plus a per-block
/// constant, etc. The deltas between ticks are the load-bearing signal; absolute
/// values are bounded by `physFootprint`.
public struct MemorySnapshot {
    public let timestamp: Date
    public let physFootprint: UInt64
    public let transcriptBytes: UInt64
    public let markdownCacheBytes: UInt64
    public let terminalBytes: UInt64
    public let sessionCount: Int
    public let runnerCount: Int
    public let perSession: [PerSession]

    public struct PerSession: Equatable, Sendable {
        public let sessionId: String
        public let worktreeId: String
        public let transcriptBytes: UInt64
        public let markdownCacheBytes: UInt64
        public let messageCount: Int
        public let attached: Bool

        public init(sessionId: String, worktreeId: String, transcriptBytes: UInt64, markdownCacheBytes: UInt64, messageCount: Int, attached: Bool) {
            self.sessionId = sessionId
            self.worktreeId = worktreeId
            self.transcriptBytes = transcriptBytes
            self.markdownCacheBytes = markdownCacheBytes
            self.messageCount = messageCount
            self.attached = attached
        }
    }

    public var accountedBytes: UInt64 {
        transcriptBytes &+ markdownCacheBytes &+ terminalBytes
    }

    public var unattributedBytes: UInt64 {
        physFootprint > accountedBytes ? physFootprint - accountedBytes : 0
    }

    public func oneLineLog() -> String {
        "mem:" +
        " phys=\(Self.formatBinary(physFootprint))" +
        " acp.tx=\(Self.formatBinary(transcriptBytes))" +
        " acp.md=\(Self.formatBinary(markdownCacheBytes))" +
        " term=\(Self.formatBinary(terminalBytes))" +
        " sessions=\(sessionCount)" +
        " runners=\(runnerCount)" +
        " unattributed=\(Self.formatBinary(unattributedBytes))"
    }

    /// Compact binary-units formatter: `1.42G`, `412M`, `2.0K`, `512B`.
    /// Uses 1024-based units, rounded to the precision of each unit.
    public static func formatBinary(_ bytes: UInt64) -> String {
        let kb: UInt64 = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        if bytes >= gb {
            let value = Double(bytes) / Double(gb)
            return String(format: "%.2fG", value)
        }
        if bytes >= mb {
            let value = Double(bytes) / Double(mb)
            return String(format: "%.0fM", value)
        }
        if bytes >= kb {
            let value = Double(bytes) / Double(kb)
            return String(format: "%.1fK", value)
        }
        return "\(bytes)B"
    }

    public init(timestamp: Date, physFootprint: UInt64, transcriptBytes: UInt64, markdownCacheBytes: UInt64, terminalBytes: UInt64, sessionCount: Int, runnerCount: Int, perSession: [PerSession]) {
        self.timestamp = timestamp
        self.physFootprint = physFootprint
        self.transcriptBytes = transcriptBytes
        self.markdownCacheBytes = markdownCacheBytes
        self.terminalBytes = terminalBytes
        self.sessionCount = sessionCount
        self.runnerCount = runnerCount
        self.perSession = perSession
    }
}
#endif
