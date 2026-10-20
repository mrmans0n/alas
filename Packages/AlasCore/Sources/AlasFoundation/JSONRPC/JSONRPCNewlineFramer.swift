import Foundation

/// Splits a stream of bytes into newline-delimited JSON payloads.
/// Used by ACP, which sends one JSON object per line on stdout/stdin.
public struct JSONRPCNewlineFramer: Sendable {
    private var buffer = Data()
    private var scannedBytes = 0
    /// Bytes searched for a newline so far, for tests to check that a line
    /// spanning many reads is not searched again on each one.
    private(set) var searchedBytes = 0

    public init() {}

    public mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    public mutating func drainFrames() -> [Data] {
        var out: [Data] = []
        var consumedBytes = 0
        var searched = 0
        buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var searchStart = scannedBytes
            while let newline = bytes[searchStart...].firstIndex(of: 0x0A) {
                searched += newline + 1 - searchStart
                var end = newline
                if end > consumedBytes, bytes[end - 1] == 0x0D { end -= 1 }
                if end > consumedBytes {
                    out.append(Data(bytes[consumedBytes..<end]))
                }
                consumedBytes = newline + 1
                searchStart = consumedBytes
            }
            searched += bytes.count - searchStart
        }
        searchedBytes += searched
        if consumedBytes == buffer.count {
            buffer = Data()
        } else if consumedBytes > 0 {
            buffer.removeFirst(consumedBytes)
        }
        // The remaining partial line has already been searched. Only scan
        // newly appended bytes next time, even when the line spans many reads.
        scannedBytes = buffer.count
        return out
    }

    public static func encode(_ body: Data) -> Data {
        var out = body
        out.append(0x0A)
        return out
    }
}
