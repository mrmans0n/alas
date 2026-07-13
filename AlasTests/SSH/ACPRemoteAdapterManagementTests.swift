import Foundation
import Testing
@testable import Alas

struct ACPRemoteAdapterManagementTests {
    private let environment = ACPRemoteNodeEnvironment(
        npmPath: "/opt/node/bin/npm",
        nodePath: "/opt/node/bin/node",
        binDirectory: "/opt/node/bin"
    )

    @Test func managedAdapterWinsWithoutNpm() async {
        let runner = AdapterProbeRunner(results: [
            .init(exitCode: 0, stdout: taggedReady(
                adapter: "/home/dev/.alas/acp/codex/bin/codex-acp",
                nodeBin: "/home/dev/.nvm/versions/node/v22/bin"
            ), stderr: ""),
        ])
        let management = ACPRemoteAdapterManagement(
            runner: { host, cwd, command, pathPolicy, _ in
                await runner.run(host: host, cwd: cwd, command: command, pathPolicy: pathPolicy)
            },
            nodeResolver: { _ in throw ACPRemoteNodeEnvironmentError.missing }
        )

        let resolution = await management.resolve(
            host: "devbox",
            descriptor: .codex,
            setupCheck: .npxPackage(name: ACPManagedAdapterDescriptor.codex.packageName)
        )

        #expect(resolution == .ready(.init(
            adapterPath: "/home/dev/.alas/acp/codex/bin/codex-acp",
            nodeBinDirectory: "/home/dev/.nvm/versions/node/v22/bin"
        )))
        #expect(await runner.callCount == 1)
    }

    @Test func managedPrefixTakesPrecedenceOverGlobalAdapter() async {
        let runner = AdapterProbeRunner(results: [
            .init(exitCode: 0, stdout: taggedReady(
                adapter: "/home/dev/.alas/acp/claude/bin/claude-agent-acp",
                nodeBin: "/managed/node/bin"
            ), stderr: ""),
            .init(exitCode: 0, stdout: taggedReady(
                adapter: "/usr/local/bin/claude-agent-acp",
                nodeBin: "/global/node/bin"
            ), stderr: ""),
        ])
        let management = makeManagement(runner: runner)

        let resolution = await management.resolve(
            host: "devbox",
            descriptor: .claude,
            setupCheck: managedCheck(.claude)
        )

        #expect(resolution == .ready(.init(
            adapterPath: "/home/dev/.alas/acp/claude/bin/claude-agent-acp",
            nodeBinDirectory: "/managed/node/bin"
        )))
        #expect(await runner.callCount == 1)
    }

    @Test func matchingGlobalPackageResolvesAbsoluteBinary() async {
        let runner = AdapterProbeRunner(results: [
            absentResult(),
            .init(exitCode: 0, stdout: taggedReady(
                adapter: "/opt/node/bin/pi-acp",
                nodeBin: "/opt/node/bin"
            ), stderr: ""),
        ])
        let management = makeManagement(runner: runner)

        let resolution = await management.resolve(
            host: "devbox",
            descriptor: .pi,
            setupCheck: managedCheck(.pi)
        )

        #expect(resolution == .ready(.init(
            adapterPath: "/opt/node/bin/pi-acp",
            nodeBinDirectory: "/opt/node/bin"
        )))
        let globalCommand = try? #require(await runner.commands.last)
        #expect(globalCommand?.contains("'pi-acp'") == true)
        #expect(globalCommand?.contains("'pi-acp'") == true)
        #expect(globalCommand?.contains("command -v 'pi-acp'") == true)
    }

    @Test func allowedPathFallbackComesAfterMatchingPackageCheck() async throws {
        let runner = AdapterProbeRunner(results: [absentResult(), missingResult()])
        let management = makeManagement(runner: runner)

        _ = await management.resolve(
            host: "devbox",
            descriptor: .claude,
            setupCheck: managedCheck(.claude)
        )

        let command = try #require(await runner.commands.last)
        let packageCheck = try #require(command.range(of: "[ -d \"$root/$package\" ]"))
        let pathCheck = try #require(command.range(of: "command -v 'claude-agent-acp'"))
        #expect(packageCheck.lowerBound < pathCheck.lowerBound)
    }

    @Test func globalProbeQuotesNodeBinBeforeEmittingReadyRecord() {
        let environment = ACPRemoteNodeEnvironment(
            npmPath: "/tmp/$(touch pwn)/bin/npm",
            nodePath: "/tmp/$(touch pwn)/bin/node",
            binDirectory: "/tmp/$(touch pwn)/bin"
        )

        let command = ACPRemoteAdapterManagement.globalProbeCommand(
            descriptor: .claude,
            setupCheck: managedCheck(.claude),
            environment: environment
        )

        #expect(command.contains("node_bin='/tmp/$(touch pwn)/bin'"))
        #expect(command.contains("\"nodeBin=$node_bin\""))
        #expect(!command.contains("\"nodeBin=/tmp/$(touch pwn)/bin\""))
    }

    @Test func codexRejectsStalePathOnlyBinary() async throws {
        let runner = AdapterProbeRunner(results: [absentResult(), missingResult()])
        let management = makeManagement(runner: runner)

        let resolution = await management.resolve(
            host: "devbox",
            descriptor: .codex,
            setupCheck: .npxPackage(name: ACPManagedAdapterDescriptor.codex.packageName)
        )

        guard case .missing = resolution else {
            Issue.record("Expected a confirmed missing adapter")
            return
        }
        let command = try #require(await runner.commands.last)
        #expect(!command.contains("command -v 'codex-acp'"))
        #expect(command.contains("'@agentclientprotocol/codex-acp'"))
    }

    @Test func confirmedAbsenceWithUsablePrerequisitesIsMissing() async {
        let runner = AdapterProbeRunner(results: [absentResult(), missingResult()])
        let resolution = await makeManagement(runner: runner).resolve(
            host: "devbox",
            descriptor: .codex,
            setupCheck: .npxPackage(name: ACPManagedAdapterDescriptor.codex.packageName)
        )

        #expect(resolution == .missing(reason: "codex-acp is not installed on devbox."))
    }

    @Test func missingNodeOrNpmIsAnError() async {
        let runner = AdapterProbeRunner(results: [absentResult()])
        let management = ACPRemoteAdapterManagement(
            runner: { host, cwd, command, pathPolicy, _ in
                await runner.run(host: host, cwd: cwd, command: command, pathPolicy: pathPolicy)
            },
            nodeResolver: { _ in throw ACPRemoteNodeEnvironmentError.missing }
        )

        let resolution = await management.resolve(
            host: "devbox",
            descriptor: .codex,
            setupCheck: .npxPackage(name: ACPManagedAdapterDescriptor.codex.packageName)
        )

        guard case .error(let message) = resolution else {
            Issue.record("Expected prerequisite failure")
            return
        }
        #expect(message.contains("Node.js and npm"))
    }

    @Test func pathOnlyAdapterResolvesWhenNpmIsUnavailable() async {
        let runner = AdapterProbeRunner(results: [
            absentResult(),
            .init(exitCode: 0, stdout: taggedReady(
                adapter: "/usr/local/bin/claude-agent-acp",
                nodeBin: "/usr/local/bin"
            ), stderr: ""),
        ])
        let management = ACPRemoteAdapterManagement(
            runner: { host, cwd, command, pathPolicy, _ in
                await runner.run(host: host, cwd: cwd, command: command, pathPolicy: pathPolicy)
            },
            nodeResolver: { _ in throw ACPRemoteNodeEnvironmentError.missing }
        )

        let resolution = await management.resolve(
            host: "devbox",
            descriptor: .claude,
            setupCheck: managedCheck(.claude)
        )

        #expect(resolution == .ready(.init(
            adapterPath: "/usr/local/bin/claude-agent-acp",
            nodeBinDirectory: "/usr/local/bin"
        )))
        let command = try? #require(await runner.commands.last)
        #expect(command?.contains("command -v 'claude-agent-acp'") == true)
        #expect(command?.contains("command -v node") == true)
        #expect(command?.contains("npm root -g") == false)
        #expect(await runner.pathPolicies.last == .augmented)
    }

    @Test func sshFailureAndMalformedOutputAreErrors() async {
        let sshRunner = AdapterProbeRunner(results: [
            .init(exitCode: 255, stdout: "", stderr: "Host key verification failed"),
        ])
        let malformedRunner = AdapterProbeRunner(results: [
            .init(exitCode: 0, stdout: "not tagged", stderr: ""),
        ])

        let ssh = await makeManagement(runner: sshRunner).resolve(
            host: "devbox", descriptor: .pi, setupCheck: managedCheck(.pi)
        )
        let malformed = await makeManagement(runner: malformedRunner).resolve(
            host: "devbox", descriptor: .pi, setupCheck: managedCheck(.pi)
        )

        #expect(ssh == .error(message: "Host key verification failed"))
        guard case .error(let message) = malformed else {
            Issue.record("Expected malformed output to be an error")
            return
        }
        #expect(message.contains("malformed"))
    }

    @Test func corruptManagedPrefixDoesNotFallThrough() async {
        let runner = AdapterProbeRunner(results: [
            .init(
                exitCode: ACPRemoteAdapterManagement.corruptExitCode,
                stdout: taggedStatus("corrupt"),
                stderr: ""
            ),
        ])
        let resolution = await makeManagement(runner: runner).resolve(
            host: "devbox", descriptor: .pi, setupCheck: managedCheck(.pi)
        )

        guard case .error(let message) = resolution else {
            Issue.record("Expected corrupt prefix to be an error")
            return
        }
        #expect(message.contains("managed"))
        #expect(await runner.callCount == 1)
    }

    @Test func managedPathsAreAgentIsolated() {
        #expect(ACPRemoteAdapterManagement.managedPrefix(for: .claude) == "$HOME/.alas/acp/claude")
        #expect(ACPRemoteAdapterManagement.managedPrefix(for: .codex) == "$HOME/.alas/acp/codex")
        #expect(ACPRemoteAdapterManagement.managedPrefix(for: .pi) == "$HOME/.alas/acp/pi")
    }

    @Test func managedProbePinsResolvedNodeDirectory() {
        let command = ACPRemoteAdapterManagement.managedProbeCommand(
            descriptor: .codex,
            nodeBinDirectory: "/home/dev/.nvm/versions/node/v22/bin"
        )

        #expect(command.contains("node_bin='/home/dev/.nvm/versions/node/v22/bin'"))
        #expect(command.contains("node=\"$node_bin/node\""))
        #expect(!command.contains("command -v node"))
    }

    private func makeManagement(runner: AdapterProbeRunner) -> ACPRemoteAdapterManagement {
        ACPRemoteAdapterManagement(
            runner: { host, cwd, command, pathPolicy, _ in
                await runner.run(host: host, cwd: cwd, command: command, pathPolicy: pathPolicy)
            },
            nodeResolver: { _ in environment }
        )
    }

    private func managedCheck(_ descriptor: ACPManagedAdapterDescriptor) -> ACPSetupCheck {
        .binaryOnPathOrNpmPackage(
            binary: descriptor.binaryName,
            npmPackage: descriptor.packageName
        )
    }
}

