import Foundation
import Testing
@testable import AlasCore

struct AlasHostExecutableTests {
    /// The host serves its data directory alone: it prints where it serves,
    /// a second host there exits naming the first, and SIGTERM stops it and
    /// frees the directory.
    @Test func aHostOwnsItsDataDirectoryUntilStopped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alas-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try AlasHostProcess(dataDirectory: directory)

        let socket = try await host.socketPath()
        #expect(FileManager.default.fileExists(atPath: socket))

        let second = try AlasHostProcess(dataDirectory: directory)
        #expect(try await second.exitStatus() == 1)
        #expect(second.errorOutput.contains("process \(host.process.processIdentifier)"))

        host.process.terminate()
        #expect(try await host.exitStatus() == 0)
        _ = try DataDirectoryLock.acquire(in: directory)
    }
}
