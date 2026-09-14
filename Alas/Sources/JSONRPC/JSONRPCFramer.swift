import Foundation

/// Splits a stream of bytes into JSON-RPC `Content-Length`-framed payloads.
/// Used by LSP (ACP uses `JSONRPCNewlineFramer`).
struct JSONRPCFramer {
    static let maximumBodyBytes = 16 * 1024 * 1024
    static let maximumHeaderBytes = 8 * 1024
    private var buffer = Data()
    private var expectedBodyBytes: Int?
    private var completedFrames: [Data] = []
    private(set) var hasFailed = false

    mutating func append<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        var cursor = bytes.startIndex
        while cursor != bytes.endIndex, !hasFailed {
            if let expectedBodyBytes {
                // Consume only this body's remaining bytes. The same read may
                // also contain the next frame, which has its own size bound.
                let end = bytes.index(cursor, offsetBy: expectedBodyBytes - buffer.count, limitedBy: bytes.endIndex) ?? bytes.endIndex
                buffer.append(contentsOf: bytes[cursor..<end])
                cursor = end
                if buffer.count == expectedBodyBytes { completeFrame() }
            } else {
                buffer.append(bytes[cursor])
                cursor = bytes.index(after: cursor)
                guard buffer.count <= Self.maximumHeaderBytes else { fail()
                return }
                if buffer.count >= 4, buffer.suffix(4).elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]) {
                    finishHeader()
                }
            }
        }
    }

    mutating func drainFrames() -> [Data] {
        defer { completedFrames = [] }
        return completedFrames
    }

    static func encode(_ body: Data) -> Data {
        var out = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8)!
        out.append(body)
        return out
    }

    private mutating func finishHeader() {
        let header = String(decoding: buffer.dropLast(4), as: UTF8.self)
        var contentLength = -1
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1]) ?? -1
            }
        }
        guard contentLength >= 0, contentLength <= Self.maximumBodyBytes else { fail()
        return }
        buffer = Data()
        expectedBodyBytes = contentLength
        if contentLength == 0 { completeFrame() }
    }

    private mutating func completeFrame() {
        completedFrames.append(buffer)
        buffer = Data()
        expectedBodyBytes = nil
    }

    private mutating func fail() {
        hasFailed = true
        buffer = Data()
        expectedBodyBytes = nil
        completedFrames = []
    }
}
