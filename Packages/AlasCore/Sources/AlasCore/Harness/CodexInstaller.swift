import Foundation

public struct CodexInstaller: AgentInstaller, Sendable {
    public let agent = AgentKind.codex
    public let hooksURL: URL
    public let configURL: URL
    public let runEnableHooks: @Sendable () async throws -> CommandResult
    public let trustHooks: @Sendable (_ hooksURL: URL, _ commands: Set<String>) async throws -> Void

    public struct CommandResult: Sendable {
        public let status: Int32
        public let stderr: String

        public init(status: Int32, stderr: String) {
            self.status = status
            self.stderr = stderr
        }
    }

    public init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        hooksURL: URL? = nil,
        configURL: URL? = nil,
        runEnableHooks: (@Sendable () async throws -> CommandResult)? = nil,
        trustHooks: (@Sendable (_ hooksURL: URL, _ commands: Set<String>) async throws -> Void)? = nil
    ) {
        self.hooksURL = hooksURL ?? homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
        self.configURL = configURL ?? homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        // Wrapped in a closure literal rather than passed as an unapplied
        // method reference: the metatype-bound reference is a plain function
        // value and converting it to the `@Sendable` stored type is a data-race
        // warning. `defaultEnableHooks` captures nothing, so the literal is
        // trivially `@Sendable`.
        self.runEnableHooks = runEnableHooks ?? { try await CodexInstaller.defaultEnableHooks() }
        self.trustHooks = trustHooks ?? { hooksURL, commands in
            try await CodexHookTrust.trustViaAppServer(hooksURL: hooksURL, commands: commands)
        }
    }

    public func installState() -> InstallState {
        let canonical = canonicalCommandsByEvent()
        guard !canonical.isEmpty else { return .notInstalled }
        do {
            let json = try JSONHookSettingsFile.load(at: hooksURL)
            let hooks = json["hooks"] as? [String: Any] ?? [:]
            let placements = managedPlacements(in: hooks)
            // Seed every canonical event so a fully missing placement
            // compares as empty (not as a missing key).
            var actual: [String: Set<String>] = Dictionary(
                uniqueKeysWithValues: canonical.keys.map { ($0, Set<String>()) }
            )
            for placement in placements {
                actual[placement.event, default: []].insert(placement.command)
            }
            if actual.values.allSatisfy(\.isEmpty) {
                // Entries in the old flat shape mean Alas installed hooks that
                // Codex never ran; report them as needing an update.
                let legacy = JSONHookSettingsFile.managedCommandsByEventFlat(in: hooks)
                return legacy.isEmpty ? .notInstalled : .outdated
            }
            // Per-event compare: a stale install with the right commands
            // under the wrong event keys would otherwise be reported as
            // installed.
            guard actual == canonical, hasFeaturesFlag() else { return .outdated }
            return hasTrustEntries(for: placements) ? .installed : .outdated
        } catch {
            return .notInstalled
        }
    }

    public func install() async throws {
        let result = try await runEnableHooks()
        if result.status == 127 { throw CodexInstallerError.codexUnavailable }
        guard result.status == 0 else {
            throw CodexInstallerError.enableHooksFailed(result.stderr)
        }
        var json = try JSONHookSettingsFile.load(at: hooksURL)
        let existing = json["hooks"] as? [String: Any] ?? [:]
        var hooks = Self.pruneManaged(from: existing)
        for (event, entries) in hooksByEvent() {
            var current = hooks[event] as? [[String: Any]] ?? []
            current.append(contentsOf: entries)
            hooks[event] = current
        }
        json["hooks"] = hooks
        try JSONHookSettingsFile.write(json, to: hooksURL)
        try await trustHooks(hooksURL, Set(canonicalCommandsByEvent().values.joined()))
    }

    public func uninstall() throws {
        var json = try JSONHookSettingsFile.load(at: hooksURL)
        let existing = json["hooks"] as? [String: Any] ?? [:]
        let remaining = Self.pruneManaged(from: existing)
        json["hooks"] = remaining
        try JSONHookSettingsFile.write(json, to: hooksURL)
        // Only flip the features.hooks flag back off when the user has no
        // other Codex hooks left — otherwise we'd silently disable their
        // unrelated hook integrations.
        if remaining.isEmpty {
            removeFeaturesFlag()
        }
    }

    // MARK: - Codex hook map

    // Codex reads hooks.json as `event → [matcher group]`, each group holding
    // a `hooks` array of handlers. Alas used to write handlers directly under
    // the event; Codex parses those as groups with no handlers and skips them
    // without a warning.

    private static let busy = AlasHookCommand.compositeCommand(
        events: [.busy], agent: .codex, forwardStdinAsBody: false)
    private static let idleAndNotify = AlasHookCommand.compositeCommand(
        events: [.idle], agent: .codex, forwardStdinAsBody: true)
    private static let attached = AlasHookCommand.compositeCommand(
        events: [.attached], agent: .codex, forwardStdinAsBody: false)
    private static let detached = AlasHookCommand.compositeCommand(
        events: [.detached], agent: .codex, forwardStdinAsBody: false)

    private func hooksByEvent() -> [String: [[String: Any]]] {
        [
            "SessionStart": [hookGroup(command: Self.attached)],
            "SessionEnd": [hookGroup(command: Self.detached)],
            "UserPromptSubmit": [hookGroup(command: Self.busy)],
            "Stop": [hookGroup(command: Self.idleAndNotify)],
        ]
    }

    private func hookGroup(command: String, timeout: Int = 10) -> [String: Any] {
        ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
    }

    private func canonicalCommandsByEvent() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (event, groups) in hooksByEvent() {
            result[event] = Set(Self.commands(inGroups: groups).map(\.command))
        }
        return result
    }

    /// Strips Alas entries in both the grouped shape and the old flat one,
    /// so updating an existing install leaves no dead flat entries behind.
    private static func pruneManaged(from hooks: [String: Any]) -> [String: Any] {
        JSONHookSettingsFile.pruneManaged(from: JSONHookSettingsFile.pruneManagedFlat(from: hooks))
    }

    private struct Placement {
        let event: String
        let groupIndex: Int
        let handlerIndex: Int
        let command: String
    }

    private func managedPlacements(in hooks: [String: Any]) -> [Placement] {
        hooks.flatMap { event, value -> [Placement] in
            guard let groups = value as? [[String: Any]] else { return [] }
            return Self.commands(inGroups: groups)
                .filter { AlasHookCommand.isManagedCommand($0.command) }
                .map { Placement(event: event, groupIndex: $0.group, handlerIndex: $0.handler, command: $0.command) }
        }
    }

    private static func commands(inGroups groups: [[String: Any]]) -> [(group: Int, handler: Int, command: String)] {
        groups.enumerated().flatMap { groupIndex, group in
            ((group["hooks"] as? [[String: Any]]) ?? []).enumerated().compactMap { handlerIndex, handler in
                (handler["command"] as? String).map { (groupIndex, handlerIndex, $0) }
            }
        }
    }

    // MARK: - Hook trust

    /// Whether config.toml records trust for each placement's key. Keys are
    /// positional (`<hooks.json>:<event>:<group>:<handler>`), so another tool
    /// adding a hook ahead of Alas's moves it to a key nobody has trusted.
    /// The hash itself is not checked; `install()` verified it with Codex.
    private func hasTrustEntries(for placements: [Placement]) -> Bool {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        let trustedKeys = Self.trustedHookKeys(inConfig: contents)
        let hooksPath = CodexHookTrust.canonicalPath(hooksURL)
        return placements.allSatisfy { placement in
            let key = "\(hooksPath):\(Self.snakeCase(placement.event)):\(placement.groupIndex):\(placement.handlerIndex)"
            return trustedKeys.contains(key)
        }
    }

    /// Keys of `[hooks.state."…"]` tables that set `trusted_hash`.
    private static func trustedHookKeys(inConfig contents: String) -> Set<String> {
        var keys = Set<String>()
        var currentKey: String?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                currentKey = Self.hookStateKey(fromHeader: trimmed)
                continue
            }
            if let key = currentKey, trimmed.range(of: #"^trusted_hash\s*="#, options: .regularExpression) != nil {
                keys.insert(key)
            }
        }
        return keys
    }

    private static func hookStateKey(fromHeader header: String) -> String? {
        let prefix = #"[hooks.state.""#
        let suffix = #""]"#
        guard header.hasPrefix(prefix), header.hasSuffix(suffix), header.count > prefix.count + suffix.count else {
            return nil
        }
        let quoted = header.dropFirst(prefix.count).dropLast(suffix.count)
        return quoted.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: #"\"#)
    }

    /// `UserPromptSubmit` → `user_prompt_submit`, the spelling Codex uses in
    /// hook keys.
    private static func snakeCase(_ event: String) -> String {
        event.reduce(into: "") { result, char in
            if char.isUppercase, !result.isEmpty { result.append("_") }
            result.append(char.lowercased())
        }
    }

    // MARK: - Features flag

    private func hasFeaturesFlag() -> Bool {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        var inFeatures = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inFeatures = Self.isFeaturesHeader(trimmed)
                continue
            }
            if inFeatures, line.range(of: #"^\s*hooks\s*=\s*true\b"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private func removeFeaturesFlag() {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        var lines: [Substring] = []
        var inFeatures = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inFeatures = Self.isFeaturesHeader(trimmed)
                lines.append(line)
                continue
            }
            if inFeatures, line.range(of: #"^\s*hooks\s*=\s*true\b"#, options: .regularExpression) != nil {
                continue
            }
            lines.append(line)
        }
        let rewritten = lines.joined(separator: "\n")
        guard rewritten != contents else { return }
        try? rewritten.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Match exactly the top-level `[features]` table (optionally followed
    /// by a comment). The previous loose `contains("features")` check matched
    /// unrelated tables like `[profile.features]` or `[features_experimental]`
    /// and would falsely associate their settings with Codex's hooks flag.
    private static func isFeaturesHeader(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^\[\s*features\s*\](\s*#.*)?$"#, options: .regularExpression) != nil
    }

    private static func defaultEnableHooks() async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "codex features enable hooks"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let stderr = String(bytes: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return .init(status: status, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum CodexInstallerError: Error, LocalizedError, Sendable {
    case codexUnavailable
    case enableHooksFailed(String)
    case trustHooksFailed(String)

    public var errorDescription: String? {
        switch self {
        case .codexUnavailable:
            return "Codex must be installed and available in your login shell."
        case .enableHooksFailed(let details):
            return details.isEmpty ? "Could not enable the Codex hooks feature." : "Could not enable the Codex hooks feature: \(details)"
        case .trustHooksFailed(let details):
            return "Could not mark the Alas hooks as trusted in Codex: \(details)"
        }
    }
}
