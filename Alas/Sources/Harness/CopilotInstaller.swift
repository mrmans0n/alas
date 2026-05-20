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
        try updateGitInfoExcludeIfPresent()
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
                    "sessionStart": [entry(command: attached)],
                    "sessionEnd": [entry(command: detached)],
                    "userPromptSubmitted": [entry(command: busy)],
                    "postToolUse": [entry(command: busy)],
                    "preToolUse": [entry(command: permissionCommand)],
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
        let gitInfoURL = projectRootURL
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("info", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitInfoURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return
        }

        let excludeURL = gitInfoURL.appendingPathComponent("exclude", isDirectory: false)
        let existing: String
        if FileManager.default.fileExists(atPath: excludeURL.path) {
            do {
                existing = try String(contentsOf: excludeURL, encoding: .utf8)
            } catch {
                throw CopilotInstallerError.excludeUnreadable(excludeURL.path)
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
        try updated.write(to: excludeURL, atomically: true, encoding: .utf8)
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

    private static let permissionCommand = AlasHookCommand.compositeCommand(
        events: [.permissionRequest],
        agent: .copilot,
        forwardStdinAsBody: false,
        stdoutResponse: "{}"
    )
}

enum CopilotInstallerError: Error, LocalizedError, Equatable {
    case invalidProjectRoot(String)
    case excludeUnreadable(String)
    case unmanagedHookExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectRoot(let path):
            return "Copilot hooks can only be installed in an existing project directory. Missing or invalid path: \(path)."
        case .excludeUnreadable(let path):
            return "Could not read the Git exclude file at \(path). The Copilot hook was not added to it."
        case .unmanagedHookExists(let path):
            return "An unmanaged Copilot hook already exists at \(path). Remove it before installing the Alas hook."
        }
    }
}
