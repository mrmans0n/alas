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
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
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
        } catch let AgentRunError.binaryNotFound(agentId, displayName) {
            #expect(agentId == "ghost")
            #expect(displayName == "ghost")
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
