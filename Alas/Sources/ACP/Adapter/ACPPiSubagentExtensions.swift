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
        /// Installed versions whose tool list was verified: at least
        /// `lowerBound`, below `upperBound`. Any other version is reported
        /// as not verified, though its tools are still excluded.
        let verifiedVersions: (lowerBound: String, upperBound: String)
        /// Every tool the package registers that starts, waits on, or
        /// steers a subagent.
        let delegationTools: [String]

        func isVerified(_ version: String) -> Bool {
            ACPNativeDelegationControls.isVersion(version, atLeast: verifiedVersions.lowerBound)
                && !ACPNativeDelegationControls.isVersion(version, atLeast: verifiedVersions.upperBound)
        }

        static func == (lhs: Extension, rhs: Extension) -> Bool {
            lhs.packageName == rhs.packageName && lhs.gitRepository == rhs.gitRepository
                && lhs.verifiedVersions == rhs.verifiedVersions && lhs.delegationTools == rhs.delegationTools
        }
    }

    /// Bump when an entry changes.
    static let registryVersion = 1

    /// To cover a new release, capture its model request with and without
    /// the exclusion (see docs/agent-delegation.md), then widen
    /// `verifiedVersions` or add its new tools here.
    static let known: [Extension] = [
        // Verified on pi-subagents 0.68.0: excluding only `subagent` leaves
        // `bg_wait` and `subagent_supervisor` in the request.
        Extension(
            packageName: "pi-subagents",
            gitRepository: "github.com/nicobailon/pi-subagents",
            verifiedVersions: ("0.68.0", "0.69.0"),
            delegationTools: ["subagent", "bg_wait", "subagent_supervisor"]
        ),
    ]

    /// Packages Alas integrates with that register no delegation tool.
    /// `pi-mcp-adapter` bridges MCP servers, including Alas's own, into Pi.
    static let knownSafePackages: Set<String> = ["pi-mcp-adapter"]
    /// The notification hook Alas installs in the global extensions folder.
    /// Recognized only while it still carries `PiInstaller`'s managed
    /// marker; `PiInstaller` never overwrites a user's file of that name.
    static func isAlasManagedGlobalExtension(_ file: URL) -> Bool {
        guard file.lastPathComponent == "alas-notify.ts",
              let contents = try? String(contentsOf: file, encoding: .utf8)
        else { return false }
        return PiInstaller.isManaged(contents)
    }

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
        \(wrapperMarker)
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
        let path = extraEnv["PATH"] ?? ACPProcessEnvironment.augmented(inheritedEnvironment)["PATH"] ?? ""
        let existing = userPiCommand(extraEnv[piCommandKey] ?? inheritedEnvironment[piCommandKey], path: path)
        let target = existing ?? "pi"
        guard isRunnable(target, path: path) else {
            throw ACPNativeDelegationError.piCommandUnavailable(command: target, isUserCommand: existing != nil)
        }
        return [piCommandKey: wrapper.path, wrapperTargetKey: target]
    }

    /// `value` as a command of the user's own, or nil when it is empty or is
    /// an Alas wrapper (this one, a symlink to it, or another Alas
    /// profile's copy carried in through the environment). Chaining to an
    /// Alas wrapper would make it run itself forever, since every copy reads
    /// the same `ALAS_PI_ACP_PI_TARGET`. A bare name is resolved through
    /// `path` first, as the wrapper's `exec` would.
    static func userPiCommand(_ value: String?, path: String) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let file = executablePath(value, path: path) else { return value }
        return startsWithWrapperMarker(file) ? nil : value
    }

    /// Reads at most the first 4 KiB, and only from a regular file, so a
    /// large binary or a FIFO never costs more than that.
    private static func startsWithWrapperMarker(_ file: String) -> Bool {
        let resolved = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
        guard (try? FileManager.default.attributesOfItem(atPath: resolved)[.type]) as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: resolved)
        else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return String(decoding: head, as: UTF8.self).contains(wrapperMarker)
    }

    /// The line that identifies an Alas wrapper, whichever profile wrote it.
    static let wrapperMarker = "target=\"${\(wrapperTargetKey):-pi}\""

    /// Whether `command` resolves the way `exec` in the wrapper would
    /// resolve it: a path as is, a bare name through `path`. A relative path
    /// depends on the session directory, so it is left to the wrapper.
    static func isRunnable(_ command: String, path: String) -> Bool {
        if command.contains("/"), !command.hasPrefix("/") { return true }
        return executablePath(command, path: path) != nil
    }

    /// The file `exec` would run for `command`: a path as is, a bare name
    /// through `path`.
    static func executablePath(_ command: String, path: String) -> String? {
        let fileManager = FileManager.default
        if command.contains("/") { return fileManager.isExecutableFile(atPath: command) ? command : nil }
        return path.split(separator: ":").lazy
            .map { "\($0)/\(command)" }
            .first { fileManager.isExecutableFile(atPath: $0) }
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
                        case .known(let name):
                            guard let ext = known.first(where: { $0.packageName == name }) else { continue }
                            let version = packageSource(entry).flatMap { installedVersion(source: $0, base: base) }
                            if let version, ext.isVerified(version) {
                                note(name, into: &covered)
                            } else {
                                note("\(name) \(version ?? "(unreadable version)") not verified\(suffix)", into: &unrecognized)
                            }
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
                if isGlobal, isAlasManagedGlobalExtension(folder.appendingPathComponent(name)) { continue }
                guard isEnabled(folder.appendingPathComponent(name), base: base, overrides: overrides) else { continue }
                note(name + suffix, into: &unrecognized)
            }
        }
        scan(base: agentDirectory, label: nil, isGlobal: true)
        for project in projects {
            scan(base: project.root.appendingPathComponent(".pi", isDirectory: true), label: project.name, isGlobal: false)
        }
        if let customPiCommand = userPiCommand(
            customPiCommand, path: ACPProcessEnvironment.augmented()["PATH"] ?? "") {
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
        guard let trimmed = packageSource(entry) else { return .unrecognized("invalid packages entry") }
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

    /// The source string of a `packages` entry: a string, or an object's
    /// `source`.
    static func packageSource(_ entry: Any) -> String? {
        let source = (entry as? String) ?? (entry as? [String: Any])?["source"] as? String
        return source?.trimmingCharacters(in: .whitespaces)
    }

    /// The `version` in the installed package's `package.json`, where Pi
    /// 0.85.1 installs it: `<base>/npm/node_modules/<name>` for `npm:`
    /// sources and `<base>/git/<host>/<owner>/<repo>` for git sources, with
    /// `base` the agent directory or a project's `.pi`. Pi can also reuse a
    /// legacy global npm install; that one reads as unreadable, which only
    /// withholds the enforced state.
    static func installedVersion(source: String, base: URL) -> String? {
        let root: URL
        if let name = npmPackageName(source) {
            root = base.appendingPathComponent("npm/node_modules", isDirectory: true).appendingPathComponent(name)
        } else if let repository = gitRepository(source, lowercased: false) {
            root = base.appendingPathComponent("git", isDirectory: true).appendingPathComponent(repository)
        } else {
            return nil
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty
        else { return nil }
        return version
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
    /// `git@host:owner/repo` → `host/owner/repo`, lowercased unless asked
    /// for the path as written (Pi's install folder keeps its case).
    static func gitRepository(_ source: String, lowercased: Bool = true) -> String? {
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
        guard !rest.isEmpty else { return nil }
        return lowercased ? rest.lowercased() : rest
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
            let pattern = String(pattern)
            return [relative, name, absolute].contains { (candidate: String) -> Bool in
                fnmatch(pattern, candidate, FNM_PATHNAME) == 0
            }
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
