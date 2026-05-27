import Foundation

enum JSONRPCFraming {
    case contentLength   // LSP-style "Content-Length: N\r\n\r\n<body>"
    case newline         // ACP-style one-JSON-object-per-line
}

protocol JSONRPCStdioTransporting: AnyObject, Sendable {
    var incoming: AsyncStream<JSONRPCStdioTransport.Incoming> { get }
    func start() throws
    func send(_ data: Data) throws
    func terminate()
}

final class JSONRPCStdioTransport: @unchecked Sendable, JSONRPCStdioTransporting {
    enum Incoming: Sendable {
        case frame(Data)
        case stderr(Data)
        case exited(Int32)
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let framing: JSONRPCFraming
    private var contentLengthFramer = JSONRPCFramer()
    private var newlineFramer = JSONRPCNewlineFramer()
    private let lock = NSLock()
    private var continuation: AsyncStream<Incoming>.Continuation?

    let incoming: AsyncStream<Incoming>

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        framing: JSONRPCFraming = .contentLength,
        replaceEnv: Bool = false
    ) {
        self.framing = framing
        var cont: AsyncStream<Incoming>.Continuation!
        self.incoming = AsyncStream { c in cont = c }
        self.continuation = cont
        process.executableURL = executable
        process.arguments = arguments
        if let env = environment {
            if replaceEnv {
                // Use exactly what the caller provided — used by ACP where
                // we explicitly need to *remove* env vars (CLAUDECODE etc.)
                // that the parent would otherwise inherit.
                process.environment = env
            } else {
                var merged = ProcessInfo.processInfo.environment
                for (k, v) in env { merged[k] = v }
                process.environment = merged
            }
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.lock.lock()
            let frames: [Data]
            switch self.framing {
            case .contentLength:
                self.contentLengthFramer.append(d)
                frames = self.contentLengthFramer.drainFrames()
            case .newline:
                self.newlineFramer.append(d)
                frames = self.newlineFramer.drainFrames()
            }
            self.lock.unlock()
            for f in frames { self.continuation?.yield(.frame(f)) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            self?.continuation?.yield(.stderr(d))
        }
        process.terminationHandler = { [weak self] p in
            self?.continuation?.yield(.exited(p.terminationStatus))
            self?.continuation?.finish()
        }
        try process.run()
    }

    func send(_ data: Data) throws {
        let framed: Data
        switch framing {
        case .contentLength: framed = JSONRPCFramer.encode(data)
        case .newline:       framed = JSONRPCNewlineFramer.encode(data)
        }
        try stdin.fileHandleForWriting.write(contentsOf: framed)
    }

    func terminate() { if process.isRunning { process.terminate() } }
}
