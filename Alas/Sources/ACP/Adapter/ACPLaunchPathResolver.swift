import Foundation

enum ACPLaunchPathError: LocalizedError, Equatable {
    case packageExecutableUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .packageExecutableUnavailable(let package):
            "The installed npm package `\(package)` does not provide its expected executable."
        }
    }
}

/// Resolves the absolute path Alas should launch for an ACP adapter, so the
/// binary that actually runs is the one the setup check verified — not a
/// same-named binary shadowing it earlier on PATH.
///
/// Scope: npm-backed adapters (those with `npmPackageName`). For everything
/// else, and whenever a verified absolute path can't be produced, returns nil
/// so the caller falls back to PATH-based launch (`/usr/bin/env <command>`).
struct ACPLaunchPathResolver {
    let env: [String: String]
    let additionalPathDirectories: [String]
    /// Returns the npm global bin directory (e.g. `<npm prefix -g>/bin`), or nil.
    let npmGlobalBinDirectory: () async -> String?

    func resolvedLaunchPath(for spec: ACPLaunchSpec) async -> String? {
        // Mirror the setup check's verification precedence so launch runs
        // exactly the binary that made setup pass:
        //  - `.npxPackage`: the package is the only thing verified, so prefer
        //    the package-owned binary (this is what beats a PATH shadow).
        //  - `.binaryOnPathOrNpmPackage`: the check resolves the PATH binary
        //    first, so launch that same binary; the npm-global binary is the
        //    fallback for when the check passed on the package instead.
        //  - `.binaryOnPath`: no managed package to anchor to — return nil so
        //    the caller launches via PATH (`/usr/bin/env <command>`) as today.
        switch spec.setupCheck {
        case .npxPackage(let package):
            return await npmGlobalCandidate(for: spec, ownedBy: package)
        case .binaryOnPathOrNpmPackage:
            if let onPath = pathCandidate(for: spec) { return onPath }
            return await npmGlobalCandidate(for: spec)
        case .binaryOnPath:
            return nil
        }
    }

    /// The package-owned binary at `<npm global bin>/<command>`, if executable.
    private func npmGlobalCandidate(
        for spec: ACPLaunchSpec,
        ownedBy package: String? = nil
    ) async -> String? {
        guard let binDir = await npmGlobalBinDirectory() else { return nil }
        let candidate = "\(binDir)/\(spec.command)"
        guard FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        guard let package else { return candidate }
        return Self.isPackageOwnedExecutable(atPath: candidate, package: package) ? candidate : nil
    }

    static func isPackageOwnedExecutable(atPath candidate: String, package: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: candidate) else { return false }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else {
            return false
        }
        let binDir = URL(fileURLWithPath: candidate).deletingLastPathComponent()
        let target = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination).standardizedFileURL.path
            : binDir
                .appendingPathComponent(destination)
                .standardizedFileURL.path
        return target.contains("/node_modules/\(package)/")
    }

    /// The PATH-resolved absolute path of `command`, if any.
    private func pathCandidate(for spec: ACPLaunchSpec) -> String? {
        AgentPath.resolveExecutable(
            named: spec.command, base: env["PATH"], wellKnown: additionalPathDirectories)
    }

    /// Default provider: runs `npm prefix -g` (npm located via the augmented
    /// PATH) and returns `<prefix>/bin`, or nil on any failure.
    static func defaultNpmGlobalBinDirectory(
        env: [String: String],
        additionalPathDirectories: [String] = AgentPath.wellKnownDirectories
    ) -> () async -> String? {
        return {
            guard let npm = AgentPath.resolveExecutable(
                named: "npm", base: env["PATH"], wellKnown: additionalPathDirectories) else { return nil }
            let augmentedEnv = ACPProcessEnvironment.augmented(
                env, additionalPathDirectories: additionalPathDirectories)
            guard let result = try? await Process.run(
                npm,
                args: ["prefix", "-g"],
                env: augmentedEnv
            ) else { return nil }
            let prefix = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty else { return nil }
            return "\(prefix)/bin"
        }
    }
}
