import Testing
import Darwin
import Foundation
@testable import Alas

struct AgentRunnerInvocationTests {
    private func shim(named name: String, in tmp: URL) throws -> (recordFile: URL, path: String) {
        let recordFile = tmp.appendingPathComponent("\(name).record")
        let script = """
        #!/bin/sh
        printf 'argv=' > "\(recordFile.path)"
        for arg in "$@"; do printf '%s\\n' "$arg" >> "\(recordFile.path)"; done
        printf 'stdin=\\n' >> "\(recordFile.path)"
        cat >> "\(recordFile.path)"
        printf 'subject from \(name)\\n\\nbody from \(name)\\n'
        """
        let bin = tmp.appendingPathComponent(name)
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bin.path
        )
        return (recordFile, "\(tmp.path):/usr/bin:/bin")
    }

    private func makeTmp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func agent(id: String, binary: String, args: [String]) -> AgentDefinition {
        AgentDefinition(
            id: id, displayName: id, binary: binary,
            binaryOverride: nil, promptModeArgs: args,
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
    }

    @Test func sshInvocationUsesRemoteWorktreeAndQuotedAgentArguments() throws {
        let invocation = try AgentRunner.processInvocation(
            agent: agent(id: "custom", binary: "agent tool", args: ["--mode", "review now"]),
            input: "payload",
            prompt: "Prompt's text",
            target: .ssh(host: "dev@example"),
            workingDirectory: "/srv/repo with space",
            environment: ["PATH": "/local-only"]
        )

        #expect(invocation.executable == SSHCommand.executable)
        #expect(invocation.arguments.contains("dev@example"))
        #expect(invocation.arguments.last?.contains("cd '\\''/srv/repo with space'\\''") == true)
        #expect(invocation.arguments.last?.contains("'review now'") == true)
        #expect(invocation.currentDirectory == FileManager.default.temporaryDirectory.path)
        #expect(invocation.environment["PATH"] != "/local-only")
    }

    @Test func sshInvocationExecutesHomeRelativeConfiguredBinaryOnRemoteShell() throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("remote-home")
        let bin = home.appendingPathComponent("bin")
        let worktree = tmp.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("agent")
        try "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$1\" \"$2\" \"$3\"\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let invocation = try AgentRunner.processInvocation(
            agent: agent(id: "custom", binary: "~/bin/agent", args: ["--mode", "review now"]),
            input: "payload",
            prompt: "Prompt's text",
            target: .ssh(host: "dev@example"),
            workingDirectory: worktree.path,
            environment: [:]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try #require(invocation.arguments.last)]
        process.currentDirectoryURL = worktree
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output

        try process.run()
        process.waitUntilExit()

        let outputData = try output.fileHandleForReading.readToEnd()
        let stdout = String(data: try #require(outputData), encoding: .utf8)
        #expect(process.terminationStatus == 0)
        #expect(stdout == "--mode|review now|Prompt's text\n")
    }

    @Test func localInvocationRemainsEnvBased() throws {
        let invocation = try AgentRunner.processInvocation(
            agent: agent(id: "claude", binary: "claude", args: ["-p"]),
            input: "diff",
            prompt: "prompt",
            target: .local,
            workingDirectory: "/tmp/repo",
            environment: ["PATH": "/test/bin"]
        )

        #expect(invocation.executable == "/usr/bin/env")
        #expect(invocation.arguments.first == "claude")
        #expect(invocation.currentDirectory == "/tmp/repo")
        #expect(invocation.environment["PATH"]?.contains("/test/bin") == true)
    }

    @Test func sshExecutionFeedsStdinAndParsesGeneratedMessage() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "ssh-shim", in: tmp)

        let result = try await AgentRunner.runPrompt(
            agent: agent(id: "custom", binary: "agent tool", args: ["--mode", "review now"]),
            input: "payload",
            prompt: "Prompt's text",
            target: .ssh(host: "dev@example"),
            workingDirectory: "/srv/repo with space",
            environment: ["PATH": path],
            processExecutableOverride: "\(tmp.path)/ssh-shim"
        )

        #expect(result == GeneratedMessage(
            subject: "subject from ssh-shim",
            body: "body from ssh-shim"
        ))
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("dev@example\n"))
        #expect(recorded.contains("cd '\\''/srv/repo with space'\\''"))
        #expect(recorded.contains("'\\''agent tool'\\'' '\\''--mode'\\'' '\\''review now'\\''"))
        #expect(recorded.contains("stdin=\npayload"))
    }

    @Test func sshExit255ReportsConnectionFailure() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("ssh-failure")
        try "#!/bin/sh\nprintf 'connection refused\\n' >&2\nexit 255\n".write(
            to: bin,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        await #expect(throws: AgentRunError.sshConnectionFailed(
            host: "dev@example",
            message: "connection refused"
        )) {
            _ = try await AgentRunner.runPromptRaw(
                agent: agent(id: "claude", binary: "claude", args: ["-p"]),
                input: "",
                prompt: "prompt",
                target: .ssh(host: "dev@example"),
                workingDirectory: "/srv/repo",
                processExecutableOverride: bin.path
            )
        }
    }

    @Test func sshExit127ReportsHostAwareBinaryNotFound() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("ssh-not-found")
        try "#!/bin/sh\nexit 127\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        do {
            _ = try await AgentRunner.runPromptRaw(
                agent: agent(id: "claude", binary: "claude", args: ["-p"]),
                input: "",
                prompt: "prompt",
                target: .ssh(host: "dev@example"),
                workingDirectory: "/srv/repo",
                processExecutableOverride: bin.path
            )
            Issue.record("expected throw")
        } catch let AgentRunError.binaryNotFound(agentId, displayName, host) {
            #expect(agentId == "claude")
            #expect(displayName == "claude")
            #expect(host == "dev@example")
        }
    }

    @Test func sshInvocationRequiresRemoteWorkingDirectory() {
        #expect(throws: AgentRunError.missingRemoteWorkingDirectory(host: "dev@example")) {
            _ = try AgentRunner.processInvocation(
                agent: agent(id: "claude", binary: "claude", args: ["-p"]),
                input: "",
                prompt: "prompt",
                target: .ssh(host: "dev@example"),
                workingDirectory: nil,
                environment: [:]
            )
        }
    }

    @Test func claudeArgvIsBinaryThenArgsThenPrompt() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "claude", in: tmp)
        let result = try await AgentRunner.runPrompt(
            agent: agent(id: "claude", binary: "claude", args: ["-p"]),
            input: "DIFF GOES HERE\n",
            prompt: "PROMPT",
            environment: ["PATH": path]
        )
        #expect(result.subject == "subject from claude")
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("-p\n"))
        #expect(recorded.contains("PROMPT\n"))
        #expect(recorded.contains("DIFF GOES HERE"))
    }

    @Test func codexUsesExecSubcommand() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "codex", in: tmp)
        _ = try await AgentRunner.runPrompt(
            agent: agent(id: "codex", binary: "codex", args: ["exec"]),
            input: "DIFF\n",
            prompt: "PROMPT",
            environment: ["PATH": path]
        )
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("exec\n"))
        #expect(recorded.contains("--skip-git-repo-check\n"))
        #expect(recorded.contains("-\n"))
    }

    @Test func codexReadsPromptAndContextFromStdin() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "codex", in: tmp)
        _ = try await AgentRunner.runPrompt(
            agent: agent(id: "codex", binary: "codex", args: ["exec"]),
            input: "DIFF\n",
            prompt: "PROMPT",
            environment: ["PATH": path]
        )
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("exec\n"))
        #expect(recorded.contains("--skip-git-repo-check\n"))
        #expect(recorded.contains("-\n"))
        #expect(!recorded.contains("PROMPT\nstdin="))
        #expect(recorded.contains("stdin=\nPROMPT\n\nDIFF\n"))
    }

    @Test func customCodexExecDefinitionReadsPromptAndContextFromStdin() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "codex", in: tmp)
        _ = try await AgentRunner.runPrompt(
            agent: agent(id: "custom-codex-profile", binary: "codex", args: ["exec"]),
            input: "DIFF\n",
            prompt: "PROMPT",
            environment: ["PATH": path]
        )
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("exec\n"))
        #expect(recorded.contains("--skip-git-repo-check\n"))
        #expect(recorded.contains("-\n"))
        #expect(!recorded.contains("PROMPT\nstdin="))
        #expect(recorded.contains("stdin=\nPROMPT\n\nDIFF\n"))
    }

    @Test func customCodexExecAliasDefinitionReadsPromptAndContextFromStdin() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "codex", in: tmp)
        _ = try await AgentRunner.runPrompt(
            agent: agent(id: "custom-codex-alias-profile", binary: "codex", args: ["e"]),
            input: "DIFF\n",
            prompt: "PROMPT",
            environment: ["PATH": path]
        )
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("e\n"))
        #expect(recorded.contains("--skip-git-repo-check\n"))
        #expect(recorded.contains("-\n"))
        #expect(!recorded.contains("PROMPT\nstdin="))
        #expect(recorded.contains("stdin=\nPROMPT\n\nDIFF\n"))
    }

    @Test func workingDirectorySetsCwdForChild() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cwdRecord = tmp.appendingPathComponent("cwd.record")
        let script = """
        #!/bin/sh
        pwd > "\(cwdRecord.path)"
        cat > /dev/null
        printf 'subject\\n'
        """
        let bin = tmp.appendingPathComponent("claude")
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bin.path
        )
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        _ = try await AgentRunner.runPrompt(
            agent: agent(id: "claude", binary: "claude", args: ["-p"]),
            input: "x",
            prompt: "y",
            workingDirectory: workdir.path,
            environment: ["PATH": "\(tmp.path):/usr/bin:/bin"]
        )

        let recorded = try String(contentsOf: cwdRecord, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // resolveSymlinksInPath handles /tmp → /private/tmp on macOS.
        let expected = (workdir.resolvingSymlinksInPath().path)
        let actual = URL(fileURLWithPath: recorded).resolvingSymlinksInPath().path
        #expect(actual == expected)
    }

    @Test func opencodeUsesRunSubcommand() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "opencode", in: tmp)
        _ = try await AgentRunner.runPrompt(
            agent: agent(id: "opencode", binary: "opencode", args: ["run"]),
            input: "DIFF\n",
            prompt: "PROMPT",
            environment: ["PATH": path]
        )
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("run\n"))
        #expect(recorded.contains("PROMPT\n"))
    }

    @Test func missingBinaryThrowsBinaryNotFoundWithAgentId() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = "\(tmp.path):/usr/bin:/bin"  // empty: no shims
        do {
            _ = try await AgentRunner.runPrompt(
                agent: agent(id: "ghost", binary: "no-such-binary", args: []),
                input: "x",
                prompt: "y",
                environment: ["PATH": path]
            )
            Issue.record("expected throw")
        } catch let AgentRunError.binaryNotFound(agentId, displayName, host) {
            #expect(agentId == "ghost")
            #expect(displayName == "ghost")
            #expect(host == nil)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func timeoutCompletesWhenChildIgnoresSIGTERM() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidFile = tmp.appendingPathComponent("ignore-term.pid")
        let script = """
        #!/bin/sh
        echo $$ > "\(pidFile.path)"
        trap '' TERM
        while true; do sleep 1; done
        """
        let bin = tmp.appendingPathComponent("ignore-term")
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bin.path
        )

        let start = Date()
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await AgentRunner.runPrompt(
                        agent: self.agent(id: "ignore-term", binary: "ignore-term", args: []),
                        input: "",
                        prompt: "",
                        environment: ["PATH": "\(tmp.path):/usr/bin:/bin"],
                        timeout: 0.1
                    )
                    Issue.record("expected timeout")
                } catch AgentRunError.timedOut(let seconds) {
                    #expect(seconds == 0.1)
                    return true
                } catch {
                    Issue.record("wrong error: \(error)")
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                if let pid = try? String(contentsOf: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   let processId = Int32(pid) {
                    kill(processId, SIGKILL)
                }
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(completed)
        #expect(elapsed < 5, "expected timeout to complete before test cleanup kill, took \(elapsed)s")
    }
}
