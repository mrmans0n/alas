import Foundation

struct ClaudeCodeACPInstaller: ACPAdapterInstaller {
    let agentID = ACPManagedAdapterDescriptor.claude.agentID
    let runner: (_ command: String, _ args: [String]) async throws -> (status: Int32, stderr: String)

    init(runner: @escaping (String, [String]) async throws -> (status: Int32, stderr: String) = ClaudeCodeACPInstaller.defaultRunner) {
        self.runner = runner
    }

    func installState() async -> ACPSetupResult {
        await ACPSetupChecker(env: ProcessInfo.processInfo.environment)
            .evaluate(.binaryOnPathOrNpmPackage(
                binary: ACPManagedAdapterDescriptor.claude.binaryName,
                npmPackage: ACPManagedAdapterDescriptor.claude.packageName))
    }

    func install() async throws {
        let (status, stderr) = try await runner(
            "npm", ["install", "-g", ACPManagedAdapterDescriptor.claude.packageName])
        if status != 0 { throw ACPInstallError.nonZeroExit(status, stderr: stderr) }
    }

    static let defaultRunner: (String, [String]) async throws -> (status: Int32, stderr: String) = { cmd, args in
        nonisolated(unsafe) let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [cmd] + args
        proc.environment = ACPProcessEnvironment.augmented()
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(status: Int32, stderr: String), Error>) in
                proc.terminationHandler = { p in
                    let data = (try? err.fileHandleForReading.readToEnd()) ?? Data()
                    let stderr = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: (p.terminationStatus, stderr))
                }
                do {
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            proc.terminate()
        }
    }
}
