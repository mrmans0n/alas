import Foundation

/// Splits a stream of bytes into LSP `Content-Length`-framed JSON payloads.
/// Caller appends bytes from the read side of stdout; calls `drainFrames()`
/// to pull decoded JSON bodies (Data) ready for `JSONDecoder`.
struct LSPFrameDecoder {
    private var buffer = Data()

    mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    mutating func drainFrames() -> [Data] {
        var out: [Data] = []
        while let frame = nextFrame() { out.append(frame) }
        return out
    }

    private mutating func nextFrame() -> Data? {
        guard let headerEnd = rangeOfHeaderTerminator() else { return nil }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        var contentLength = -1
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
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

    private func rangeOfHeaderTerminator() -> Range<Data.Index>? {
        let pattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]   // \r\n\r\n
        return buffer.firstRange(of: pattern)
    }
}

/// Owns a `Process` running an LSP server and exposes async send/receive.
/// `incoming` emits raw JSON Data per-frame; the client decodes them.
final class LSPTransport {
    enum Incoming: Sendable {
        case frame(Data)
        case stderr(Data)
        case exited(Int32)
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var decoder = LSPFrameDecoder()
    private let lock = NSLock()
    private var continuation: AsyncStream<Incoming>.Continuation?

    let incoming: AsyncStream<Incoming>

    init(executable: URL, arguments: [String], environment: [String: String]?) {
        var cont: AsyncStream<Incoming>.Continuation!
        self.incoming = AsyncStream { c in cont = c }
        self.continuation = cont
        process.executableURL = executable
        process.arguments = arguments
        if let env = environment { process.environment = env }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { return }
            self.lock.lock()
            self.decoder.append(data)
            let frames = self.decoder.drainFrames()
            self.lock.unlock()
            for f in frames { self.continuation?.yield(.frame(f)) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.continuation?.yield(.stderr(data))
        }
        process.terminationHandler = { [weak self] proc in
            self?.continuation?.yield(.exited(proc.terminationStatus))
            self?.continuation?.finish()
        }
        try process.run()
    }

    func send(_ data: Data) throws {
        let header = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)!
        try stdin.fileHandleForWriting.write(contentsOf: header)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
