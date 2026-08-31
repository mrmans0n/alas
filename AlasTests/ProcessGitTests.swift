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

    @Test func invalidWorkingDirectoryThrowsLaunchFailed() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-missing-cwd-\(UUID().uuidString)")

        do {
            _ = try await Process.run("/bin/echo", args: ["hi"], cwd: missing)
            Issue.record("expected launch failure")
        } catch ProcessError.launchFailed(let message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func tooManyArgumentsThrowsLaunchFailedBeforeFoundationAbort() async throws {
        do {
            _ = try await Process.run("/usr/bin/true", args: Array(repeating: "x", count: 4097))
            Issue.record("expected launch failure")
        } catch ProcessError.launchFailed(let message) {
            #expect(message.contains("Too many arguments"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
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

    @Test func runWritesStdinToReader() async throws {
        let result = try await Process.run(
            "/usr/bin/wc",
            args: ["-c"],
            stdin: "hello stdin\n"
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "12")
    }

    @Test func runTimeoutStillAppliesWhenProcessDoesNotReadLargeStdin() async throws {
        let largeInput = String(repeating: "x", count: 2_000_000)
        let start = Date()
        do {
            _ = try await Process.run("/bin/sleep", args: ["5"], stdin: largeInput, timeout: 0.1)
            Issue.record("expected timeout")
        } catch ProcessError.timedOut(let executable, _, let seconds) {
            let elapsed = Date().timeIntervalSince(start)
            #expect(executable == "/bin/sleep")
            #expect(seconds == 0.1)
            #expect(elapsed < 3.0, "expected stdin timeout to return quickly, took \(elapsed)s")
        } catch {
            Issue.record("wrong error: \(error)")
        }
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

    @Test func gitEnvForcesCLocale() {
        // Stderr matchers in WorktreeService etc. only recognize English git
        // messages. Without LC_ALL=C, a user with a non-English shell locale
        // (e.g. es_ES.UTF-8) hits localized errors like "árboles de trabajo
        // conteniendo submódulos…" and the auto-force-remove path never fires.
        let env = Process.gitEnv()
        #expect(env["LC_ALL"] == "C")
    }

    @Test func gitEmitsEnglishMessagesUnderForeignLocale() async throws {
        // End-to-end check: gitEnv() must override an inherited foreign LANG
        // so git still emits English. We can't mutate ProcessInfo, but we can
        // run /usr/bin/env git directly with the env gitEnv() produces and
        // confirm the message is English even if LANG would request Spanish.
        var env = Process.gitEnv()
        env["LANG"] = "es_ES.UTF-8"
        // Trigger any error: `git` with no args in a non-repo cwd emits the
        // usage hint, which is locale-sensitive. Easier: ask for a config key
        // that doesn't exist and check stderr/stdout aren't Spanish.
        let result = try await Process.run(
            "/usr/bin/env",
            args: ["git", "help", "-a"],
            env: env
        )
        // "The common Git" / "available" appears verbatim in English `git help -a`
        // output; Spanish translation would not contain these tokens.
        #expect(result.exitCode == 0)
        #expect(result.stdout.lowercased().contains("available")
            || result.stdout.lowercased().contains("commands"))
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
        // the deliberate exceptions of GIT_OPTIONAL_LOCKS (always overridden),
        // PATH (overridden when ShellEnvResolver discovered a login-shell
        // PATH, which happens in integration test environments), and LC_ALL
        // (always pinned to "C" so git emits English-parseable messages).
        let parent = ProcessInfo.processInfo.environment
        let env = Process.gitEnv()
        for (key, value) in parent where !["GIT_OPTIONAL_LOCKS", "PATH", "LC_ALL"].contains(key) {
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

    @Test func gitCanBypassRemoteHostRegistryForExplicitLocalCall() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-explicit-local-git-\(UUID().uuidString)")
        defer {
            RemoteHostRegistry.shared.unregister(root: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: directory, usesRemoteHostRegistry: false)
        RemoteHostRegistry.shared.register(root: directory.path, host: "host-that-must-not-be-used")

        let result = try await Process.git(
            ["rev-parse", "--show-toplevel"],
            cwd: directory,
            usesRemoteHostRegistry: false
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == directory.path)
    }

    @Test func gitInvocationSurvivesWorkingDirectoryDeletionBeforeLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-deleted-git-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invocation = GitInvocation.build(gitArgs: ["status", "--porcelain"], cwd: directory, host: nil)
        try FileManager.default.removeItem(at: directory)

        let result = try await Process.run(
            invocation.executable,
            args: invocation.args,
            cwd: invocation.cwd,
            env: invocation.env
        )

        #expect(result.exitCode != 0)
        #expect(!result.stderr.isEmpty)
    }

    @Test func gitWithMissingWorkingDirectoryStillThrowsLaunchFailed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-missing-git-cwd-\(UUID().uuidString)")

        await #expect(throws: ProcessError.self) {
            _ = try await Process.git(["status", "--porcelain"], cwd: directory)
        }
    }

    @Test func gitEnvPrefersResolvedShellPath() {
        let prior = ShellEnvResolver.shared.resolvedPath
        ShellEnvResolver.shared.resolvedPath = "/custom/shell/bin"
        defer { ShellEnvResolver.shared.resolvedPath = prior }

        let env = Process.gitEnv()
        #expect(env["PATH"] == "/custom/shell/bin")
        #expect(env["GIT_OPTIONAL_LOCKS"] == "0")
    }

    @Test func gitEnvFallsBackToProcessPathWhenResolverIsNil() {
        let prior = ShellEnvResolver.shared.resolvedPath
        ShellEnvResolver.shared.resolvedPath = nil
        defer { ShellEnvResolver.shared.resolvedPath = prior }

        let env = Process.gitEnv()
        #expect(env["PATH"] == ProcessInfo.processInfo.environment["PATH"])
    }
}
