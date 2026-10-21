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

    public init(runner: @escaping (String, [String]) async throws -> (status: Int32, stderr: String) = ClaudeCodeACPInstaller.defaultRunner) {
        self.runner = runner
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
    }
}
