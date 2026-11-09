import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

public struct CodexACPInstaller: ACPAdapterInstaller {
    public let agentID = ACPManagedAdapterDescriptor.codex.agentID
    public let runner: (_ command: String, _ args: [String]) async throws -> (status: Int32, stderr: String)
    /// Replaces the post-install setup check in tests.
    private let verify: (() async -> ACPSetupResult)?

    public init(
        runner: @escaping (String, [String]) async throws -> (status: Int32, stderr: String) = ClaudeCodeACPInstaller.defaultRunner,
        verify: (() async -> ACPSetupResult)? = nil
    ) {
        self.runner = runner
        self.verify = verify
    }

    public func installState() async -> ACPSetupResult {
        await ACPSetupChecker(env: ACPProcessEnvironment.baseEnvironment())
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
        let state = if let verify { await verify() } else { await installState() }
        try ACPInstallError.requireReady(state)
    }

    public func reinstall() async throws {
        _ = try? await runner("npm", ["uninstall", "-g", ACPManagedAdapterDescriptor.codex.packageName])
        try await install()
    }
}
