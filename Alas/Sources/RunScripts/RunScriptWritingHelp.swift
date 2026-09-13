import Foundation

enum RunScriptWritingHelp {
    static func scope(for url: URL, worktreeRoot: URL, globalDir: URL = Paths.runScriptsGlobalDir) -> RunScriptScope? {
        let directory = url.standardizedFileURL.deletingLastPathComponent().path
        if directory == RunScriptStore.repoScriptsDir(worktreeRoot: worktreeRoot).standardizedFileURL.path {
            return .repo
        }
        if directory == globalDir.standardizedFileURL.path { return .global }
        return nil
    }

    static func prompt(scope: RunScriptScope, scriptURL: URL, worktreeRoot: URL, request: String) -> String {
        let scopeInstructions = scope == .repo
            ? "This is a repository script. Inspect this repository's instructions and build tools to implement the request."
            : "This is a global script, available in every local worktree. Make it portable across repositories, check prerequisites, and do not hardcode paths or assumptions from the current repository."
        return """
        Help me write this Alas run script for the Cmd+R palette.

        Script path: \(scriptURL.path)
        Current worktree: \(worktreeRoot.path)
        Scope: \(scope.rawValue)
        \(scopeInstructions)

        Read the existing script first and preserve my work and metadata unless the request requires changing them. Edit this file in place.
        Scripts run from the selected worktree root by default. Keep a valid shebang and executable permissions.
        Alas reads these optional comment headers within the first 20 lines:
        # alas-name: Display name
        # alas-on-exit: keep
        Use keep to retain the terminal pane after exit, or close to close it.
        # alas-cwd: relative/path
        The working directory is relative to the selected worktree root.
        # alas-url: http://localhost:3000
        Add a service URL only when the script starts a service with a known endpoint.

        Check syntax without running the script. Open the finished script for review and explain how to run it with Cmd+R. Do not run it automatically.

        My request:
        \(request.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}

enum RunScriptWritingHelpError: LocalizedError, Equatable {
    case noDefaultAgent
    case unsupportedAgent
    case remoteWorktree
    case emptyRequest
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .noDefaultAgent:
            "Choose a default agent in Settings > Agents to use writing help."
        case .unsupportedAgent:
            "The default agent must be enabled, installed, and support chat sessions. Check Settings > Agents."
        case .remoteWorktree:
            "Script writing help is available in local worktrees."
        case .emptyRequest:
            "Describe what you want the script to do."
        case .sessionUnavailable:
            "Could not open a writing-help chat. Your script is still available in the editor."
        }
    }
}
