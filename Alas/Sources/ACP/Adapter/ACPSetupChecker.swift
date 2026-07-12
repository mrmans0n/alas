import Foundation

struct ACPSetupChecker {
    let env: [String: String]
    let additionalPathDirectories: [String]

    init(
        env: [String: String],
        additionalPathDirectories: [String] = AgentPath.wellKnownDirectories
    ) {
        self.env = env
        self.additionalPathDirectories = additionalPathDirectories
    }

    func evaluate(_ check: ACPSetupCheck) async -> ACPSetupResult {
        switch check {
        case .binaryOnPath(let name):
            return resolve(name) != nil
                ? .ready
                : .missing(reason: "`\(name)` not found on PATH")
        case .npxPackage(let pkg):
            return await npmPackageInstalled(pkg)
                ? .ready
                : .missing(reason: "npm package `\(pkg)` is not installed globally")
        case .binaryOnPathOrNpmPackage(let bin, let pkg):
            if resolve(bin) != nil { return .ready }
            if await npmPackageInstalled(pkg) { return .ready }
            return .missing(reason: "`\(bin)` not on PATH and `\(pkg)` not installed")
        }
    }

    private func resolve(_ name: String) -> String? {
        AgentPath.resolveExecutable(named: name, base: env["PATH"], wellKnown: additionalPathDirectories)
    }

    private func npmPackageInstalled(_ name: String) async -> Bool {
        // `npm root -g` resolves the global node_modules path; look for the package there.
        guard let npm = resolve("npm") else { return false }
        let env = ACPProcessEnvironment.augmented(
            env,
            additionalPathDirectories: additionalPathDirectories)
        let result: ProcessResult?
        do {
            result = try await Process.run(
                npm,
                args: ["root", "-g"],
                env: env
            )
        } catch {
            return false
        }
        guard let result else { return false }
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: "\(root)/\(name)", isDirectory: &isDir) && isDir.boolValue
    }
}
