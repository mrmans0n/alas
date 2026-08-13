import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct ProcessGitDataTests {
    @Test func runDataWithoutTimeoutStillCancelsProcess() async throws {
        let task = Task { try await Process.runData("/bin/sleep", args: ["5"], timeout: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let started = Date()
        let result = try await task.value
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(result.exitCode != 0)
    }

    @Test func returnsRawBinaryBytesFromGitShowBlob() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)

        let raw: [UInt8] = [0xff, 0x00, 0xfe, 0x42, 0xc3, 0x28, 0x80, 0x01]
        let payload = Data(raw)
        let blob = tmp.appendingPathComponent("blob.bin")
        try payload.write(to: blob)

        _ = try await Process.git(["add", "blob.bin"], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "add"], cwd: tmp)

        let result = try await Process.gitData(["show", "HEAD:blob.bin"], cwd: tmp)
        #expect(result.exitCode == 0)
        #expect(result.stdout == payload)
    }
}
