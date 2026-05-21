import Foundation

struct CopilotInstaller: Sendable {
    let projectRootURL: URL

    private static let managedMarker = "alas-managed-copilot-hook-v1"
    private static let excludedHookPath = ".github/hooks/alas-notify.json"

    private var hookURL: URL {
        projectRootURL
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("alas-notify.json", isDirectory: false)
    }

    init(projectRootURL: URL) {
        self.projectRootURL = projectRootURL
    }

    func install() throws {
        try validateProjectRoot()

        if FileManager.default.fileExists(atPath: hookURL.path) {
            let contents = (try? String(contentsOf: hookURL, encoding: .utf8)) ?? ""
            guard contents.contains(Self.managedMarker) else {
                throw CopilotInstallerError.unmanagedHookExists(hookURL.path)
            }
        }

        try FileManager.default.createDirectory(
            at: hookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.hookData().write(to: hookURL, options: .atomic)
        do {
            try updateGitInfoExcludeIfPresent()
        } catch {
            // Git ignore metadata is best-effort; the hook install should still succeed.
        }
    }

    private func validateProjectRoot() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectRootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CopilotInstallerError.invalidProjectRoot(projectRootURL.path)
        }
    }

    private static func hookData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "alas_marker": managedMarker,
                "hooks": [
                    "agentStop": [entry(command: idle)],
                    "permissionRequest": [entry(command: permissionCommand)],
                    "sessionStart": [entry(command: attached)],
                    "sessionEnd": [entry(command: detached)],
                    "userPromptSubmitted": [entry(command: busy)],
                    "preToolUse": [entry(command: busy)],
                    "postToolUse": [entry(command: busy)],
                    "postToolUseFailure": [entry(command: busy)],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func entry(command: String) -> [String: Any] {
        [
            "type": "command",
            "bash": command,
            "timeoutSec": 5,
        ]
    }

    private func updateGitInfoExcludeIfPresent() throws {
        guard let excludeURL = try resolveGitInfoExcludeURLIfPresent() else { return }
        let existing: String
        if FileManager.default.fileExists(atPath: excludeURL.path) {
            do {
                existing = try String(contentsOf: excludeURL, encoding: .utf8)
            } catch {
                return
            }
        } else {
            existing = ""
        }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.contains(Substring(Self.excludedHookPath)) else { return }

        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") {
            updated.append("\n")
        }
        updated.append(Self.excludedHookPath)
        updated.append("\n")
        try FileManager.default.createDirectory(
            at: excludeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try updated.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    private func resolveGitInfoExcludeURLIfPresent() throws -> URL? {
        let dotGitURL = projectRootURL.appendingPathComponent(".git", isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            let infoURL = dotGitURL.appendingPathComponent("info", isDirectory: true)
            guard FileManager.default.fileExists(atPath: infoURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return nil
            }
            return infoURL.appendingPathComponent("exclude", isDirectory: false)
        }

        let gitFile = try String(contentsOf: dotGitURL, encoding: .utf8)
        guard let firstLine = gitFile.split(separator: "\n").first else { return nil }
        let prefix = "gitdir:"
        guard firstLine.lowercased().hasPrefix(prefix) else { return nil }
        let rawGitDir = firstLine.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawGitDir.isEmpty else { return nil }

        let gitDirURL: URL
        if rawGitDir.hasPrefix("/") {
            gitDirURL = URL(fileURLWithPath: rawGitDir, isDirectory: true)
        } else {
            gitDirURL = URL(
                fileURLWithPath: (projectRootURL.path as NSString)
                    .appendingPathComponent(rawGitDir),
                isDirectory: true
            ).standardizedFileURL
        }
        guard FileManager.default.fileExists(atPath: gitDirURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }

        let commonDirURL = try resolveCommonGitDirURL(from: gitDirURL) ?? gitDirURL
        return commonDirURL
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("exclude", isDirectory: false)
    }

    private func resolveCommonGitDirURL(from gitDirURL: URL) throws -> URL? {
        let commonDirFileURL = gitDirURL.appendingPathComponent("commondir", isDirectory: false)
        guard FileManager.default.fileExists(atPath: commonDirFileURL.path) else { return nil }

        let commonDirFile = try String(contentsOf: commonDirFileURL, encoding: .utf8)
        guard let firstLine = commonDirFile.split(separator: "\n").first else { return nil }
        let rawCommonDir = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCommonDir.isEmpty else { return nil }

        if rawCommonDir.hasPrefix("/") {
            return URL(fileURLWithPath: rawCommonDir, isDirectory: true)
        }
        return URL(
            fileURLWithPath: (gitDirURL.path as NSString)
                .appendingPathComponent(rawCommonDir),
            isDirectory: true
        ).standardizedFileURL
    }

    private static let attached = AlasHookCommand.compositeCommand(
        events: [.attached],
        agent: .copilot,
        forwardStdinAsBody: false,
        stdoutResponse: "{}"
    )

    private static let detached = AlasHookCommand.compositeCommand(
        events: [.detached],
        agent: .copilot,
        forwardStdinAsBody: false,
        stdoutResponse: "{}"
    )

    private static let busy = AlasHookCommand.compositeCommand(
        events: [.busy],
        agent: .copilot,
        forwardStdinAsBody: false,
        stdoutResponse: "{}"
    )

    private static let idle = AlasHookCommand.compositeCommand(
        events: [.idle],
        agent: .copilot,
        forwardStdinAsBody: false,
        stdoutResponse: "{}"
    )

    private static let permissionCommand = AlasHookCommand.compositeCommand(
        events: [.permissionRequest],
        agent: .copilot,
        forwardStdinAsBody: false,
        stdoutResponse: "{}"
    )
}

enum CopilotInstallerError: Error, LocalizedError, Equatable {
    case invalidProjectRoot(String)
    case unmanagedHookExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectRoot(let path):
            return "Copilot hooks can only be installed in an existing project directory. Missing or invalid path: \(path)."
        case .unmanagedHookExists(let path):
            return "An unmanaged Copilot hook already exists at \(path). Remove it before installing the Alas hook."
        }
    }
}
