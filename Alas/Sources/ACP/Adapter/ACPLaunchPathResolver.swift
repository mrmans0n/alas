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
        // Scope: only adapters Alas installs via npm have a package to anchor
        // a verified path to. Binary-only adapters keep launching via PATH.
        guard spec.npmPackageName != nil else { return nil }

        // Prefer the binary owned by the verified npm global package — this is
        // what beats a PATH shadow.
        if let binDir = await npmGlobalBinDirectory() {
            let candidate = "\(binDir)/\(spec.command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }

        // Fall back to the PATH-resolved absolute path (graceful — never worse
        // than today). nil only when nothing resolves.
        return AgentPath.resolveExecutable(
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
