import Foundation
import Testing
@testable import Alas

struct RunScriptCompletionMonitorTests {
    @Test func remoteFrameIsBinarySafe() throws {
        let body = Data([0x00, 0x0A, 0xFF, 0x41])
        let framed = Data("ALAS_RUN_V1\t9\t1\t0\t1700000000\n".utf8) + body
        let result = try RunScriptCompletionMonitor.parseRemotePayload(framed)
        #expect(result.exitCode == 9)
        #expect(result.completedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(result.transcript == body)
        #expect(!result.truncated)
    }

    @Test func remoteCommandQuotesAndBoundsOutput() {
        let paths = RunScriptCapturePaths(transcript: "/tmp/a'b.log", completion: "/tmp/a'b.done")
        let command = RunScriptCompletionMonitor.remoteWaitCommand(paths: paths, byteLimit: 1_048_576)
        #expect(command.contains("tail -c 1052672"))
        #expect(command.contains("captured=1"))
        #expect(command.contains("cat \"$body\""))
        #expect(command.contains("\"$body\" \"$completion.status\""))
        #expect(command.contains("completed_at=${2:-$(date +%s)}"))
        #expect(command.contains("[ \"$exit_code\" != 0 ]"))
        #expect(command.contains("ALAS_RUN_V1"))
        #expect(command.contains("rm -f"))
        #expect(command.contains("|| true"))
        #expect(!command.contains("/tmp/a'b.log"))
    }

    @Test func remoteCommandExpandsHomeRelativePathsAtRuntime() throws {
        let location = try RunScriptCompletionMonitor.paths(runID: UUID().uuidString, host: "devbox")
        guard case let .remote(_, paths) = location else {
            Issue.record("Expected remote paths")
            return
        }
        let command = RunScriptCompletionMonitor.remoteWaitCommand(paths: paths, byteLimit: 1)
        #expect(command.contains("transcript=\"$HOME/.alas/run-transcripts/"))
        #expect(command.contains("completion=\"$HOME/.alas/run-transcripts/"))
        #expect(!command.contains("'~/.alas"))
    }

    @Test func pathsRejectNonUUIDRunID() throws {
        #expect(throws: Error.self) {
            try RunScriptCompletionMonitor.paths(runID: "not-a-uuid", host: nil)
        }
    }

    @Test func localFailureReadsTailAndCleansUp() async throws {
        let runID = UUID().uuidString
        let location = try RunScriptCompletionMonitor.paths(runID: runID, host: nil)
        guard case let .local(paths) = location else {
            Issue.record("Expected local paths")
            return
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: paths.transcript).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let transcript = Data((String(repeating: "x", count: 32) + "tail").utf8)
        try transcript.write(to: URL(fileURLWithPath: paths.transcript))
        try "7\t1700000000\n".write(toFile: paths.completion, atomically: true, encoding: .utf8)

        let result = try await RunScriptCompletionMonitor.wait(for: location)
        #expect(result.exitCode == 7)
        #expect(result.completedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(result.transcript == transcript)
        #expect(!result.truncated)
        #expect(!FileManager.default.fileExists(atPath: paths.transcript))
        #expect(!FileManager.default.fileExists(atPath: paths.completion))
    }

    @Test func localFailureRetainsLookbehindBeforeSanitizingTail() async throws {
        let runID = UUID().uuidString
        let location = try RunScriptCompletionMonitor.paths(runID: runID, host: nil)
        guard case let .local(paths) = location else {
            Issue.record("Expected local paths")
            return
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: paths.transcript).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let transcript = Data(repeating: 120, count: RunScriptCompletionMonitor.outputByteLimit + 4_112)
        try transcript.write(to: URL(fileURLWithPath: paths.transcript))
        try "7\n".write(toFile: paths.completion, atomically: true, encoding: .utf8)

        let result = try await RunScriptCompletionMonitor.wait(for: location)
        #expect(result.exitCode == 7)
        #expect((result.transcript?.count ?? 0) > RunScriptCompletionMonitor.outputByteLimit)
        #expect(result.truncated)
    }

    @Test func localSuccessCleansUpWithoutTranscript() async throws {
        let runID = UUID().uuidString
        let location = try RunScriptCompletionMonitor.paths(runID: runID, host: nil)
        guard case let .local(paths) = location else {
            Issue.record("Expected local paths")
            return
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: paths.completion).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "0\n".write(toFile: paths.completion, atomically: true, encoding: .utf8)

        let result = try await RunScriptCompletionMonitor.wait(for: location)
        #expect(result.exitCode == 0)
        #expect(result.transcript == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.completion))
    }

    @Test func localMalformedStatusThrowsAndCleansUp() async throws {
        let runID = UUID().uuidString
        let location = try RunScriptCompletionMonitor.paths(runID: runID, host: nil)
        guard case let .local(paths) = location else {
            Issue.record("Expected local paths")
            return
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: paths.completion).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "nope\n".write(toFile: paths.completion, atomically: true, encoding: .utf8)

        await #expect(throws: Error.self) {
            try await RunScriptCompletionMonitor.wait(for: location)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.completion))
    }

    @Test func localFailureWithUnreadableTranscriptStillReportsFailure() async throws {
        let runID = UUID().uuidString
        let location = try RunScriptCompletionMonitor.paths(runID: runID, host: nil)
        guard case let .local(paths) = location else {
            Issue.record("Expected local paths")
            return
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: paths.transcript),
            withIntermediateDirectories: true
        )
        try "9\n".write(toFile: paths.completion, atomically: true, encoding: .utf8)

        let result = try await RunScriptCompletionMonitor.wait(for: location)
        #expect(result.exitCode == 9)
        #expect(result.transcript == nil)
    }
}
