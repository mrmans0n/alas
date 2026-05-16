import Foundation

struct DetectedInstaller: Equatable, Sendable {
    let kind: InstallerKind
    let executable: String   // absolute path
}

/// Probes the host's PATH (augmented with well-known directories — see
/// `CommitAIPath.wellKnownDirectories`) to discover which package managers
/// are available. The result is a snapshot; refresh by calling `detect` again
/// after a successful install.
struct InstallerHost: Equatable, Sendable {
    let detected: [InstallerKind: DetectedInstaller]

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        additionalPathDirectories: [String] = InstallerHost.defaultAdditionalPathDirectories(),
        fileManager: FileManager = .default
    ) -> InstallerHost {
        let path = effectivePath(env: environment, additional: additionalPathDirectories)
        var found: [InstallerKind: DetectedInstaller] = [:]
        for kind in InstallerKind.allCases {
            if let exec = locate(kind.executableName, on: path, fileManager: fileManager) {
                found[kind] = DetectedInstaller(kind: kind, executable: exec)
            }
        }
        return InstallerHost(detected: found)
    }

    func installer(for kind: InstallerKind) -> DetectedInstaller? {
        detected[kind]
    }

    /// Walks `recipes` in order and returns the first whose installer is
    /// detected on this host.
    func firstAvailable(in recipes: [InstallRecipe]) -> (installer: DetectedInstaller, recipe: InstallRecipe)? {
        for recipe in recipes {
            if let installer = detected[recipe.installer] {
                return (installer, recipe)
            }
        }
        return nil
    }

    /// Every recipe whose installer is detected, in the original order. Used
    /// by the install button's caret menu when there's more than one option.
    func allAvailable(in recipes: [InstallRecipe]) -> [(installer: DetectedInstaller, recipe: InstallRecipe)] {
        recipes.compactMap { recipe in
            detected[recipe.installer].map { ($0, recipe) }
        }
    }

    // MARK: - PATH helpers (mirror LanguageServerAvailability and CommitAIPath)

    private static func locate(_ name: String, on path: String, fileManager: FileManager) -> String? {
        for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func effectivePath(env: [String: String], additional: [String]) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        if let envPath = env["PATH"] {
            for dir in envPath.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
            where seen.insert(dir).inserted {
                parts.append(dir)
            }
        }
        for dir in additional where !dir.isEmpty && seen.insert(dir).inserted {
            parts.append(dir)
        }
        return parts.joined(separator: ":")
    }

    /// Same well-known set as `LanguageServerAvailability.defaultAdditionalPathDirectories`,
    /// kept aligned so a host that has brew on PATH for LSP detection also has it for
    /// installer detection.
    // Keep in sync with LanguageServerAvailability.defaultAdditionalPathDirectories — both consult the same well-known set.
    static func defaultAdditionalPathDirectories() -> [String] {
        var dirs: [String] = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.bun/bin",
            "\(NSHomeDirectory())/.volta/bin",
        ]

        dirs.append(contentsOf: pathFileEntries(at: "/etc/paths"))

        let pathsD = "/etc/paths.d"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: pathsD) {
            for entry in entries.sorted() {
                dirs.append(contentsOf: pathFileEntries(at: "\(pathsD)/\(entry)"))
            }
        }

        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func pathFileEntries(at path: String) -> [String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

extension InstallerKind {
    /// Executable name to look up on PATH for this installer.
    var executableName: String {
        switch self {
        case .brew:   return "brew"
        case .npm:    return "npm"
        case .pnpm:   return "pnpm"
        case .bun:    return "bun"
        case .cargo:  return "cargo"
        case .rustup: return "rustup"
        case .go:     return "go"
        case .pipx:   return "pipx"
        }
    }
}
