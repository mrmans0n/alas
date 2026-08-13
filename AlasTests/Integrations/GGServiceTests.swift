import Foundation
import Testing
@testable import Alas

private struct FakeGGRunner: GGCommandRunning {
    let result: ProcessResult
    private let recorded: RecordedArgs

    final class RecordedArgs: @unchecked Sendable {
        var args: [String] = []
        var cwd: URL?
    }

    init(result: ProcessResult, recorded: RecordedArgs = RecordedArgs()) {
        self.result = result
        self.recorded = recorded
    }

    var lastArgs: [String] { recorded.args }
    var lastCwd: URL? { recorded.cwd }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        recorded.args = args
        recorded.cwd = cwd
        return result
    }
}

struct GGServiceTests {
    @Test func processRunnerUsesGGTimeoutForEveryCommand() async throws {
        let cases: [([String], TimeInterval)] = [
            (["ls", "--json"], 600),
            (["--client-operation-id", "alas:1", "ls", "--json"], 600),
            (["ls", "--json", "--client-operation-id", "alas:1"], 600),
            (["sync", "--json"], 600),
            (["sync", "--help"], 600),
            (["ls"], 600),
            (["land", "--until", "ls", "--json", "--no-clean"], 600),
            (["--client-operation-id", "alas:1", "land", "--until", "ls", "--json", "--no-clean"], 600)
        ]

        for (args, expectedTimeout) in cases {
            let invocation = ProcessLaunchInvocation()
            let runner = ProcessGGCommandRunner { executable, launchArgs, cwd, _, timeout in
                invocation.record(
                    executable: executable,
                    args: launchArgs,
                    cwd: cwd,
                    timeout: timeout
                )
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }

            _ = try await runner.run(args: args, cwd: nil)

            #expect(invocation.executable == "/usr/bin/env")
            #expect(invocation.args == ["gg"] + args)
            #expect(invocation.timeout == expectedTimeout)
        }
    }

    @Test func probeVersionParsesOutput() async {
        let runner = FakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: "gg 0.9.8\n", stderr: "")
        )
        let service = GGService(runner: runner)
        #expect(await service.probeVersion() == "0.9.8")
        #expect(runner.lastArgs == ["--version"])
    }

    @Test func probeVersionReturnsNilWhenMissing() async {
        let runner = FakeGGRunner(
            result: ProcessResult(exitCode: 127, stdout: "", stderr: "gg: command not found")
        )
        #expect(await GGService(runner: runner).probeVersion() == nil)
    }

    @Test func currentStackDecodesStack() async throws {
        let runner = FakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        let service = GGService(runner: runner)
        let stack = try await service.currentStack(worktreePath: "/tmp/wt")
        #expect(stack?.name == "agent-inbox")
        #expect(runner.lastArgs == ["ls", "--json"])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/tmp/wt"))
    }

    @Test func currentStackReturnsNilOffStack() async throws {
        let runner = FakeGGRunner(
            result: ProcessResult(
                exitCode: 0,
                stdout: #"{"version": 1, "current_stack": null, "stacks": []}"#,
                stderr: ""
            )
        )
        let stack = try await GGService(runner: runner).currentStack(worktreePath: "/tmp/wt")
        #expect(stack == nil)
    }

    @Test func currentStackMapsExit127ToCliMissing() async {
        let runner = FakeGGRunner(
            result: ProcessResult(exitCode: 127, stdout: "", stderr: "not found")
        )
        await #expect(throws: GGServiceError.cliMissing) {
            _ = try await GGService(runner: runner).currentStack(worktreePath: "/tmp/wt")
        }
    }

    @Test func currentStackMapsNonzeroExitToCommandFailed() async {
        let runner = FakeGGRunner(
            result: ProcessResult(exitCode: 1, stdout: "", stderr: "boom")
        )
        await #expect(throws: GGServiceError.commandFailed(stderr: "boom")) {
            _ = try await GGService(runner: runner).currentStack(worktreePath: "/tmp/wt")
        }
    }

    @Test func mapConvertsExitCodesToErrors() {
        #expect(GGServiceError.map(exitCode: 127, stderr: "anything") == .cliMissing)
        #expect(GGServiceError.map(exitCode: 1, stderr: "  boom \n") == .commandFailed(stderr: "boom"))
        #expect(GGServiceError.map(exitCode: 2, stderr: "") == .commandFailed(stderr: ""))
    }
}

private final class ProcessLaunchInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (executable: String, args: [String], cwd: URL?, timeout: TimeInterval)?

    var executable: String? {
        lock.withLock { value?.executable }
    }

    var args: [String]? {
        lock.withLock { value?.args }
    }

    var timeout: TimeInterval? {
        lock.withLock { value?.timeout }
    }

    func record(executable: String, args: [String], cwd: URL?, timeout: TimeInterval) {
        lock.withLock {
            value = (executable: executable, args: args, cwd: cwd, timeout: timeout)
        }
    }
}
