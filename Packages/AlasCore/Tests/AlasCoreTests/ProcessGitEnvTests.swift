import Darwin
import Foundation
import Testing
@testable import AlasPlatform

struct ProcessGitEnvTests {
    @Test(arguments: [
        (false, [String: String](), nil as String?, nil as String?, nil as String?),
        (true, [:], "0", "ssh -o BatchMode=yes", "never"),
        (true, ["GIT_SSH_COMMAND": "ssh -i key"], "0", "ssh -i key", "never"),
    ])
    func gitEnvNeverPromptsOnlyWhereAskedAndKeepsAConfiguredSSHCommand(
        neverPrompts: Bool, base: [String: String], prompt: String?, ssh: String?, credentialManager: String?
    ) {
        let env = Process.gitEnv(base: base, neverPrompts: neverPrompts)
        #expect(env["GIT_TERMINAL_PROMPT"] == prompt)
        #expect(env["GCM_INTERACTIVE"] == credentialManager)
        #expect(env["GIT_SSH_COMMAND"] == ssh)
    }

    /// The output handler can hit the cap before `run()` marks the child running.
    /// The fixture forces that window with one real writer per variant.
    @Test(arguments: [false, true])
    func childrenReachingTheCapDuringLaunchAreStillStopped(capped: Bool) async throws {
        let process = CapDuringLaunchProcess()
        defer { process.stopForCleanup() }
        try await Process.$outputCappedProcessFactory.withValue({ process }) {
            if capped {
                let result = try await Process.runCapped("/usr/bin/yes", args: [], maxOutputBytes: 64 * 1024, timeout: 15)
                #expect(result.stdoutTruncated)
                #expect(result.stdout.utf8.count == 64 * 1024)
            } else {
                await #expect {
                    _ = try await Process.runData("/usr/bin/yes", args: [], timeout: 15, maxOutputBytes: 64 * 1024)
                } throws: { error in
                    if case ProcessError.outputTooLarge(maxBytes: 64 * 1024) = error { true } else { false }
                }
            }
        }
        try #require(process.observedEarlyTermination)
        try await eventually(within: .seconds(15)) { kill(process.processIdentifier, 0) != 0 }
    }
}

/// NSTask is a class cluster, so forward its concrete behavior and control only
/// the running observation during launch. The child, output, signals, and reaping stay real.
private final class CapDuringLaunchProcess: Process, @unchecked Sendable {
    private let child = Process()
    private let lock = NSLock()
    private let terminationAttempt = DispatchSemaphore(value: 0)
    private var launching = true
    private var earlyTermination = false

    var observedEarlyTermination: Bool { lock.withLock { earlyTermination } }

    override var executableURL: URL? { get { child.executableURL } set { child.executableURL = newValue } }
    override var arguments: [String]? { get { child.arguments } set { child.arguments = newValue } }
    override var currentDirectoryURL: URL? { get { child.currentDirectoryURL } set { child.currentDirectoryURL = newValue } }
    override var environment: [String: String]? { get { child.environment } set { child.environment = newValue } }
    override var standardInput: Any? { get { child.standardInput } set { child.standardInput = newValue } }
    override var standardOutput: Any? { get { child.standardOutput } set { child.standardOutput = newValue } }
    override var standardError: Any? { get { child.standardError } set { child.standardError = newValue } }
    override var terminationHandler: (@Sendable (Process) -> Void)? { get { child.terminationHandler } set { child.terminationHandler = newValue } }
    override var processIdentifier: Int32 { child.processIdentifier }
    override var terminationStatus: Int32 { child.terminationStatus }
    override func terminate() { child.terminate() }

    override var isRunning: Bool {
        if lock.withLock({ launching }) {
            terminationAttempt.signal()
            return false
        }
        return child.isRunning
    }

    override func run() throws {
        try child.run()
        let observed = terminationAttempt.wait(timeout: .now() + 15) == .success
        lock.withLock {
            launching = false
            earlyTermination = observed
        }
        guard observed else {
            stopForCleanup()
            throw FixtureError.capWasNotReachedDuringLaunch
        }
    }

    func stopForCleanup() { terminateProcessWithEscalation(child) }

    private enum FixtureError: Error { case capWasNotReachedDuringLaunch }
}
