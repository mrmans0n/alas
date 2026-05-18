import Testing
import Foundation
@testable import Alas

struct TerminalCLIInjectionTests {
    @Test func zshAndBashReceiveAlasFunction() {
        let zsh = TerminalCLIInjection.script(forShell: "/bin/zsh") ?? ""
        let bash = TerminalCLIInjection.script(forShell: "/opt/homebrew/bin/bash") ?? ""

        for script in [zsh, bash] {
            #expect(script.contains("alas()"))
            #expect(script.contains("ALAS_SOCKET_PATH"))
            #expect(script.contains("ALAS_SESSION_ID"))
            #expect(script.contains(#""kind": "cli""#))
            #expect(script.contains(#""command": "open""#))
            #expect(script.contains("os.path.abspath"))
            #expect(script.contains("/usr/bin/nc -U -w1"))
        }
    }

    @Test func unsupportedShellReceivesNoSnippet() {
        #expect(TerminalCLIInjection.script(forShell: "/opt/homebrew/bin/fish") == nil)
    }

    @Test func composePrependsInjectionBeforeUserScriptAndSuffix() {
        let composed = TerminalCLIInjection.compose(
            shell: "/bin/zsh",
            userStartupScript: "echo user",
            startupScriptSuffix: "echo agent"
        )

        #expect(composed.contains("alas()"))
        #expect(composed.range(of: "alas()")!.lowerBound < composed.range(of: "echo user")!.lowerBound)
        #expect(composed.range(of: "echo user")!.lowerBound < composed.range(of: "echo agent")!.lowerBound)
    }

    @Test func composeKeepsUnsupportedShellUserScriptOnly() {
        let composed = TerminalCLIInjection.compose(
            shell: "/opt/homebrew/bin/fish",
            userStartupScript: "echo user",
            startupScriptSuffix: nil
        )

        #expect(composed == "echo user")
    }

    @Test func bashFunctionSendsOpenRequestFromLogicalPWD() async throws {
        let root = "/tmp/alas-cli-injection-\(UUID().uuidString)"
        let realDir = "\(root)/real"
        let logicalDir = "\(root)/logical"
        let nestedDir = "\(realDir)/dir with spaces"
        let scriptPath = "\(root)/alas-injection.sh"
        let socketPath = "\(root)/test.sock"
        try FileManager.default.createDirectory(atPath: nestedDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: logicalDir, withDestinationPath: realDir)
        try TerminalCLIInjection.script(forShell: "/bin/bash")!.write(
            toFile: scriptPath,
            atomically: true,
            encoding: .utf8
        )
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
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", #"source "$0"; cd "$ALAS_LOGICAL_DIR"; alas open "dir with spaces/file.txt""#, scriptPath]
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
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
