import Foundation

/// Splits a stream of bytes into JSON-RPC `Content-Length`-framed payloads.
/// Used by LSP (ACP uses `JSONRPCNewlineFramer`).
struct JSONRPCFramer {
    private var buffer = Data()

    mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
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
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let headerEnd = buffer.firstRange(of: terminator) else { return nil }
        let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var contentLength = -1
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1]) ?? -1
            }
        }
        guard contentLength >= 0 else { return nil }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        buffer.removeSubrange(buffer.startIndex..<(bodyStart + contentLength))
        return body
    }
}
