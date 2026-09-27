import Foundation
import CryptoKit

protocol CheckpointGitRunning: Sendable {
    func run(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResult
    func runData(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResultData
    /// Blob sizes from one `cat-file --batch-check`, keyed by OID.
    func blobSizes(oids: [String], cwd: URL) async throws -> [String: Int64]
    /// Blob bytes from one `cat-file --batch`, keyed by OID.
    func blobContents(oids: [String], cwd: URL) async throws -> [String: Data]
    /// Blob references from one `cat-file --batch`, hashed as each object
    /// streams so no whole object is buffered.
    func blobReferences(oids: [String], cwd: URL) async throws -> [String: CheckpointBlobReference]
}

/// Git-dir paths one checkpoint operation reads, resolved by a single
/// `rev-parse`. Only the path strings are shared; callers still check each
/// file on disk where the check happens today.
struct CheckpointGitPaths: Equatable, Sendable {
    static let operationMarkerNames = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"]

    let index: URL
    let indexLock: URL
    /// In `operationMarkerNames` order.
    let operationMarkers: [URL]

    static func resolve(git: any CheckpointGitRunning, cwd: URL) async throws -> Self {
        let names = ["index", "index.lock"] + operationMarkerNames
        let lines = try await gitPaths(names, git: git, cwd: cwd).split(separator: "\n", omittingEmptySubsequences: false)
        var paths = lines.map(String.init)
        // Every path shares the git dir, so a newline in it (legal in a
        // directory name) always yields extra lines. Resolve each path alone,
        // which keeps embedded newlines intact.
        if paths.count != names.count || paths.contains(where: \.isEmpty) {
            paths = []
            for name in names { paths.append(try await gitPaths([name], git: git, cwd: cwd)) }
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        return .init(index: urls[0], indexLock: urls[1], operationMarkers: Array(urls[2...]))
    }

    /// `rev-parse` output for `names`, without its final newline.
    private static func gitPaths(_ names: [String], git: any CheckpointGitRunning, cwd: URL) async throws -> String {
        let result = try await git.run(["rev-parse", "--path-format=absolute"] + names.flatMap { ["--git-path", $0] },
                                       cwd: cwd, environment: [:])
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        var output = result.stdout
        if output.hasSuffix("\n") { output.removeLast() }
        guard !output.isEmpty else { throw CheckpointSnapshotError.invalidGitOutput }
        return output
    }
}

struct LiveCheckpointGitRunner: CheckpointGitRunning {
    func run(_ args: [String], cwd: URL, environment: [String: String] = [:]) async throws -> ProcessResult {
        let invocation = try invocation(args, cwd: cwd)
        return try await Process.run(invocation.executable, args: invocation.args, cwd: invocation.cwd,
                                     env: gitEnvironment(environment))
    }

    func runData(_ args: [String], cwd: URL, environment: [String: String] = [:]) async throws -> ProcessResultData {
        let invocation = try invocation(args, cwd: cwd)
        return try await Process.runData(invocation.executable, args: invocation.args, cwd: invocation.cwd,
                                         env: gitEnvironment(environment))
    }

    func blobSizes(oids: [String], cwd: URL) async throws -> [String: Int64] {
        try await stream(["cat-file", "--batch-check"], lines: oids, cwd: cwd) { reader in
            var sizes: [String: Int64] = [:]
            for oid in oids { sizes[oid] = try reader.header(for: oid) }
            return sizes
        }
    }

    func blobContents(oids: [String], cwd: URL) async throws -> [String: Data] {
        try await stream(["cat-file", "--batch"], lines: oids, cwd: cwd) { reader in
            var contents: [String: Data] = [:]
            for oid in oids {
                let byteCount = try reader.header(for: oid)
                var bytes = Data(capacity: Int(byteCount))
                try reader.body(byteCount: byteCount) { bytes.append($0) }
                contents[oid] = bytes
            }
            return contents
        }
    }

    func blobReferences(oids: [String], cwd: URL) async throws -> [String: CheckpointBlobReference] {
        try await stream(["cat-file", "--batch"], lines: oids, cwd: cwd) { reader in
            var references: [String: CheckpointBlobReference] = [:]
            for oid in oids {
                let byteCount = try reader.header(for: oid)
                var hasher = SHA256()
                try reader.body(byteCount: byteCount) { hasher.update(data: $0) }
                let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                references[oid] = CheckpointBlobReference(sha256: hash, byteCount: byteCount)
            }
            return references
        }
    }

    private func invocation(_ args: [String], cwd: URL) throws -> GitInvocation {
        guard !cwd.isRemoteAlasPath else { throw CheckpointSnapshotError.remoteTarget }
        return GitInvocation.build(gitArgs: args, cwd: cwd, host: nil)
    }

    private func gitEnvironment(_ overrides: [String: String]) -> [String: String] {
        var environment = Process.gitEnv()
        if let index = overrides["GIT_INDEX_FILE"] { environment["GIT_INDEX_FILE"] = index }
        return environment
    }

    /// Runs one git process that reads `lines` from stdin, parsing stdout as it
    /// arrives. Stdin is written while stdout drains, so a request larger than
    /// the pipe buffers cannot deadlock. No timeout applies: a batch can
    /// legitimately stream many large objects, just as the per-object
    /// streaming read it replaces. Empty input spawns nothing.
    private func stream<Result: Sendable>(
        _ args: [String], lines: [String], cwd: URL,
        read: @escaping @Sendable (inout CheckpointGitStreamReader) throws -> Result
    ) async throws -> Result {
        if lines.isEmpty {
            var reader = CheckpointGitStreamReader(handle: nil)
            return try read(&reader)
        }
        // Stdin is line-framed; a newline inside a request would split it.
        guard !lines.contains(where: { $0.contains("\n") }) else { throw CheckpointSnapshotError.invalidGitOutput }
        let invocation = try invocation(args, cwd: cwd)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.args
        process.currentDirectoryURL = invocation.cwd
        process.environment = gitEnvironment([:])

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Git can exit before reading every request. Report that as a failed
        // write instead of letting SIGPIPE terminate the app.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ProcessError.launchFailed(String(cString: strerror(errno)))
        }

        let termination = ProcessTerminationWaiter()
        process.terminationHandler = { _ in termination.finish() }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error.localizedDescription)
        }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let request = Data(lines.map { $0 + "\n" }.joined().utf8)
        let writerTask = Task.detached(priority: .utility) {
            let handle = stdin.fileHandleForWriting
            try? handle.write(contentsOf: request)
            try? handle.close()
        }
        let readerTask = Task.detached(priority: .utility) {
            var reader = CheckpointGitStreamReader(handle: stdout.fileHandleForReading)
            return try read(&reader)
        }
        let stderrTask = Task.detached(priority: .utility) {
            stderr.fileHandleForReading.readDataToEndOfFile()
        }

        // Nothing else bounds a batch, so cancellation must stop git.
        let result = await withTaskCancellationHandler {
            await readerTask.result
        } onCancel: {
            terminateProcessWithEscalation(process)
        }
        // A reader that stopped early no longer drains stdout, so git could
        // block forever on a full pipe.
        if case .failure = result { terminateProcessWithEscalation(process) }
        await termination.wait()
        await writerTask.value
        let errorData = await stderrTask.value
        try Task.checkCancellation()
        guard process.terminationStatus == 0 || process.terminationReason == .uncaughtSignal else {
            throw ProcessError.nonZeroExit(process.terminationStatus, String(data: errorData, encoding: .utf8) ?? "")
        }
        return try result.get()
    }
}

