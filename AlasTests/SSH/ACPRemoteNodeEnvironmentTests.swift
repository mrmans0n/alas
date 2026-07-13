import Foundation
import Testing
@testable import Alas

struct ACPRemoteNodeEnvironmentTests {
    @Test func discoveryUsesInheritedPathWithoutWorkingDirectory() async throws {
        let recorder = NodeEnvironmentRunner(result: .resolved())
        let resolver = ACPRemoteNodeEnvironmentResolver { host, cwd, command, pathPolicy in
            await recorder.run(host: host, cwd: cwd, command: command, pathPolicy: pathPolicy)
        }

        let environment = try await resolver.resolve(host: "builder")

        #expect(environment == ACPRemoteNodeEnvironment(
            npmPath: "/opt/node/bin/npm",
            nodePath: "/opt/node/bin/node",
            binDirectory: "/opt/node/bin"
        ))
        let call = try #require(await recorder.call)
        #expect(call.host == "builder")
        #expect(call.cwd == nil)
        #expect(call.pathPolicy == .inherited)
        #expect(call.command == ACPRemoteNodeEnvironmentResolver.discoveryCommand)
    }

    @Test func discoveryCommandChecksPathBeforeKnownLocations() {
        let command = ACPRemoteNodeEnvironmentResolver.discoveryCommand
        let pathCheck = command.range(of: "path_npm=$(command -v npm")
        let nvmCheck = command.range(of: "try_env_dir \"$NVM_BIN\"")
        let homebrewCheck = command.range(of: "try_dir '/opt/homebrew/bin'")
        #expect(pathCheck != nil)
        #expect(nvmCheck != nil)
        #expect(homebrewCheck != nil)
        if let pathCheck, let nvmCheck, let homebrewCheck {
            #expect(pathCheck.lowerBound < nvmCheck.lowerBound)
            #expect(nvmCheck.lowerBound < homebrewCheck.lowerBound)
        }
    }

    @Test func discoveryCommandCoversSupportedManagersAndCommonPaths() {
        let command = ACPRemoteNodeEnvironmentResolver.discoveryCommand
        for expected in [
            "$NVM_BIN",
            "$VOLTA_HOME/bin",
            "$mise_root/shims",
            "$asdf_root/shims",
            "$volta_root/bin",
            "$nvm_root/current/bin",
            "$mise_root/installs/node",
            "$asdf_root/installs/nodejs",
            "$nvm_root/versions/node",
            "$HOME/.local/bin",
            "$HOME/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/home/linuxbrew/.linuxbrew/bin",
            "/usr/bin",
        ] {
            #expect(command.contains(expected), "Missing discovery candidate: \(expected)")
        }
        #expect(!command.contains("source "))
        #expect(!command.contains("readlink"))
        #expect(!command.contains("realpath"))
        #expect(!command.contains("sort -V"))
    }

    @Test func discoveryCommandUsesPortableAwkAndRetriesIncompleteVersions() {
        let command = ACPRemoteNodeEnvironmentResolver.discoveryCommand
        #expect(command.contains("for (part = 1; part <= count; part++)"))
        #expect(!command.contains("for (index ="))
        #expect(command.contains("attempted=\u{27}|\u{27}"))
        #expect(command.contains("attempted=\"${attempted}${best_version}|\""))
    }

    @Test func parsesPathsContainingSpacesAndEqualsSigns() async throws {
        let result = ProcessResult.resolved(bin: "/Users/build tools/node=22/bin")
        let resolver = resolver(returning: result)

        let environment = try await resolver.resolve(host: "builder")

        #expect(environment.binDirectory == "/Users/build tools/node=22/bin")
        #expect(environment.npmPath == "/Users/build tools/node=22/bin/npm")
    }

    @Test func missingStatusAndReservedExitClassifyMissing() async {
        let resolver = resolver(returning: ProcessResult(
            exitCode: ACPRemoteNodeEnvironmentResolver.missingExitCode,
            stdout: nodeEnvironmentTagged("status=missing"),
            stderr: ""
        ))
        await expectError(.missing, from: resolver)
    }

    @Test func exit255ClassifiesConnectionFailureBeforeParsing() async {
        let resolver = resolver(returning: ProcessResult(
            exitCode: 255,
            stdout: "not protocol output",
            stderr: "  Host key verification failed.\n"
        ))
        await expectError(.connectionFailure("Host key verification failed."), from: resolver)
    }

    @Test func otherExitClassifiesExecutionFailure() async {
        let resolver = resolver(returning: ProcessResult(
            exitCode: 7,
            stdout: nodeEnvironmentTagged("status=missing"),
            stderr: "  awk failed\n"
        ))
        await expectError(.executionFailure(exitCode: 7, detail: "awk failed"), from: resolver)
    }

    @Test func thrownRunnerErrorClassifiesExecutionFailure() async {
        struct SampleError: LocalizedError {
            var errorDescription: String? { "process launch failed" }
        }
        let resolver = ACPRemoteNodeEnvironmentResolver { _, _, _, _ in
            throw SampleError()
        }
        await expectError(
            .executionFailure(exitCode: nil, detail: "process launch failed"),
            from: resolver
        )
    }

    @Test(arguments: [
        "",
        "noise\n" + nodeEnvironmentTagged("status=missing"),
        nodeEnvironmentTagged("status=ok", "npm=/x/bin/npm", "node=/x/bin/node"),
        nodeEnvironmentTagged("status=ok", "npm=relative/npm", "node=relative/node", "bin=relative"),
        nodeEnvironmentTagged("status=ok", "npm=/x/bin/npm", "node=/other/bin/node", "bin=/x/bin"),
        nodeEnvironmentTagged("status=ok", "npm=/x/bin/npm", "npm=/x/bin/npm", "node=/x/bin/node", "bin=/x/bin"),
        nodeEnvironmentTagged("status=ok", "npm=/x/bin/npm", "node=/x/bin/node", "bin=/x/bin")
            + "\n" + nodeEnvironmentTagged("status=ok", "npm=/y/bin/npm", "node=/y/bin/node", "bin=/y/bin"),
        nodeEnvironmentTagged("status=ok", "npm=/x/bin/npm", "node=/x/bin/node", "bin=/x/bin", "extra=value"),
        "ALAS_NODE_ENV_V1_BEGIN\r\nstatus=missing\r\nALAS_NODE_ENV_V1_END\r\n",
    ])
    func rejectsMalformedResolvedOutput(_ output: String) async {
        let resolver = resolver(returning: ProcessResult(exitCode: 0, stdout: output, stderr: ""))
        await expectError(.malformedOutput, from: resolver)
    }

    @Test(arguments: [
        nodeEnvironmentTagged("status=ok", "npm=/x/bin/npm", "node=/x/bin/node", "bin=/x/bin"),
        nodeEnvironmentTagged("status=missing", "extra=value"),
        nodeEnvironmentTagged("status=missing", "status=missing"),
        "status=missing\n",
    ])
    func rejectsMalformedMissingOutput(_ output: String) async {
        let resolver = resolver(returning: ProcessResult(
            exitCode: ACPRemoteNodeEnvironmentResolver.missingExitCode,
            stdout: output,
            stderr: ""
        ))
        await expectError(.malformedOutput, from: resolver)
    }

    private func resolver(returning result: ProcessResult) -> ACPRemoteNodeEnvironmentResolver {
        ACPRemoteNodeEnvironmentResolver { _, _, _, _ in result }
    }

    private func expectError(
        _ expected: ACPRemoteNodeEnvironmentError,
        from resolver: ACPRemoteNodeEnvironmentResolver
    ) async {
        do {
            _ = try await resolver.resolve(host: "builder")
            Issue.record("Expected remote Node environment resolution to fail")
        } catch let error as ACPRemoteNodeEnvironmentError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private func nodeEnvironmentTagged(_ fields: String...) -> String {
    ([ACPRemoteNodeEnvironmentResolver.protocolBegin] + fields + [
        ACPRemoteNodeEnvironmentResolver.protocolEnd,
    ]).joined(separator: "\n") + "\n"
}

private extension ProcessResult {
    static func resolved(bin: String = "/opt/node/bin") -> ProcessResult {
        ProcessResult(
            exitCode: 0,
            stdout: nodeEnvironmentTagged(
                "status=ok",
                "npm=\(bin)/npm",
                "node=\(bin)/node",
                "bin=\(bin)"
            ),
            stderr: ""
        )
    }
}

private actor NodeEnvironmentRunner {
    struct Call: Sendable {
        let host: String
        let cwd: String?
        let command: String
        let pathPolicy: SSHCommand.PathPolicy
    }

    private(set) var call: Call?
    private let result: ProcessResult

    init(result: ProcessResult) {
        self.result = result
    }

    func run(
        host: String,
        cwd: String?,
        command: String,
        pathPolicy: SSHCommand.PathPolicy
    ) -> ProcessResult {
        call = Call(host: host, cwd: cwd, command: command, pathPolicy: pathPolicy)
        return result
    }
}
