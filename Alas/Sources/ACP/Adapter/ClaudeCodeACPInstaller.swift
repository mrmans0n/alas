import Foundation

struct ClaudeCodeACPInstaller: ACPAdapterInstaller {
    let agentID = ACPManagedAdapterDescriptor.claude.agentID
    let runner: (_ command: String, _ args: [String]) async throws -> (status: Int32, stderr: String)

    init(runner: @escaping (String, [String]) async throws -> (status: Int32, stderr: String) = ClaudeCodeACPInstaller.defaultRunner) {
        self.runner = runner
    }

    func installState() async -> ACPSetupResult {
        await ACPSetupChecker(env: ProcessInfo.processInfo.environment)
            .evaluate(.npxPackage(name: ACPManagedAdapterDescriptor.claude.packageName))
    }

    func install() async throws {
        // Fetch and install the replacement before removing the working
        // adapter. `--force` permits replacing the shared global bin link.
        let (status, stderr) = try await runner(
            "npm", ["install", "-g", "--force", ACPManagedAdapterDescriptor.claude.packageName])
        if status != 0 { throw ACPInstallError.nonZeroExit(status, stderr: stderr) }

        for packageName in ACPManagedAdapterDescriptor.claude.legacyPackageNames {
            _ = try? await runner("npm", ["uninstall", "-g", packageName])
        }
        // npm removes a shared bin link when uninstalling its former owner.
        // Rebuild restores the already-installed downstream package's link
        // without another registry fetch.
        let (rebuildStatus, rebuildStderr) = try await runner(
            "npm", ["rebuild", "-g", ACPManagedAdapterDescriptor.claude.packageName])
        if rebuildStatus != 0 {
            throw ACPInstallError.nonZeroExit(rebuildStatus, stderr: rebuildStderr)
        }
    }

    static let defaultRunner: @Sendable (String, [String]) async throws -> (status: Int32, stderr: String) = { cmd, args in
        let proc = Process()
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
