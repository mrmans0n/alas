import Foundation

/// The package manager that owns an agent CLI Alas detected on PATH but did
/// not install (e.g. `omp` as a Bun global, `pi` as an npm global, `opencode`
/// as a Homebrew formula). Derived from the binary's resolved symlink target.
enum ACPDetectedAgentOwner: Equatable, Sendable {
    /// `<root>/node_modules/<package>`; `root` is Bun's global install dir.
    case bun(package: String, root: String)
    /// `<prefix>/lib/node_modules/<package>`.
    case npm(package: String, prefix: String)
    case homebrewFormula(name: String)
    case homebrewCask(name: String)

    var managerName: String {
        switch self {
        case .bun: "Bun"
        case .npm: "npm"
        case .homebrewFormula, .homebrewCask: "Homebrew"
        }
    }

    /// Directory holding the installed package's `package.json`.
    var packageDirectory: String? {
        switch self {
        case .bun(let package, let root): "\(root)/node_modules/\(package)"
        case .npm(let package, let prefix): "\(prefix)/lib/node_modules/\(package)"
        case .homebrewFormula, .homebrewCask: nil
        }
    }

    /// Command (run through `/usr/bin/env`) that upgrades the package to its
    /// latest release in place.
    var upgradeCommand: [String] {
        switch self {
        // Bun installs into its configured global dir, which may not be the
        // one the detected binary lives in.
        case .bun(let package, let root): ["BUN_INSTALL_GLOBAL_DIR=\(root)", "bun", "add", "-g", "\(package)@latest"]
        case .npm(let package, let prefix): ["npm", "install", "-g", "--prefix", prefix, "\(package)@latest"]
        case .homebrewFormula(let name): ["brew", "upgrade", "--formula", name]
        case .homebrewCask(let name): ["brew", "upgrade", "--cask", name]
        }
    }

    /// Stable identity of the install, so cached checks and dismissals never
    /// carry over to a different installation of the same agent.
    var cacheIdentity: String {
        switch self {
        case .bun(let package, let root): "bun|\(root)|\(package)"
        case .npm(let package, let prefix): "npm|\(prefix)|\(package)"
        case .homebrewFormula(let name): "brew-formula|\(name)"
        case .homebrewCask(let name): "brew-cask|\(name)"
        }
    }

    /// Classifies a canonical (symlink-resolved) executable path. Returns nil
    /// for installs Alas cannot update (pnpm, uv, cargo, standalone scripts).
    static func classify(resolvedPath path: String) -> ACPDetectedAgentOwner? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        // Homebrew first: `/opt/homebrew/lib/node_modules/…` is npm, but
        // `Cellar`/`Caskroom` are owned by brew itself.
        if let index = components.firstIndex(of: "Cellar"), index + 1 < components.count {
            return .homebrewFormula(name: components[index + 1])
        }
        if let index = components.firstIndex(of: "Caskroom"), index + 1 < components.count {
            return .homebrewCask(name: components[index + 1])
        }

        // The outermost `node_modules` names the top-level global package;
        // deeper ones are its dependencies.
        guard let index = components.firstIndex(of: "node_modules"),
              let package = packageName(components, after: index)
        else { return nil }
        let parent = components[..<index]

        // `$BUN_INSTALL/install/global`; `BUN_INSTALL` defaults to `~/.bun`.
        if parent.suffix(2).elementsEqual(["install", "global"]) {
            return .bun(package: package, root: "/" + parent.joined(separator: "/"))
        }
        if parent.last == "lib", parent.count >= 2 {
            return .npm(package: package, prefix: "/" + parent.dropLast().joined(separator: "/"))
        }
        return nil
    }

    private static func packageName(_ components: [String], after index: Int) -> String? {
        guard index + 1 < components.count else { return nil }
        let first = components[index + 1]
        guard first.hasPrefix("@") else { return first }
        guard index + 2 < components.count else { return nil }
        return "\(first)/\(components[index + 2])"
    }
}

/// Checks and applies updates for detected agent CLIs. Local only.
struct ACPDetectedAgentUpdater: Sendable {
    typealias Runner = @Sendable (_ arguments: [String], _ cwd: String?, _ timeout: TimeInterval) async throws -> ProcessResult

    let checkTimeout: TimeInterval
    let upgradeTimeout: TimeInterval
    let runner: Runner
    let readFile: @Sendable (_ path: String) -> Data?