/// Parses streamed git output. For `cat-file --batch` framing each object is
/// `<oid> blob <size>\n`, then for `--batch` the object bytes and a trailing
/// `\n`. A missing object prints `<oid> missing` with exit status 0, so every
/// header is validated.
struct CheckpointGitStreamReader {
    private let handle: FileHandle?
    private var buffer = Data()
    private var offset = 0

    init(handle: FileHandle?) {
        self.handle = handle
    }

    mutating func header(for oid: String) throws -> Int64 {
        let fields = try line().split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == oid, fields[1] == "blob",
              let byteCount = Int64(fields[2]), byteCount >= 0 else {
            throw CheckpointSnapshotError.invalidGitOutput
        }
        return byteCount
    }

    mutating func body(byteCount: Int64, _ consume: (Data) throws -> Void) throws {
        var remaining = byteCount
        while remaining > 0 {
            try requireBufferedByte()
            let count = Int(min(Int64(buffer.count - offset), remaining))
            try consume(buffer.subdata(in: offset..<(offset + count)))
            offset += count
            remaining -= Int64(count)
        }
        try requireBufferedByte()
        guard buffer[offset] == UInt8(ascii: "\n") else { throw CheckpointSnapshotError.invalidGitOutput }
        offset += 1
    }

    mutating func line() throws -> String {
        while true {
            if let newline = buffer[offset...].firstIndex(of: UInt8(ascii: "\n")) {
                let text = String(decoding: buffer[offset..<newline], as: UTF8.self)
                offset = newline + 1
                return text
            }
            guard try fill() else { throw CheckpointSnapshotError.invalidGitOutput }
        }
    }

    private mutating func requireBufferedByte() throws {
        if offset == buffer.count, !(try fill()) { throw CheckpointSnapshotError.invalidGitOutput }
    }

    /// Appends the next chunk, keeping the buffer zero-based.
    private mutating func fill() throws -> Bool {
        guard let chunk = try handle?.read(upToCount: 1024 * 1024), !chunk.isEmpty else { return false }
        buffer = offset < buffer.count ? buffer.subdata(in: offset..<buffer.count) + chunk : chunk
        offset = 0
        return true
    }
}

private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func finish() {
        let toResume: CheckedContinuation<Void, Never>?
        lock.lock()
        finished = true
        toResume = continuation
        continuation = nil
        lock.unlock()
        toResume?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
