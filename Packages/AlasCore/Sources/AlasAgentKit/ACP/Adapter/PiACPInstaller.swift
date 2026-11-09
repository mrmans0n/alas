import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

public struct PiACPInstaller: ACPAdapterInstaller {
    public let agentID = ACPManagedAdapterDescriptor.pi.agentID
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
            .evaluate(.binaryOnPathOrNpmPackage(
                binary: ACPManagedAdapterDescriptor.pi.binaryName,
                npmPackage: ACPManagedAdapterDescriptor.pi.packageName))
    }

    public func install() async throws {
        let (status, stderr) = try await runner(
            "npm", ["install", "-g", ACPManagedAdapterDescriptor.pi.packageName])
        if status != 0 { throw ACPInstallError.nonZeroExit(status, stderr: stderr) }
        let state = if let verify { await verify() } else { await installState() }
        try ACPInstallError.requireReady(state)
    }

    public func reinstall() async throws {
        _ = try? await runner("npm", ["uninstall", "-g", ACPManagedAdapterDescriptor.pi.packageName])
        try await install()
    }
}
