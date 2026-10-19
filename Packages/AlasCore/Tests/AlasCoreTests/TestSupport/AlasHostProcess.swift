import Foundation
@testable import AlasCore
import Testing

/// The built `alas-host`, run on a data directory: what it prints, and how
/// it ends. `swift test` builds it, since the test target depends on it.
final class AlasHostProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    /// The pipes that reached end of file: their output is complete.
    private var closedPipes = 0
    /// Where the host's profile keeps its sockets, outside its data
    /// directory: removed with this value, since each test's profile is new.
    private let runtimeDirectory: URL

    /// The `alas-host` that `swift test` built, in the package's build
    /// directory: `.build/debug` is the configuration it tests.
    static var binary: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TestSupport
            .deletingLastPathComponent() // AlasCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // the package
            .appendingPathComponent(".build/debug/alas-host")
    }

    init(dataDirectory: URL, arguments: [String] = []) throws {
        let root = AlasProfile.canonicalDirectory(dataDirectory) ?? dataDirectory
        runtimeDirectory = AlasProfile.runtimeDirectory(for: root, uid: getuid())
        process.executableURL = Self.binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ALAS_APP_SUPPORT_DIR"] = dataDirectory.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle) { $0.out.append($1) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle) { $0.err.append($1) }
        }
        try process.run()
    }

    private func read(_ handle: FileHandle, into append: (AlasHostProcess, Data) -> Void) {
        let data = handle.availableData
        lock.withLock {
            if data.isEmpty {
                handle.readabilityHandler = nil
                closedPipes += 1
            } else {
                append(self, data)
            }
        }
    }

    var output: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var errorOutput: String { lock.withLock { String(decoding: err, as: UTF8.self) } }

    /// The socket path, the first line the host prints once it serves.
    func socketPath() async throws -> String {
        try await eventually { [self] in output.contains("\n") || !process.isRunning }
        return try #require(output.split(separator: "\n").first.map(String.init), "alas-host printed nothing: \(errorOutput)")
    }

    /// Waits for the process to end and for all it printed, and returns
    /// its exit status.
    func exitStatus() async throws -> Int32 {
        try await eventually { [self] in !process.isRunning && lock.withLock { closedPipes == 2 } }
        return process.terminationStatus
    }

    deinit {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: runtimeDirectory)
    }
}
