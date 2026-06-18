import Foundation

/// Accumulates partial reads and yields complete lines. Trailing newline-less
/// content is held until either more data arrives or `flush()` is called.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: String = ""

    func feed(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending += chunk
        var out: [String] = []
        while let newlineRange = pending.range(of: "\n") {
            var line = String(pending[..<newlineRange.lowerBound])
            if line.hasSuffix("\r") { line.removeLast() }
            out.append(line)
            pending.removeSubrange(pending.startIndex...newlineRange.lowerBound)
        }
        return out
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if pending.isEmpty { return nil }
        let tail = pending
        pending = ""
        return tail
    }
}
