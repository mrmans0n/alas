import Foundation

/// Splits a stream of bytes into newline-delimited JSON payloads.
/// Used by ACP, which sends one JSON object per line on stdout/stdin.
struct JSONRPCNewlineFramer {
    private var buffer = Data()

    mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    mutating func drainFrames() -> [Data] {
        var out: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            // Trim trailing \r if present (CRLF), and skip empty lines.
            var trimmed = line
            if trimmed.last == 0x0D { trimmed = trimmed.dropLast() }
            if !trimmed.isEmpty { out.append(Data(trimmed)) }
        }
        return out
    }

    static func encode(_ body: Data) -> Data {
        var out = body
        out.append(0x0A)
        return out
    }
}
