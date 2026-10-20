import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct CodexACPInstaller: ACPAdapterInstaller {
    public let agentID = ACPManagedAdapterDescriptor.codex.agentID
    public let runner: (_ command: String, _ args: [String]) async throws -> (status: Int32, stderr: String)

    public init(runner: @escaping (String, [String]) async throws -> (status: Int32, stderr: String) = ClaudeCodeACPInstaller.defaultRunner) {
        self.runner = runner
    }

    public func installState() async -> ACPSetupResult {
        await ACPSetupChecker(env: ProcessInfo.processInfo.environment)
            .evaluate(.npxPackage(name: ACPManagedAdapterDescriptor.codex.packageName))
    }

    public func install() async throws {
        // Install first so a registry or authentication failure leaves the
        // existing adapter usable. `--force` permits replacing the shared bin.
        let (status, stderr) = try await runner(
            "npm", ["install", "-g", "--force", ACPManagedAdapterDescriptor.codex.packageName])
        if status != 0 { throw ACPInstallError.nonZeroExit(status, stderr: stderr) }

        for packageName in ACPManagedAdapterDescriptor.codex.legacyPackageNames {
            _ = try? await runner("npm", ["uninstall", "-g", packageName])
        }
        let (rebuildStatus, rebuildStderr) = try await runner(
            "npm", ["rebuild", "-g", ACPManagedAdapterDescriptor.codex.packageName])
        if rebuildStatus != 0 {
            throw ACPInstallError.nonZeroExit(rebuildStatus, stderr: rebuildStderr)
        }
    }
}
