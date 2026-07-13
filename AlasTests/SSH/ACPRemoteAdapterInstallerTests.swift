import Foundation
import Testing
@testable import Alas

@Suite("ACPRemoteAdapterInstaller")
struct ACPRemoteAdapterInstallerTests {
    private let environment = ACPRemoteNodeEnvironment(
        npmPath: "/opt/node 22/bin/npm",
        nodePath: "/opt/node 22/bin/node",
        binDirectory: "/opt/node 22/bin"
    )

    @Test("install uses a unique private staging prefix and pinned Node environment")
    func stagedInstallCommand() async throws {
        let runner = RemoteInstallRunner(results: [success(), success()])
        let management = makeManagement(runner)

        try await management.install(host: "buildbox", descriptor: .codex)
        try await management.install(host: "buildbox", descriptor: .codex)

        let commands = await runner.commands
        #expect(commands.count == 2)
        #expect(commands[0] != commands[1])
        #expect(await runner.timeouts == [
            ACPRemoteAdapterManagement.installTimeout,
            ACPRemoteAdapterManagement.installTimeout,
        ])
        let command = commands[0]
        #expect(command.contains("PATH='/opt/node 22/bin':\"$PATH\""))
        #expect(command.contains("'/opt/node 22/bin/npm' --prefix \"$stage\" install -g '@agentclientprotocol/codex-acp'"))
        #expect(command.contains("staging_root=$HOME/.alas/acp/.staging"))
        #expect(command.contains("live=$HOME/.alas/acp/'codex'"))
        #expect(command.contains("stage=\"$staging_root/codex-"))
        #expect(command.contains("uninstall -g '@zed-industries/codex-acp' >/dev/null 2>&1 || :"))
        #expect(command.contains("[ -d \"$stage/lib/node_modules/$package\" ]"))
        #expect(command.contains("[ -x \"$stage/bin/$binary\" ]"))
        #expect(command.contains("trap cleanup_stage EXIT"))
        #expect(command.contains("lock=\"$staging_root/.locks/codex.lock\""))
        #expect(command.contains("acquire_promotion_lock || exit 43"))
        #expect(command.contains("mkdir \"$lock\""))
        #expect(command.contains("\"$$\" > \"$lock/pid\""))
        #expect(command.contains("rm -f \"$lock/pid\" >/dev/null 2>&1 || :"))
        #expect(command.contains("rmdir \"$lock\" >/dev/null 2>&1 || :"))
        #expect(command.contains("owner=$(cat \"$lock/pid\" 2>/dev/null || :)"))
        #expect(command.contains("kill -0 \"$owner\" 2>/dev/null"))
        #expect(command.contains("was interrupted. Remove $lock"))
        #expect(!command.contains("rm -rf \"$lock\""))
    }

    @Test("promotion transaction backs up, validates, rolls back, then cleans backup")
    func promotionTransactionOrder() throws {
        let command = ACPRemoteAdapterManagement.installCommand(
            descriptor: .claude,
            environment: environment,
            transactionID: "transaction-1"
        )

        let backup = try #require(command.range(of: "mv \"$live\" \"$backup\""))
        let lock = try #require(command.range(of: "acquire_promotion_lock || exit 43"))
        let promotion = try #require(command.range(of: "mv \"$stage\" \"$live\""))
        let finalValidation = try #require(command.range(of: "[ ! -d \"$live/lib/node_modules/$package\" ]"))
        let rollback = try #require(command.range(
            of: "mv \"$backup\" \"$live\" || exit 41",
            range: finalValidation.upperBound..<command.endIndex
        ))
        let backupCleanup = try #require(command.range(of: "rm -rf \"$backup\" || exit 42"))

        #expect(lock.lowerBound < backup.lowerBound)
        #expect(backup.lowerBound < promotion.lowerBound)
        #expect(promotion.lowerBound < finalValidation.lowerBound)
        #expect(finalValidation.lowerBound < rollback.lowerBound)
        #expect(rollback.lowerBound < backupCleanup.lowerBound)
        #expect(command.contains("if ! mv \"$stage\" \"$live\"; then"))
        #expect(command.contains("exit 39"))
        #expect(command.contains("exit 40"))
        #expect(command.contains("exit 41"))
    }

    @Test("transaction exit codes are reserved above discovery codes")
    func transactionExitCodes() {
        let codes: [Int32] = [
            ACPRemoteAdapterManagement.stagingExitCode,
            ACPRemoteAdapterManagement.npmInstallExitCode,
            ACPRemoteAdapterManagement.stagedPackageExitCode,
            ACPRemoteAdapterManagement.stagedBinaryExitCode,
            ACPRemoteAdapterManagement.backupExitCode,
            ACPRemoteAdapterManagement.promotionExitCode,
            ACPRemoteAdapterManagement.promotedValidationExitCode,
            ACPRemoteAdapterManagement.rollbackExitCode,
            ACPRemoteAdapterManagement.backupCleanupExitCode,
            ACPRemoteAdapterManagement.promotionLockExitCode,
        ]
        #expect(codes.allSatisfy { $0 > ACPRemoteAdapterManagement.corruptExitCode })
        #expect(Set(codes).count == codes.count)
    }

    @Test("stderr is sanitized and bounded")
    func boundedFailureDetail() async {
        let stderr = "bad\u{0}detail" + String(repeating: "x", count: 5_000)
        let runner = RemoteInstallRunner(results: [
            ProcessResult(exitCode: ACPRemoteAdapterManagement.npmInstallExitCode, stdout: "", stderr: stderr),
        ])

        do {
            try await makeManagement(runner).install(host: "buildbox", descriptor: .pi)
            Issue.record("Expected installation failure")
        } catch let error as ACPRemoteAdapterInstallError {
            guard case .executionFailure(let code, let detail) = error else {
                Issue.record("Expected typed execution failure")
                return
            }
            #expect(code == ACPRemoteAdapterManagement.npmInstallExitCode)
            #expect(detail.count <= ACPRemoteAdapterManagement.maximumInstallDetailLength)
            #expect(!detail.contains("\u{0}"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("SSH and prerequisite failures remain distinct")
    func typedFailures() async {
        let sshRunner = RemoteInstallRunner(results: [
            ProcessResult(exitCode: 255, stdout: "", stderr: "Host key failed"),
        ])
        do {
            try await makeManagement(sshRunner).install(host: "buildbox", descriptor: .pi)
            Issue.record("Expected SSH failure")
        } catch let error as ACPRemoteAdapterInstallError {
            #expect(error == .connectionFailure("Host key failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let management = ACPRemoteAdapterManagement(
            runner: { _, _, _, _, _ in Self.success() },
            nodeResolver: { _ in throw ACPRemoteNodeEnvironmentError.missing }
        )
        do {
            try await management.install(host: "buildbox", descriptor: .pi)
            Issue.record("Expected prerequisite failure")
        } catch let error as ACPRemoteAdapterInstallError {
            guard case .prerequisite = error else {
                Issue.record("Expected prerequisite error")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeManagement(_ runner: RemoteInstallRunner) -> ACPRemoteAdapterManagement {
        ACPRemoteAdapterManagement(
            runner: { host, cwd, command, pathPolicy, timeout in
                await runner.run(
                    host: host,
                    cwd: cwd,
                    command: command,
                    pathPolicy: pathPolicy,
                    timeout: timeout
                )
            },
            nodeResolver: { _ in environment }
        )
    }

    private static func success() -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    private func success() -> ProcessResult { Self.success() }
}

private actor RemoteInstallRunner {
    private var results: [ProcessResult]
    private(set) var commands: [String] = []
    private(set) var timeouts: [TimeInterval] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(
        host: String,
        cwd: String?,
        command: String,
        pathPolicy: SSHCommand.PathPolicy,
        timeout: TimeInterval
    ) -> ProcessResult {
        commands.append(command)
        timeouts.append(timeout)
        return results.removeFirst()
    }
}
