import Foundation
import Testing

/// The built `alas-host`, run on a data directory: what it prints, and how
/// it ends. `swift test` builds it, since the test target depends on it.
final class AlasHostProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

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

    init(dataDirectory: URL) throws {
        process.executableURL = Self.binary
        var environment = ProcessInfo.processInfo.environment
        environment["ALAS_APP_SUPPORT_DIR"] = dataDirectory.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.lock.withLock { self?.out.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.lock.withLock { self?.err.append(data) }
        }
        try process.run()
    }

    var output: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var errorOutput: String { lock.withLock { String(decoding: err, as: UTF8.self) } }

    /// The socket path, the first line the host prints once it serves.
    func socketPath() async throws -> String {
        try await eventually { [self] in output.contains("\n") || !process.isRunning }
        return try #require(output.split(separator: "\n").first.map(String.init), "alas-host printed nothing: \(errorOutput)")
    }

    /// Waits for the process to end, and returns its exit status.
    func exitStatus() async throws -> Int32 {
        try await eventually { [process] in !process.isRunning }
        return process.terminationStatus
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}
