import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
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

    @Test func signaledExitIsNotReportedAsTimeout() async throws {
        let result = try await Process.run("/bin/sh", args: ["-c", "kill -TERM $$"], timeout: 5)
        #expect(result.exitCode == 15)
    }

    @Test func watchdogTimeoutThrowsTimeoutError() async throws {
        do {
            _ = try await Process.run("/bin/sleep", args: ["5"], timeout: 0.1)
            Issue.record("expected timeout")
        } catch ProcessError.timedOut(let executable, _, let seconds) {
            #expect(executable == "/bin/sleep")
            #expect(seconds == 0.1)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func gitEnvSetsOptionalLocksToZero() {
        let env = Process.gitEnv()
        #expect(env["GIT_OPTIONAL_LOCKS"] == "0")
    }

    @Test func gitEnvInheritsPath() {
        // The parent process always has PATH set (xcodebuild guarantees this).
        // If we accidentally clear inherited env when adding overrides, git
        // can't be located and every git call breaks.
        let env = Process.gitEnv()
        #expect(env["PATH"] != nil)
        #expect(env["PATH"]?.isEmpty == false)
    }

    @Test func gitEnvInheritsHome() {
        // git resolves global config via HOME. Without inheritance, every
        // `git` call would run with the wrong identity / no config.
        let env = Process.gitEnv()
        #expect(env["HOME"] != nil)
    }

    @Test func gitEnvPreservesAllParentVariables() {
        // Stronger than the keyed tests above: a broken implementation that
        // returned a hardcoded minimal dict (PATH/HOME only) would pass the
        // single-key checks. Verify the whole parent env round-trips, with
        // the single deliberate exception of GIT_OPTIONAL_LOCKS.
        let parent = ProcessInfo.processInfo.environment
        let env = Process.gitEnv()
        for (key, value) in parent where key != "GIT_OPTIONAL_LOCKS" {
            #expect(env[key] == value, "key \(key) was dropped or changed")
        }
    }

    @Test func runIsCancelledViaSIGTERM() async throws {
        // /bin/sleep 5 should be SIGTERM'd via cancellation in < 1s.
        let task = Task<ProcessResult, Error> {
            try await Process.run("/bin/sleep", args: ["5"], timeout: 30)
        }
        try await Task.sleep(nanoseconds: 100_000_000)   // let it spawn
        task.cancel()
        let start = Date()
        let result = try await task.value
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 3.0, "expected cancellation to terminate quickly, took \(elapsed)s")
        // SIGTERM => exit code 15 by convention, or non-zero signal status
        #expect(result.exitCode != 0)
    }

    @Test func gitConvenienceCallStillWorks() async throws {
        // Sanity: after switching to the explicit env dict (no longer
        // passing env: nil), `Process.git` must still successfully locate
        // and run /usr/bin/env git.
        let result = try await Process.git(["--version"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("git version"))
    }
}
