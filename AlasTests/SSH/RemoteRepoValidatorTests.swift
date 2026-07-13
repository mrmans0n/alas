import Foundation
import Testing
@testable import Alas

struct RemoteRepoValidatorTests {
    @Test func validateRunsOnlyBatchRepoCheck() async throws {
        let recorder = RemoteRepoValidatorRunner(results: [
            ProcessResult(exitCode: 0, stdout: "true\n", stderr: ""),
        ])

        try await RemoteRepoValidator.validate(
            host: "devbox",
            path: "/srv/repo",
            runner: { executable, args, timeout in
                await recorder.run(executable: executable, args: args, timeout: timeout)
            }
        )

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].timeout == 30)
        #expect(calls[0].args.contains("BatchMode=yes"))
        #expect(calls[0].args.last?.contains("git -C") == true)
    }

    @Test func connectionFailurePreservesSSHDetail() async throws {
        let recorder = RemoteRepoValidatorRunner(results: [
            ProcessResult(exitCode: 255, stdout: "", stderr: "Host key verification failed."),
        ])

        do {
            try await RemoteRepoValidator.validate(
                host: "devbox",
                path: "/srv/repo",
                runner: { executable, args, timeout in
                    await recorder.run(executable: executable, args: args, timeout: timeout)
                }
            )
            Issue.record("Expected validation to fail")
        } catch let error as RemoteRepoValidationError {
            guard case let .connectionFailed(message) = error else {
                Issue.record("Expected connection failure")
                return
            }
            #expect(message == "Host key verification failed.")
        }
    }

    @Test func interactiveSetupForcesTTYAndSharesControlMaster() {
        let invocation = RemoteRepoValidator.interactiveSetupInvocation(host: "devbox")

        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.args.first == "-tt")
        #expect(invocation.args.contains("ControlMaster=auto"))
        #expect(invocation.args.contains("ControlPath=~/.ssh/alas-%C"))
        #expect(!invocation.args.contains("BatchMode=yes"))
        #expect(invocation.args.last?.contains("true") == true)
    }

    @Test func waitsForControlMasterUntilItBecomesAvailable() async {
        let recorder = RemoteRepoValidatorRunner(results: [
            ProcessResult(exitCode: 255, stdout: "", stderr: "No control socket"),
            ProcessResult(exitCode: 0, stdout: "Master running", stderr: ""),
        ])

        let connected = await RemoteRepoValidator.waitForActiveControlMaster(
            host: "devbox",
            attempts: 2,
            retryDelay: .zero,
            runner: { executable, args, timeout in
                await recorder.run(executable: executable, args: args, timeout: timeout)
            }
        )

        #expect(connected)
        let calls = await recorder.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.timeout == 5 })
        #expect(calls.allSatisfy { $0.args.contains("-O") && $0.args.contains("check") })
        #expect(calls.allSatisfy { $0.args.last == "devbox" })
    }

    @Test func controlMasterWaitIsBounded() async {
        let recorder = RemoteRepoValidatorRunner(results: [])

        let connected = await RemoteRepoValidator.waitForActiveControlMaster(
            host: "devbox",
            attempts: 2,
            retryDelay: .zero,
            runner: { executable, args, timeout in
                await recorder.run(executable: executable, args: args, timeout: timeout)
            }
        )

        #expect(!connected)
        #expect(await recorder.calls.count == 2)
    }
}

private actor RemoteRepoValidatorRunner {
    struct Call {
        let executable: String
        let args: [String]
        let timeout: TimeInterval
    }

    private(set) var calls: [Call] = []
    private var results: [ProcessResult]

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(executable: String, args: [String], timeout: TimeInterval) -> ProcessResult {
        calls.append(Call(executable: executable, args: args, timeout: timeout))
        return results.isEmpty ? ProcessResult(exitCode: 1, stdout: "", stderr: "") : results.removeFirst()
    }
}
