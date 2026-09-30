import Foundation

/// Pi subagents come from extensions, not from Pi itself. This is the
/// registry of known subagent extensions and the tools they register, the
/// launch wrapper that excludes those tools, and a read-only inventory of what
/// the user's Pi configuration installs.
///
/// `pi-acp` (verified on 0.0.34) always spawns
/// `pi --mode rpc --no-themes [--session <file>]`, with no argument
/// passthrough, and restarts `pi` that way on every `session/load`. Its only
/// lever is `PI_ACP_PI_COMMAND`, which replaces the `pi` executable. It is
/// spawned directly, without a shell and without splitting on spaces, so a
/// path under `Application Support` is safe. Alas points it at the wrapper
/// below, which runs the command `pi-acp` would have run with every original
/// argument plus `--exclude-tools`. Pi (verified on 0.85.1) filters excluded
/// names out of every tool refresh, including tools an extension registers
/// later, and ignores names no extension registered.
enum ACPPiSubagentExtensions {
    struct Extension: Equatable, Sendable {
        /// npm package name, as in `npm:<name>` in Pi `packages`.
        let packageName: String
        /// `host/owner/repo` of the package's `git:` source.
        let gitRepository: String
        /// Every tool the package registers that starts, waits on, or
        /// steers a subagent.
        let delegationTools: [String]
    }

    /// Bump when an entry changes.
    static let registryVersion = 1

    static let known: [Extension] = [
        // Verified on pi-subagents 0.68.0: excluding only `subagent` leaves
        // `bg_wait` and `subagent_supervisor` in the request.
        Extension(
            packageName: "pi-subagents",
            gitRepository: "github.com/nicobailon/pi-subagents",
            delegationTools: ["subagent", "bg_wait", "subagent_supervisor"]
        ),
    ]

    /// Packages Alas integrates with that register no delegation tool.
    /// `pi-mcp-adapter` bridges MCP servers, including Alas's own, into Pi.
    static let knownSafePackages: Set<String> = ["pi-mcp-adapter"]
    /// The notification hook Alas installs in the global extensions folder
    /// (`PiInstaller`).
    static let knownSafeGlobalExtensions: Set<String> = ["alas-notify.ts"]

    /// Every registry tool, always excluded together: an absent name is a
    /// no-op, and a package installed after detection is still covered.
    static var excludedTools: [String] { known.flatMap(\.delegationTools) }

    // MARK: - Launch wrapper

    static let piCommandKey = "PI_ACP_PI_COMMAND"
    /// The command the wrapper runs: the user's own `PI_ACP_PI_COMMAND`, or
    /// `pi`. Always set by Alas, so an inherited value is never used.
    static let wrapperTargetKey = "ALAS_PI_ACP_PI_TARGET"
    static let wrapperFileName = "pi-native-subagents-off.sh"

    /// The whole wrapper. Its content is fixed (the target comes from the
    /// environment), so every launch rewrites the same file with the same
    /// bytes and a running adapter never sees another launch's target.
    static var wrapperContents: String {
        """
        #!/bin/sh
        # Written by Alas (Pi subagent registry v\(registryVersion)) for sessions with
        # "Disable native subagents" on. pi-acp runs this in place of pi
        # (PI_ACP_PI_COMMAND). It runs the command pi-acp would have run
        # (\(wrapperTargetKey)) with every original argument, and excludes the
        # tools of known Pi subagent extensions.
        target="${\(wrapperTargetKey):-pi}"
        if ! command -v "$target" >/dev/null 2>&1; then
          echo "Alas: cannot run the Pi command \\"$target\\"." >&2
          exit 127
        fi
        exec "$target" "$@" --exclude-tools \(excludedTools.joined(separator: ","))

        """
    }

