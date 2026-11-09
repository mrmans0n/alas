import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct ACPSetupChecker: Sendable {
    public let env: [String: String]
    public let additionalPathDirectories: [String]

    public init(
        env: [String: String],
        additionalPathDirectories: [String] = AgentPath.wellKnownDirectories
    ) {
        self.env = env
        self.additionalPathDirectories = additionalPathDirectories
    }

    public func evaluate(_ check: ACPSetupCheck) async -> ACPSetupResult {
        switch check {
        case .binaryOnPath(let name):
            return resolve(name) != nil
                ? .ready
                : .missing(reason: "`\(name)` not found on PATH")
        case .npxPackage(let pkg):
            return await npmPackageState(pkg).result(
                packageName: pkg, absentReason: "npm package `\(pkg)` is not installed globally")
        case .binaryOnPathOrNpmPackage(let bin, let pkg):
            if resolve(bin) != nil { return .ready }
            return await npmPackageState(pkg).result(
                packageName: pkg, absentReason: "`\(bin)` not on PATH and `\(pkg)` not installed")
        }
    }

    /// The version of a globally installed npm package, or nil when npm or
    /// the package is missing.
    public func installedVersion(ofNpmPackage name: String) async -> String? {
        guard let directory = await globalPackageDirectory(name),
              let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
              let manifest = try? JSONDecoder().decode(NpmPackageVersion.self, from: data)
        else { return nil }
        return manifest.version
    }

    private enum NpmPackageState {
        case installed
        case absent
        /// Installed and linked, but npm skipped these platform packages.
        case incomplete(missing: [String])

        /// An incomplete install is an error rather than a missing adapter:
        /// it needs a reinstall, which the setup-error surfaces offer.
        func result(packageName: String, absentReason: String) -> ACPSetupResult {
            switch self {
            case .installed: .ready
            case .absent: .missing(reason: absentReason)
            case .incomplete(let missing):
                .error(message: ACPAdapterPayloadCheck.incompleteReason(packageName: packageName, missing: missing))
            }
        }
    }

    private func resolve(_ name: String) -> String? {
        AgentPath.resolveExecutable(named: name, base: env["PATH"], wellKnown: additionalPathDirectories)
    }

    private var npmEnvironment: [String: String] {
        ACPProcessEnvironment.augmented(env, additionalPathDirectories: additionalPathDirectories)
    }

    /// `npm root -g`'s directory for `name`, when it exists.
    private func globalPackageDirectory(_ name: String) async -> URL? {
        guard let npm = resolve("npm"),
              let result = try? await Process.run(npm, args: ["root", "-g"], env: npmEnvironment)
        else { return nil }
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        let packageDirectory = URL(fileURLWithPath: root).appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageDirectory.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return packageDirectory
    }

    private func npmPackageState(_ name: String) async -> NpmPackageState {
        guard let npm = resolve("npm"), let packageDirectory = await globalPackageDirectory(name) else {
            return .absent
        }
        let env = npmEnvironment
        let descriptors = [
            ACPManagedAdapterDescriptor.claude,
            ACPManagedAdapterDescriptor.codex,
            ACPManagedAdapterDescriptor.pi,
        ]
        guard let descriptor = descriptors.first(where: { $0.packageName == name }) else {
            return .installed
        }
        guard let data = try? Data(contentsOf: packageDirectory.appendingPathComponent("package.json")),
              let manifest = try? JSONDecoder().decode(NpmPackageManifest.self, from: data),
              let relativePath = manifest.path(for: descriptor.binaryName) else { return .absent }
        let executable = packageDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard executable.path.hasPrefix(packageDirectory.standardizedFileURL.path + "/") else { return .absent }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .absent }
        guard let prefixResult = try? await Process.run(
            npm,
            args: ["prefix", "-g"],
            env: env
        ) else { return .absent }
        let prefix = prefixResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return .absent }
        let globalBinary = URL(fileURLWithPath: prefix, isDirectory: true)
            .appendingPathComponent("bin/\(descriptor.binaryName)").path
        guard ACPLaunchPathResolver.isPackageOwnedExecutable(
            atPath: globalBinary,
            packageDirectory: packageDirectory.path
        ) else { return .absent }
        // Without Node the adapter cannot run either; its launch reports that.
        guard let node = resolve("node") else { return .installed }
        let missing = await ACPAdapterPayloadCheck.missingPackages(
            packageDirectory: packageDirectory.path, node: node, env: env)
        return missing.isEmpty ? .installed : .incomplete(missing: missing)
    }
}

private struct NpmPackageVersion: Decodable {
    let version: String
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

    public init(bin: Bin) {
        self.bin = bin
    }
}
