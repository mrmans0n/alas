import Foundation

/// Accumulates partial reads and yields complete lines. Trailing newline-less
/// content is held until either more data arrives or `flush()` is called.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func feed(_ chunk: String) -> [String] {
        feed(Data(chunk.utf8))
    }

    func feed(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var out: [String] = []
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            var line = Data(pending[..<newlineIndex])
            if line.last == 0x0D { line.removeLast() }
            out.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newlineIndex)
        }
        return out
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if pending.isEmpty { return nil }
        let tail = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return tail
    }
}