    /// The launch environment for a Pi session with the policy on. The
    /// user's `PI_ACP_PI_COMMAND` (agent environment first, then the
    /// inherited one) becomes the wrapper's target instead of being dropped.
    static func launchEnvironment(
        extraEnv: [String: String],
        inheritedEnvironment: [String: String],
        wrapper: URL
    ) throws -> [String: String] {
        let existing = (extraEnv[piCommandKey] ?? inheritedEnvironment[piCommandKey])
            .flatMap { $0.isEmpty ? nil : $0 }
        // A relaunch can carry this wrapper forward; chaining to it would loop.
        let target = existing.flatMap { $0 == wrapper.path ? nil : $0 } ?? "pi"
        let path = extraEnv["PATH"] ?? ACPProcessEnvironment.augmented(inheritedEnvironment)["PATH"] ?? ""
        guard isRunnable(target, path: path) else {
            throw ACPNativeDelegationError.piCommandUnavailable(command: target, isUserCommand: existing != nil)
        }
        return [piCommandKey: wrapper.path, wrapperTargetKey: target]
    }

    /// Whether `command` resolves the way `exec` in the wrapper would
    /// resolve it: a path as is, a bare name through `path`. A relative path
    /// depends on the session directory, so it is left to the wrapper.
    static func isRunnable(_ command: String, path: String) -> Bool {
        let fileManager = FileManager.default
        if command.hasPrefix("/") { return fileManager.isExecutableFile(atPath: command) }
        if command.contains("/") { return true }
        return path.split(separator: ":").contains { directory in
            fileManager.isExecutableFile(atPath: "\(directory)/\(command)")
        }
    }

    // MARK: - Inventory

    /// What the installed extensions mean for the setting. Read-only: Alas
    /// never changes Pi settings or extension folders.
    enum Coverage: Equatable, Sendable {
        /// No known subagent extension, and nothing Alas does not recognize.
        case nothingToDisable
        /// Every installed extension is recognized; these known subagent
        /// extensions have all their delegation tools excluded.
        case enforced(covered: [String])
        /// Some installed extension, settings file Alas could not read, or
        /// custom `PI_ACP_PI_COMMAND` is not recognized. A subagent tool it
        /// adds, or a later `--exclude-tools` it passes, keeps a tool available.
        case unrecognized(covered: [String], unrecognized: [String])

        var settingsDescription: String {
            switch self {
            case .nothingToDisable:
                return "No known Pi subagent extension is installed, so there is nothing to remove yet."
            case .enforced(let covered):
                return "Covers the installed \(Self.list(covered))."
            case .unrecognized(let covered, let unrecognized):
                let shown = unrecognized.prefix(3).joined(separator: ", ")
                let more = unrecognized.count > 3 ? ", and \(unrecognized.count - 3) more" : ""
                let coveredText = covered.isEmpty ? "" : "Covers the installed \(Self.list(covered)). "
                return coveredText + "Not enforced for extensions or commands Alas does not "
                    + "recognize (\(shown)\(more)): they can keep a subagent tool available."
            }
        }

        private static func list(_ names: [String]) -> String {
            names.joined(separator: ", ") + (names.count == 1 ? " extension" : " extensions")
        }
    }

