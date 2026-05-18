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
        #expect(script.contains(#""command": "open""#))
        #expect(script.contains("os.path.abspath"))
        #expect(script.contains("/usr/bin/nc -U -w1"))
    }

    @Test func installExecutableWritesAlasCommand() throws {
        let url = try TerminalCLIInjection.installExecutable()
        var isDirectory: ObjCBool = false

        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(url.lastPathComponent == "alas")
    }

    @Test func pathValueUsesSystemFallbackWhenCurrentPathIsEmpty() {
        let value = TerminalCLIInjection.pathValue(prepending: "/tmp/alas-bin", to: nil)

        #expect(value.hasPrefix("/tmp/alas-bin:"))
        #expect(value.contains("/usr/bin"))
        #expect(value.contains("/bin"))
    }

    @Test func bashExecutableSendsOpenRequestFromLogicalPWD() async throws {
        try await assertExecutableSendsOpenRequestFromLogicalPWD(shell: "/bin/bash")
    }

    @Test func zshExecutableSendsOpenRequestFromLogicalPWD() async throws {
        try await assertExecutableSendsOpenRequestFromLogicalPWD(shell: "/bin/zsh")
    }

    private func assertExecutableSendsOpenRequestFromLogicalPWD(shell: String) async throws {
        let root = "/tmp/alas-cli-injection-\(UUID().uuidString)"
        let realDir = "\(root)/real"
        let logicalDir = "\(root)/logical"
        let nestedDir = "\(realDir)/dir with spaces"
        let socketPath = "\(root)/test.sock"
        try FileManager.default.createDirectory(atPath: nestedDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: logicalDir, withDestinationPath: realDir)
        let cliURL = try TerminalCLIInjection.installExecutable()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let server = AgentHookSocketServer(socketPath: socketPath)
        defer { server.shutdown() }

        actor Holder {
            var request: AlasCLIRequest?
            func set(_ request: AlasCLIRequest) { self.request = request }
            func current() -> AlasCLIRequest? { request }
        }
        let holder = Holder()
        server.onCLIRequest = { request in
            await holder.set(request)
            return .ok
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", #"cd "$ALAS_LOGICAL_DIR"; alas open "dir with spaces/file.txt""#]
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(cliURL.deletingLastPathComponent().path):\(env["PATH"] ?? "")"
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
        #expect(stdoutText == "")
        #expect(stderrText == "")
        #expect(request?.command == .open)
        #expect(request?.sessionId == "test-session")
        #expect(request?.paths == ["\(logicalDir)/dir with spaces/file.txt"])
    }
}
