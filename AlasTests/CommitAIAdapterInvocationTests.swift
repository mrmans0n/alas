import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct CommitAIAdapterInvocationTests {
    /// Install a shim binary that records argv and stdin to disk, then
    /// prints a canned commit message. Returns the recorder file URL +
    /// a sandboxed PATH that starts with this dir.
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
        let path = "\(tmp.path):/usr/bin:/bin"
        return (recordFile, path)
    }

    private func withPath<T>(_ value: String, body: () async throws -> T) async throws -> T {
        let prev = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", value, 1)
        defer { setenv("PATH", prev, 1) }
        return try await body()
    }

    private func makeTmp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-adp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func claudeAdapterPassesPromptAsArgvAndDiffOnStdin() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "claude", in: tmp)

        let result = try await withPath(path) {
            try await ClaudeAdapter().generate(input: "DIFF GOES HERE\n", prompt: "PROMPT")
        }
        #expect(result.subject == "subject from claude")
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("-p\n"))
        #expect(recorded.contains("PROMPT\n"))
        #expect(recorded.contains("DIFF GOES HERE"))
    }

    @Test func codexAdapterUsesExecSubcommand() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "codex", in: tmp)

        _ = try await withPath(path) {
            try await CodexAdapter().generate(input: "DIFF\n", prompt: "PROMPT")
        }
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("exec\n"))
        #expect(recorded.contains("PROMPT\n"))
    }

    @Test func cursorAgentAdapterUsesPFlag() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "cursor-agent", in: tmp)
        _ = try await withPath(path) {
            try await CursorAgentAdapter().generate(input: "DIFF\n", prompt: "PROMPT")
        }
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("-p\n"))
        #expect(recorded.contains("PROMPT\n"))
    }

    @Test func piAdapterUsesPFlag() async throws {
        let tmp = try makeTmp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (record, path) = try shim(named: "pi", in: tmp)
        _ = try await withPath(path) {
            try await PiAdapter().generate(input: "DIFF\n", prompt: "PROMPT")
        }
        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded.contains("-p\n"))
        #expect(recorded.contains("PROMPT\n"))
    }
}
