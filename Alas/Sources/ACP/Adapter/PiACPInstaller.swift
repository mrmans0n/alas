import Foundation

struct PiACPInstaller: ACPAdapterInstaller {
    let agentID = ACPManagedAdapterDescriptor.pi.agentID
    let runner: (_ command: String, _ args: [String]) async throws -> (status: Int32, stderr: String)

    init(runner: @escaping (String, [String]) async throws -> (status: Int32, stderr: String) = ClaudeCodeACPInstaller.defaultRunner) {
        self.runner = runner
    }

    func installState() async -> ACPSetupResult {
        await ACPSetupChecker(env: ProcessInfo.processInfo.environment)
            .evaluate(.binaryOnPathOrNpmPackage(
                binary: ACPManagedAdapterDescriptor.pi.binaryName,
                npmPackage: ACPManagedAdapterDescriptor.pi.packageName))
    }

    func install() async throws {
        let (status, stderr) = try await runner(
            "npm", ["install", "-g", ACPManagedAdapterDescriptor.pi.packageName])
        if status != 0 { throw ACPInstallError.nonZeroExit(status, stderr: stderr) }
    }
}
