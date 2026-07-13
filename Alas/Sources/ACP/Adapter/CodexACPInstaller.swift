import Foundation

struct CodexACPInstaller: ACPAdapterInstaller {
    let agentID = ACPManagedAdapterDescriptor.codex.agentID
    let runner: (_ command: String, _ args: [String]) async throws -> (status: Int32, stderr: String)

    init(runner: @escaping (String, [String]) async throws -> (status: Int32, stderr: String) = ClaudeCodeACPInstaller.defaultRunner) {
        self.runner = runner
    }

    func installState() async -> ACPSetupResult {
        await ACPSetupChecker(env: ProcessInfo.processInfo.environment)
            .evaluate(.npxPackage(name: ACPManagedAdapterDescriptor.codex.packageName))
    }

    func install() async throws {
        // The stale `@zed-industries/codex-acp` declares the same global
        // `codex-acp` bin; npm (v7+) refuses to clobber another package's bin
        // and fails with EEXIST. Remove the old package first — best-effort,
        // since it may not be present — then install the active fork.
        for packageName in ACPManagedAdapterDescriptor.codex.legacyPackageNames {
            _ = try? await runner("npm", ["uninstall", "-g", packageName])
        }
        let (status, stderr) = try await runner(
            "npm", ["install", "-g", ACPManagedAdapterDescriptor.codex.packageName])
        if status != 0 { throw ACPInstallError.nonZeroExit(status, stderr: stderr) }
    }
}
