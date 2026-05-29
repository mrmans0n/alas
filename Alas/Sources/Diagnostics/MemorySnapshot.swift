#if DEBUG
import Foundation

/// One pull-tick of memory accounting for the Alas process.
///
/// Each byte field is an *estimate* — Swift's `String` byte cost is approximated as
/// UTF-8 length, attributed strings as their plain text byte length plus a per-block
/// constant, etc. The deltas between ticks are the load-bearing signal; absolute
/// values are bounded by `physFootprint`.
struct MemorySnapshot {
    let timestamp: Date
    let physFootprint: UInt64
    let transcriptBytes: UInt64
    let markdownCacheBytes: UInt64
    let terminalBytes: UInt64
    let sessionCount: Int
    let runnerCount: Int
    let perSession: [PerSession]

    struct PerSession: Equatable {
        let sessionId: String
        let worktreeId: String
        let transcriptBytes: UInt64
        let markdownCacheBytes: UInt64
        let messageCount: Int
        let attached: Bool
    }

    var accountedBytes: UInt64 {
        transcriptBytes &+ markdownCacheBytes &+ terminalBytes
    }

    var unattributedBytes: UInt64 {
        physFootprint > accountedBytes ? physFootprint - accountedBytes : 0
    }

    func oneLineLog() -> String {
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
    static func formatBinary(_ bytes: UInt64) -> String {
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
}
#endif
