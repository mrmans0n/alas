import Foundation

struct CodexInstaller: AgentInstaller, Sendable {
    let agent = AgentKind.codex
    let hooksURL: URL
    let configURL: URL
    let runEnableHooks: @Sendable () async throws -> CommandResult

    struct CommandResult: Sendable {
        let status: Int32
        let stderr: String
    }

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        hooksURL: URL? = nil,
        configURL: URL? = nil,
        runEnableHooks: (@Sendable () async throws -> CommandResult)? = nil
    ) {
        self.hooksURL = hooksURL ?? homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
        self.configURL = configURL ?? homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        self.runEnableHooks = runEnableHooks ?? Self.defaultEnableHooks
    }

    func installState() -> InstallState {
        let canonical = canonicalCommandsByEvent()
        guard !canonical.isEmpty else { return .notInstalled }
        do {
            let json = try JSONHookSettingsFile.load(at: hooksURL)
            let hooks = json["hooks"] as? [String: Any] ?? [:]
            // Seed every canonical event so a fully missing placement
            // compares as empty (not as a missing key).
            var actual: [String: Set<String>] = Dictionary(
                uniqueKeysWithValues: canonical.keys.map { ($0, Set<String>()) }
            )
            for (event, cmds) in JSONHookSettingsFile.managedCommandsByEventFlat(in: hooks) {
                actual[event, default: []].formUnion(cmds)
            }
            if actual.values.allSatisfy(\.isEmpty) { return .notInstalled }
            // Per-event compare: a stale install with the right commands
            // under the wrong event keys would otherwise be reported as
            // installed.
            guard actual == canonical else { return .outdated }
            return hasFeaturesFlag() ? .installed : .outdated
        } catch {
            return .notInstalled
        }
    }

    func install() async throws {
        let result = try await runEnableHooks()
        if result.status == 127 { throw CodexInstallerError.codexUnavailable }
        guard result.status == 0 else {
            throw CodexInstallerError.enableHooksFailed(result.stderr)
        }
        var json = try JSONHookSettingsFile.load(at: hooksURL)
        let existing = json["hooks"] as? [String: Any] ?? [:]
        var hooks = JSONHookSettingsFile.pruneManagedFlat(from: existing)
        for (event, entries) in hooksByEvent() {
            var current = hooks[event] as? [[String: Any]] ?? []
            current.append(contentsOf: entries)
            hooks[event] = current
        }
        json["hooks"] = hooks
        try JSONHookSettingsFile.write(json, to: hooksURL)
    }

    func uninstall() throws {
        var json = try JSONHookSettingsFile.load(at: hooksURL)
        let existing = json["hooks"] as? [String: Any] ?? [:]
        let remaining = JSONHookSettingsFile.pruneManagedFlat(from: existing)
        json["hooks"] = remaining
        try JSONHookSettingsFile.write(json, to: hooksURL)
        // Only flip the features.hooks flag back off when the user has no
        // other Codex hooks left — otherwise we'd silently disable their
        // unrelated hook integrations.
        if remaining.isEmpty {
            removeFeaturesFlag()
        }
    }

    // MARK: - Codex hook map (flat format)

    private static let busy = AlasHookCommand.compositeCommand(
        events: [.busy], agent: .codex, forwardStdinAsBody: false)
    private static let idleAndNotify = AlasHookCommand.compositeCommand(
        events: [.idle], agent: .codex, forwardStdinAsBody: true)

    private func hooksByEvent() -> [String: [[String: Any]]] {
        [
            "UserPromptSubmit": [flatEntry(command: Self.busy)],
            "Stop": [flatEntry(command: Self.idleAndNotify)],
        ]
    }

    private func flatEntry(command: String, timeout: Int = 10) -> [String: Any] {
        ["command": command, "timeout": timeout]
    }

    private func canonicalCommandsByEvent() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (event, entries) in hooksByEvent() {
            result[event] = Set(entries.compactMap { $0["command"] as? String })
        }
        return result
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

enum CodexInstallerError: Error, LocalizedError {
    case codexUnavailable
    case enableHooksFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexUnavailable:
            return "Codex must be installed and available in your login shell."
        case .enableHooksFailed(let details):
            return details.isEmpty ? "Could not enable the Codex hooks feature." : "Could not enable the Codex hooks feature: \(details)"
        }
    }
}
