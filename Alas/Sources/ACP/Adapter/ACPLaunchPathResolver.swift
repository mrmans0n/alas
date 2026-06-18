import Foundation

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
        //    the package-owned binary (this is what beats a PATH shadow);
        //    PATH only as a graceful fallback.
        //  - `.binaryOnPathOrNpmPackage`: the check resolves the PATH binary
        //    first, so launch that same binary; the npm-global binary is the
        //    fallback for when the check passed on the package instead.
        //  - `.binaryOnPath`: no managed package to anchor to — return nil so
        //    the caller launches via PATH (`/usr/bin/env <command>`) as today.
        switch spec.setupCheck {
        case .npxPackage:
            if let owned = await npmGlobalCandidate(for: spec) { return owned }
            return pathCandidate(for: spec)
        case .binaryOnPathOrNpmPackage:
            if let onPath = pathCandidate(for: spec) { return onPath }
            return await npmGlobalCandidate(for: spec)
        case .binaryOnPath:
            return nil
        }
    }

    /// The package-owned binary at `<npm global bin>/<command>`, if executable.
    private func npmGlobalCandidate(for spec: ACPLaunchSpec) async -> String? {
        guard let binDir = await npmGlobalBinDirectory() else { return nil }
        let candidate = "\(binDir)/\(spec.command)"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
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
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: npm)
            proc.arguments = ["prefix", "-g"]
            proc.environment = ACPProcessEnvironment.augmented(
                env, additionalPathDirectories: additionalPathDirectories)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do { try proc.run() } catch { return nil }
            proc.waitUntilExit()
            guard let data = try? pipe.fileHandleForReading.readToEnd(),
                  let prefix = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !prefix.isEmpty
            else { return nil }
            return "\(prefix)/bin"
        }
    }
}
