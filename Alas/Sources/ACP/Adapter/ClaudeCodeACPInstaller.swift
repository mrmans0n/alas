import Foundation

struct ClaudeCodeACPInstaller: ACPAdapterInstaller {
    let agentID = "claude"
    let runner: (_ command: String, _ args: [String]) async throws -> (status: Int32, stderr: String)

    init(runner: @escaping (String, [String]) async throws -> (status: Int32, stderr: String) = ClaudeCodeACPInstaller.defaultRunner) {
        self.runner = runner
    }

    func installState() async -> ACPSetupResult {
        await ACPSetupChecker(env: ProcessInfo.processInfo.environment)
            .evaluate(.binaryOnPathOrNpmPackage(
                binary: "claude-agent-acp",
                npmPackage: "@agentclientprotocol/claude-agent-acp"))
    }

    func install() async throws {
        let (status, stderr) = try await runner("npm", ["install", "-g", "@agentclientprotocol/claude-agent-acp"])
        if status != 0 { throw ACPInstallError.nonZeroExit(status, stderr: stderr) }
    }

    static let defaultRunner: (String, [String]) async throws -> (status: Int32, stderr: String) = { cmd, args in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [cmd] + args
        proc.environment = ACPProcessEnvironment.augmented()
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = (try? err.fileHandleForReading.readToEnd()) ?? Data()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
