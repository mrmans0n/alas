import Foundation

enum EnvBuilder {
    private static let strippedKeys: Set<String> = [
        "TERM", "TERMINFO", "TERMINFO_DIRS",
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM",
    ]

    static func build(
        project: ProjectConfig,
        worktree: Worktree,
        sessionId: String,
        socketPath: String?,
        inheritParent: Bool,
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = inheritParent
            ? parent.filter { !strippedKeys.contains($0.key) }
            : [:]
        env["ALAS_REPO"] = project.name
        env["ALAS_BRANCH"] = worktree.branch
        env["ALAS_WORKTREE"] = worktree.path.path
        env["ALAS_SESSION_ID"] = sessionId
        if let socketPath { env["ALAS_SOCKET_PATH"] = socketPath }
        return env
    }
}