private func taggedReady(adapter: String, nodeBin: String) -> String {
    ([ACPRemoteAdapterManagement.protocolBegin, "status=ready", "adapter=\(adapter)",
      "nodeBin=\(nodeBin)", ACPRemoteAdapterManagement.protocolEnd]).joined(separator: "\n") + "\n"
}

private func taggedStatus(_ status: String) -> String {
    ([ACPRemoteAdapterManagement.protocolBegin, "status=\(status)",
      ACPRemoteAdapterManagement.protocolEnd]).joined(separator: "\n") + "\n"
}

private func absentResult() -> ProcessResult {
    ProcessResult(
        exitCode: ACPRemoteAdapterManagement.absentExitCode,
        stdout: taggedStatus("absent"),
        stderr: ""
    )
}

private func missingResult() -> ProcessResult {
    ProcessResult(
        exitCode: ACPRemoteAdapterManagement.missingExitCode,
        stdout: taggedStatus("missing"),
        stderr: ""
    )
}

private actor AdapterProbeRunner {
    private var results: [ProcessResult]
    private(set) var commands: [String] = []
    private(set) var pathPolicies: [SSHCommand.PathPolicy] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    var callCount: Int { commands.count }

    func run(
        host: String,
        cwd: String?,
        command: String,
        pathPolicy: SSHCommand.PathPolicy
    ) -> ProcessResult {
        commands.append(command)
        pathPolicies.append(pathPolicy)
        return results.isEmpty
            ? ProcessResult(exitCode: 99, stdout: "", stderr: "Unexpected probe")
            : results.removeFirst()
    }
}
