import Foundation
import Testing
@testable import Alas

struct RemoteRepoValidatorTests {
    @Test func validateRunsInteractivePreflightBeforeBatchRepoCheck() async throws {
        let recorder = RemoteRepoValidatorRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
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
        #expect(calls.count == 2)
        #expect(calls[0].timeout == 30)
        #expect(!calls[0].args.contains("BatchMode=yes"))
        #expect(calls[0].args.contains("ConnectTimeout=30"))
        #expect(calls[0].args.last?.contains("true") == true)
        #expect(calls[1].timeout == 30)
        #expect(calls[1].args.contains("BatchMode=yes"))
        #expect(calls[1].args.last?.contains("git -C") == true)
    }

    @Test func preflightFailureTellsUserToConnectFirst() async throws {
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
            guard case let .unreachable(message) = error else {
                Issue.record("Expected unreachable error")
                return
            }
            #expect(message.contains("Run `/usr/bin/ssh"))
            #expect(message.contains("ControlMaster=auto"))
            #expect(message.contains("devbox"))
            #expect(message.contains("Host key verification failed."))
        }
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