    init(
        checkTimeout: TimeInterval = 30,
        upgradeTimeout: TimeInterval = 10 * 60,
        runner: @escaping Runner = ACPDetectedAgentUpdater.defaultRunner,
        readFile: @escaping @Sendable (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) {
        self.checkTimeout = checkTimeout
        self.upgradeTimeout = upgradeTimeout
        self.runner = runner
        self.readFile = readFile
    }

    /// The agent CLI to check for `agentID`, or nil when Alas owns the
    /// install (managed adapters) or the agent is not a curated built-in.
    /// For pi the adapter is managed, so the CLI underneath it is checked.
    static func binaryName(agentID: String, binaryOverride: String?) -> String? {
        if agentID == ACPManagedAdapterDescriptor.pi.agentID { return "pi" }
        guard let spec = ACPLaunchCatalog.builtinSpecs.first(where: { $0.agentID == agentID }),
              case .binaryOnPath(let name) = spec.setupCheck
        else { return nil }
        if let override = binaryOverride.flatMap({
            AppState.normalizedACPBinaryOverride($0, remoteHome: nil)
        }) {
            return override
        }
        return name
    }

    static func owner(
        ofBinary name: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> ACPDetectedAgentOwner? {
        guard let path = AgentPath.resolveExecutable(named: name, base: env["PATH"]) else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return ACPDetectedAgentOwner.classify(resolvedPath: resolved)
    }

    func check(owner: ACPDetectedAgentOwner) async -> AdapterUpdateState {
        switch owner {
        case .bun(let package, let root):
            // `bun info` needs a package.json in its cwd; Bun's global root has one.
            guard let current = installedVersion(owner),
                  let result = try? await runner(["bun", "info", package, "version"], root, checkTimeout),
                  result.exitCode == 0
            else { return .unknown }
            return Self.state(current: current, latestOutput: result.stdout)
        case .npm(let package, _):
            guard let current = installedVersion(owner),
                  let result = try? await runner(["npm", "view", package, "version", "--json"], nil, checkTimeout),
                  result.exitCode == 0
            else { return .unknown }
            return Self.state(current: current, latestOutput: result.stdout)
        case .homebrewFormula(let name), .homebrewCask(let name):
            let kind = if case .homebrewCask = owner { "--cask" } else { "--formula" }
            // Skip brew's slow auto-update so the check fits its timeout.
            guard let result = try? await runner(
                ["HOMEBREW_NO_AUTO_UPDATE=1", "brew", "outdated", "--json=v2", "--greedy", kind, name],
                nil,
                checkTimeout)
            else { return .unknown }
            return Self.parseBrewOutdated(name: name, status: result.exitCode, stdout: result.stdout)
        }
    }

    func upgrade(owner: ACPDetectedAgentOwner) async throws {
        let result = try await runner(owner.upgradeCommand, nil, upgradeTimeout)
        if result.exitCode != 0 {
            throw ACPInstallError.nonZeroExit(result.exitCode, stderr: result.stderr)
        }
    }

    private func installedVersion(_ owner: ACPDetectedAgentOwner) -> String? {
        guard let directory = owner.packageDirectory,
              let data = readFile("\(directory)/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["version"] as? String
    }

    /// Compares the installed version with registry output: a bare version
    /// (`bun info`) or a JSON string (`npm view --json`).
    static func state(current: String, latestOutput: String) -> AdapterUpdateState {
        let latest = latestOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !latest.isEmpty, !latest.contains(where: \.isWhitespace) else { return .unknown }
        // Prereleases on `latest` are not offered; neither are downgrades.
        guard !latest.contains("-"), isNewer(latest, than: current) else { return .upToDate }
        return .available(current: current, latest: latest)
    }

    /// `brew outdated --json=v2` exits 1 when the named package is outdated
    /// and 0 when it is current; JSON is on stdout either way.
    static func parseBrewOutdated(name: String, status: Int32, stdout: String) -> AdapterUpdateState {
        guard status == 0 || status == 1,
              let data = stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }
        let entries = ((root["formulae"] as? [[String: Any]]) ?? []) + ((root["casks"] as? [[String: Any]]) ?? [])
        guard let entry = entries.first(where: { ($0["name"] as? String) == name }) else {
            return status == 0 ? .upToDate : .unknown
        }
        guard let current = (entry["installed_versions"] as? [String])?.last,
              let latest = entry["current_version"] as? String
        else { return .unknown }
        if entry["pinned"] as? Bool == true { return .upToDate }
        return .available(current: current, latest: latest)
    }

    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let base = { (version: String) -> [Int] in
            version.split(separator: "-", maxSplits: 1).first.map {
                $0.split(separator: ".").map { Int($0) ?? 0 }
            } ?? []
        }
        let l = base(lhs), r = base(rhs)
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        // Same base: a release outranks its own prerelease.
        return !lhs.contains("-") && rhs.contains("-")
    }

    static let defaultRunner: Runner = { arguments, cwd, timeout in
        try await Process.run(
            "/usr/bin/env",
            args: arguments,
            cwd: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            env: ACPProcessEnvironment.augmented(),
            timeout: timeout)
    }
}
