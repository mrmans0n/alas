import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
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

    private func withPath<T>(_ value: String, body: () async throws -> T) async throws -> T {
        let prev = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", value, 1)
        defer { setenv("PATH", prev, 1) }
        return try await body()
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
        let result = try await withPath(path) {
            try await AgentRunner.runPrompt(
                agent: agent(id: "claude", binary: "claude", args: ["-p"]),
                input: "DIFF GOES HERE\n",
                prompt: "PROMPT"
            )
        }
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
        _ = try await withPath(path) {
            try await AgentRunner.runPrompt(
                agent: agent(id: "codex", binary: "codex", args: ["exec"]),
                input: "DIFF\n",
                prompt: "PROMPT"
            )
        }
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("exec\n"))
        #expect(recorded.contains("PROMPT\n"))
    }

    @Test func opencodeUsesRunSubcommand() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "opencode", in: tmp)
        _ = try await withPath(path) {
            try await AgentRunner.runPrompt(
                agent: agent(id: "opencode", binary: "opencode", args: ["run"]),
                input: "DIFF\n",
                prompt: "PROMPT"
            )
        }
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("run\n"))
        #expect(recorded.contains("PROMPT\n"))
    }

    @Test func missingBinaryThrowsBinaryNotFoundWithAgentId() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = "\(tmp.path):/usr/bin:/bin"  // empty: no shims
        do {
            _ = try await withPath(path) {
                try await AgentRunner.runPrompt(
                    agent: agent(id: "ghost", binary: "no-such-binary", args: []),
                    input: "x",
                    prompt: "y"
                )
            }
            Issue.record("expected throw")
        } catch let AgentRunError.binaryNotFound(agentId) {
            #expect(agentId == "ghost")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}
