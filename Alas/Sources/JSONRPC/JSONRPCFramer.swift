import Foundation

/// Splits a stream of bytes into JSON-RPC `Content-Length`-framed payloads.
/// Used by LSP (ACP uses `JSONRPCNewlineFramer`).
struct JSONRPCFramer {
    static let maximumBodyBytes = 16 * 1024 * 1024
    static let maximumHeaderBytes = 8 * 1024
    private var buffer = Data()
    private(set) var hasFailed = false

    mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        guard !hasFailed else { return }
        let remaining = Self.maximumBodyBytes + Self.maximumHeaderBytes - buffer.count
        buffer.append(contentsOf: bytes.prefix(remaining + 1))
        if buffer.count > Self.maximumBodyBytes + Self.maximumHeaderBytes { fail() }
    }

    mutating func drainFrames() -> [Data] {
        var out: [Data] = []
        while let frame = nextFrame() { out.append(frame) }
        return out
    }

    static func encode(_ body: Data) -> Data {
        var out = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8)!
        out.append(body)
        return out
    }

    private mutating func nextFrame() -> Data? {
        guard !hasFailed else { return nil }
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let headerEnd = buffer.firstRange(of: terminator) else {
            if buffer.count > Self.maximumHeaderBytes { fail() }
            return nil
        }
        guard headerEnd.upperBound <= Self.maximumHeaderBytes else { fail()
        return nil }
        let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var contentLength = -1
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1]) ?? -1
            }
        }
        guard contentLength >= 0, contentLength <= Self.maximumBodyBytes else { fail()
        return nil }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        buffer.removeSubrange(buffer.startIndex..<(bodyStart + contentLength))
        return body
    }

    private mutating func fail() {
        hasFailed = true
        buffer = Data()
    }
}
