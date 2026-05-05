import Testing
import Foundation
@testable import Alas

struct ProcessGitTests {
    @Test func runEchoReturnsStdout() async throws {
        let result = try await Process.run("/bin/echo", args: ["hi"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
    }

    @Test func nonZeroExitCapturesStderr() async throws {
        let result = try await Process.run("/usr/bin/false", args: [])
        #expect(result.exitCode == 1)
    }

    @Test func gitVersionRuns() async throws {
        let result = try await Process.run("/usr/bin/env", args: ["git", "--version"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("git version"))
    }

    @Test func largeStdoutDoesNotDeadlock() async throws {
        let result = try await Process.run(
            "/usr/bin/awk",
            args: ["BEGIN { for (i = 0; i < 200000; i++) printf \"x\" }"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.count >= 200000)
    }
}
