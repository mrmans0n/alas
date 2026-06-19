import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct TerminalCLIInjectionTests {
    @Test func executableScriptSendsOpenRequest() {
        let script = TerminalCLIInjection.executableScript()

        #expect(script.contains("ALAS_SOCKET_PATH"))
        #expect(script.contains("ALAS_SESSION_ID"))
        #expect(script.contains(#""kind": "cli""#))
        #expect(script.contains(#""command": command"#))
        #expect(script.contains("os.path.abspath"))
        #expect(script.contains(#"/usr/bin/nc -U -w "$timeout""#))
    }

    @Test func executableScriptSendsWorktreeAndReviewRequests() {
        let script = TerminalCLIInjection.executableScript()

        #expect(script.contains(#"build_request "$ALAS_SESSION_ID" "wt" "list""#))
        #expect(script.contains(#"build_request "$ALAS_SESSION_ID" "wt" "switch" "$1""#))
        #expect(script.contains(#"build_request "$ALAS_SESSION_ID" "wt" "new" "$branch" "$base""#))
        #expect(script.contains(#"build_request "$ALAS_SESSION_ID" "wt" "delete" "$target" "$force" "$keep_branch""#))
        #expect(script.contains(#"build_request "$ALAS_SESSION_ID" "review""#))
        #expect(script.contains(#"send_request "$request" 30"#))
        #expect(script.contains(#""keep_branch""#))
    }

    @Test func aoExecutableScriptExecsAlasOpen() {
        let script = TerminalCLIInjection.aoExecutableScript()

        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains(#"exec alas open "$@""#))
    }

    @Test func installExecutablesWritesAlasAndAoCommands() throws {
        let dir = try TerminalCLIInjection.installExecutables()
        var isDirectory: ObjCBool = false

        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let alasURL = dir.appendingPathComponent("alas")
        var alasIsDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: alasURL.path, isDirectory: &alasIsDir))
        #expect(!alasIsDir.boolValue)
        #expect(FileManager.default.isExecutableFile(atPath: alasURL.path))
        #expect(try String(contentsOf: alasURL, encoding: .utf8) == TerminalCLIInjection.executableScript())

        let aoURL = dir.appendingPathComponent("ao")
        var aoIsDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: aoURL.path, isDirectory: &aoIsDir))
        #expect(!aoIsDir.boolValue)
        #expect(FileManager.default.isExecutableFile(atPath: aoURL.path))
        #expect(try String(contentsOf: aoURL, encoding: .utf8) == TerminalCLIInjection.aoExecutableScript())
    }

    @Test func installExecutablesIsIdempotent() throws {
        let dir1 = try TerminalCLIInjection.installExecutables()
        let alasBefore = try String(contentsOf: dir1.appendingPathComponent("alas"), encoding: .utf8)
        let aoBefore = try String(contentsOf: dir1.appendingPathComponent("ao"), encoding: .utf8)

        let dir2 = try TerminalCLIInjection.installExecutables()

        #expect(dir1.path == dir2.path)
        let alasAfter = try String(contentsOf: dir2.appendingPathComponent("alas"), encoding: .utf8)
        let aoAfter = try String(contentsOf: dir2.appendingPathComponent("ao"), encoding: .utf8)
        #expect(alasAfter == alasBefore)
        #expect(aoAfter == aoBefore)
    }

    @Test func pathValueUsesSystemFallbackWhenCurrentPathIsEmpty() {
        let value = TerminalCLIInjection.pathValue(prepending: "/tmp/alas-bin", to: nil)

        #expect(value.hasPrefix("/tmp/alas-bin:"))
        #expect(value.contains("/usr/bin"))
        #expect(value.contains("/bin"))
    }

    @Test func bashExecutableSendsOpenRequestFromLogicalPWD() async throws {
        try await assertExecutableRequest(
            shell: "/bin/bash",
            commandLine: #"cd "$ALAS_LOGICAL_DIR"; alas open "dir with spaces/file.txt""#
        ) { request in
            if case .open(let paths) = request.command {
                #expect(paths.count == 1)
                #expect(paths.first?.hasSuffix("/logical/dir with spaces/file.txt") == true)
            } else {
                Issue.record("expected open command")
            }
        }
    }

    @Test func zshExecutableSendsOpenRequestFromLogicalPWD() async throws {
        try await assertExecutableRequest(
            shell: "/bin/zsh",
            commandLine: #"cd "$ALAS_LOGICAL_DIR"; alas open "dir with spaces/file.txt""#
        ) { request in
            if case .open(let paths) = request.command {
                #expect(paths.count == 1)
                #expect(paths.first?.hasSuffix("/logical/dir with spaces/file.txt") == true)
            } else {
                Issue.record("expected open command")
            }
        }
    }

    @Test func bashExecutableSendsWorktreeListRequest() async throws {
        try await assertExecutableRequest(shell: "/bin/bash", commandLine: "alas wt list") { request in
            #expect(request.command == .worktree(.list))
        }
    }

    @Test func zshExecutableSendsReviewProviderRequest() async throws {
        try await assertExecutableRequest(shell: "/bin/zsh", commandLine: "alas review 123") { request in
            #expect(request.command == .review(.provider(target: "123")))
        }
    }

    @Test func executablePrintsResponseLines() async throws {
        try await assertExecutableRequest(
            shell: "/bin/bash",
            commandLine: "alas wt list",
            response: .text(["* main    /tmp/repo", "  feature /tmp/repo-feature"]),
            expectedStdout: "* main    /tmp/repo\n  feature /tmp/repo-feature\n"
        ) { request in
            #expect(request.command == .worktree(.list))
        }
    }

    private func assertExecutableRequest(
        shell: String,
        commandLine: String,
        response: AlasCLIResponse = .ok,
        expectedStdout: String = "",
        expectedStderr: String = "",
        verify: @escaping (AlasCLIRequest) -> Void
    ) async throws {
        let root = "/tmp/alas-cli-injection-\(UUID().uuidString)"
        let realDir = "\(root)/real"
        let logicalDir = "\(root)/logical"
        let nestedDir = "\(realDir)/dir with spaces"
        let socketPath = "\(root)/test.sock"
        try FileManager.default.createDirectory(atPath: nestedDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: logicalDir, withDestinationPath: realDir)
        let binDir = try TerminalCLIInjection.installExecutables()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let server = AgentHookSocketServer(socketPath: socketPath)
        defer { server.shutdown() }

        actor Holder {
            var request: AlasCLIRequest?
            func set(_ request: AlasCLIRequest) { self.request = request }
            func current() -> AlasCLIRequest? { request }
        }
        let holder = Holder()
        let response = response
        server.onCLIRequest = { request in
            await holder.set(request)
            return response
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", commandLine]
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(binDir.path):\(env["PATH"] ?? "")"
        env["ALAS_SOCKET_PATH"] = socketPath
        env["ALAS_SESSION_ID"] = "test-session"
        env["ALAS_LOGICAL_DIR"] = logicalDir
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let request = await holder.current()

        #expect(process.terminationStatus == 0)
        #expect(stdoutText == expectedStdout)
        #expect(stderrText == expectedStderr)
        if let request {
            verify(request)
        } else {
            Issue.record("expected CLI request")
        }
        #expect(request?.sessionId == "test-session")
    }
}