    /// The Pi configuration directory (`PI_CODING_AGENT_DIR`, else
    /// `~/.pi/agent`), as Pi resolves it.
    static func agentDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["PI_CODING_AGENT_DIR"],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true)
    }

    /// Reads the global settings (`<agentDir>/settings.json` `packages` and
    /// `extensions`, plus `<agentDir>/extensions/`) and each project's
    /// `.pi/settings.json` and `.pi/extensions/`. Project resources count
    /// even though Pi loads them only for trusted projects, so this can
    /// over-report but never misses one. `projects` should list every local
    /// worktree a session can start in, since Pi reads the session's own
    /// `.pi` folder.
    ///
    /// A `customPiCommand` (the user's own `PI_ACP_PI_COMMAND`) is chained,
    /// not replaced, but Alas cannot see what it runs: one that appends its
    /// own `--exclude-tools` after the arguments replaces Alas's list, since
    /// Pi keeps the last one. It is reported, never counted as covered.
    static func coverage(
        agentDirectory: URL,
        projects: [(name: String, root: URL)] = [],
        customPiCommand: String? = nil
    ) -> Coverage {
        var covered: [String] = []
        var unrecognized: [String] = []
        func note(_ name: String, into list: inout [String]) {
            if !list.contains(name) { list.append(name) }
        }
        func scan(base: URL, label: String?, isGlobal: Bool) {
            let suffix = label.map { " (project \($0))" } ?? ""
            let settingsURL = base.appendingPathComponent("settings.json")
            var overrides: [String] = []
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                if let settings = readSettings(settingsURL) {
                    overrides = settings.extensions.filter(isOverride)
                    for entry in settings.packages {
                        switch classifyPackage(entry) {
                        case .known(let name): note(name, into: &covered)
                        case .safe: break
                        case .unrecognized(let name): note(name + suffix, into: &unrecognized)
                        }
                    }
                    // Plain entries add a local path; glob entries only
                    // narrow those, so ignoring them over-reports.
                    for path in settings.extensions where !isOverride(path) && !isGlob(path) {
                        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
                        guard isEnabled(url, base: base, overrides: overrides) else { continue }
                        note(url.lastPathComponent + suffix, into: &unrecognized)
                    }
                } else {
                    note("unreadable \(settingsURL.path)", into: &unrecognized)
                }
            }
            let folder = base.appendingPathComponent("extensions", isDirectory: true)
            for name in autoDiscoveredExtensions(in: folder) {
                if isGlobal, knownSafeGlobalExtensions.contains(name) { continue }
                guard isEnabled(folder.appendingPathComponent(name), base: base, overrides: overrides) else { continue }
                note(name + suffix, into: &unrecognized)
            }
        }
        scan(base: agentDirectory, label: nil, isGlobal: true)
        for project in projects {
            scan(base: project.root.appendingPathComponent(".pi", isDirectory: true), label: project.name, isGlobal: false)
        }
        if let customPiCommand, !customPiCommand.isEmpty {
            note("PI_ACP_PI_COMMAND \(customPiCommand)", into: &unrecognized)
        }
        if !unrecognized.isEmpty { return .unrecognized(covered: covered, unrecognized: unrecognized) }
        return covered.isEmpty ? .nothingToDisable : .enforced(covered: covered)
    }

    enum PackageClass: Equatable {
        case known(String)
        case safe
        case unrecognized(String)
    }

    /// Classifies one `packages` entry: a source string, or an object with a
    /// `source`. Per-package resource filters do not matter; excluding a
    /// tool the package no longer loads is harmless.
    static func classifyPackage(_ entry: Any) -> PackageClass {
        let source: String
        if let string = entry as? String {
            source = string
        } else if let object = entry as? [String: Any], let string = object["source"] as? String {
            source = string
        } else {
            return .unrecognized("invalid packages entry")
        }
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if let name = npmPackageName(trimmed) {
            if let known = known.first(where: { $0.packageName == name }) { return .known(known.packageName) }
            return knownSafePackages.contains(name) ? .safe : .unrecognized(name)
        }
        if let repository = gitRepository(trimmed) {
            if let known = known.first(where: { $0.gitRepository == repository }) { return .known(known.packageName) }
            return .unrecognized(repository)
        }
        return .unrecognized(trimmed)
    }

    /// `npm:name`, `npm:name@1.2.3`, `npm:@scope/name@^1` → the package name.
    static func npmPackageName(_ source: String) -> String? {
        guard source.hasPrefix("npm:") else { return nil }
        let spec = source.dropFirst(4)
        let searchStart = spec.hasPrefix("@") ? spec.index(after: spec.startIndex) : spec.startIndex
        let name = spec[searchStart...].firstIndex(of: "@").map { spec[..<$0] } ?? spec
        return name.isEmpty ? nil : String(name)
    }

    /// `git:host/owner/repo@ref`, `https://host/owner/repo.git`,
    /// `git@host:owner/repo` → lowercased `host/owner/repo`.
    static func gitRepository(_ source: String) -> String? {
        var rest = source
        if rest.hasPrefix("git:") {
            rest.removeFirst(4)
        } else if let scheme = ["https://", "http://", "ssh://", "git://"].first(where: { rest.hasPrefix($0) }) {
            rest.removeFirst(scheme.count)
        } else if !rest.hasPrefix("git@") {
            return nil
        }
        if rest.hasPrefix("git@") {
            rest.removeFirst(4)
            if let colon = rest.firstIndex(of: ":") { rest.replaceSubrange(colon...colon, with: "/") }
        }
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
        if let slash = rest.lastIndex(of: "/"), let at = rest[slash...].firstIndex(of: "@") {
            rest = String(rest[..<at])
        }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        while rest.hasSuffix("/") { rest.removeLast() }
        return rest.isEmpty ? nil : rest.lowercased()
    }

    private struct Settings {
        var packages: [Any]
        /// Top-level `extensions` entries: local paths, globs, and
        /// `!`/`+`/`-` overrides.
        var extensions: [String]
    }

    private static func readSettings(_ url: URL) -> Settings? {
        guard var data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let packages: [Any]
        switch object["packages"] {
        case nil, is NSNull: packages = []
        case let array as [Any]: packages = array
        default: return nil
        }
        let extensions: [String]
        switch object["extensions"] {
        case nil, is NSNull: extensions = []
        case let array as [String]:
            extensions = array
        default: return nil
        }
        return Settings(packages: packages, extensions: extensions)
    }

    private static func isOverride(_ entry: String) -> Bool {
        entry.hasPrefix("!") || entry.hasPrefix("+") || entry.hasPrefix("-")
    }

    private static func isGlob(_ entry: String) -> Bool {
        entry.contains("*") || entry.contains("?")
    }

    /// Pi's override rules (0.85.1 `isEnabledByOverrides`) for a file under
    /// `base`: `!glob` disables a match on its base-relative path, name, or
    /// absolute path; `+path` re-enables and `-path` disables an exact
    /// base-relative or absolute path, in that order. Globs use `fnmatch`
    /// with `FNM_PATHNAME`, which matches no more than Pi's minimatch, so a
    /// disabled extension may still be reported but an enabled one is never
    /// hidden.
    static func isEnabled(_ file: URL, base: URL, overrides: [String]) -> Bool {
        let absolute = file.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        let relative = absolute.hasPrefix(basePath + "/") ? String(absolute.dropFirst(basePath.count + 1)) : absolute
        let name = file.lastPathComponent
        func exact(_ pattern: Substring) -> Bool {
            let normalized = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : String(pattern)
            return normalized == relative || normalized == absolute
        }
        func glob(_ pattern: Substring) -> Bool {
            [relative, name, absolute].contains { fnmatch(String(pattern), $0, FNM_PATHNAME) == 0 }
        }
        var enabled = true
        if overrides.contains(where: { $0.hasPrefix("!") && glob($0.dropFirst()) }) { enabled = false }
        if overrides.contains(where: { $0.hasPrefix("+") && exact($0.dropFirst()) }) { enabled = true }
        if overrides.contains(where: { $0.hasPrefix("-") && exact($0.dropFirst()) }) { enabled = false }
        return enabled
    }

    /// Entries Pi auto-loads from an `extensions` folder: `.ts`/`.js` files
    /// and directories, skipping hidden entries and `node_modules`.
    private static func autoDiscoveredExtensions(in directory: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().filter { name in
            guard !name.hasPrefix("."), name != "node_modules" else { return false }
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
            return isDirectory.boolValue || name.hasSuffix(".ts") || name.hasSuffix(".js")
        }
    }
}
