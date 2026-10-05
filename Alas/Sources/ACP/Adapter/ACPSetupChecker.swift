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
        let packageDirectory = URL(fileURLWithPath: root).appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageDirectory.path, isDirectory: &isDir),
              isDir.boolValue else { return false }

        let descriptors = [
            ACPManagedAdapterDescriptor.claude,
            ACPManagedAdapterDescriptor.codex,
            ACPManagedAdapterDescriptor.pi,
        ]
        guard let descriptor = descriptors.first(where: { $0.packageName == name }) else {
            return true
        }
        guard let data = try? Data(contentsOf: packageDirectory.appendingPathComponent("package.json")),
              let manifest = try? JSONDecoder().decode(NpmPackageManifest.self, from: data),
              let relativePath = manifest.path(for: descriptor.binaryName) else { return false }
        let executable = packageDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard executable.path.hasPrefix(packageDirectory.standardizedFileURL.path + "/") else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }
}

private struct NpmPackageManifest: Decodable {
    let bin: Bin

    enum Bin: Decodable {
        case path(String)
        case paths([String: String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let path = try? container.decode(String.self) {
                self = .path(path)
            } else {
                self = .paths(try container.decode([String: String].self))
            }
        }
    }

    func path(for binary: String) -> String? {
        switch bin {
        case .path(let path): path
        case .paths(let paths): paths[binary]
        }
    }
}
