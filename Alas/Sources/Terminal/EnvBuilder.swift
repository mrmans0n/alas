import Foundation

enum EnvBuilder {
    private static let strippedKeys: Set<String> = [
        "TERM", "TERMINFO", "TERMINFO_DIRS",
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM",
        // Do not copy an inherited zmx session identity. ZMX_SESSION_PREFIX
        // remains inherited user configuration.
        "ZMX_SESSION",
    ]

    static func build(
        project: ProjectConfig,
        worktree: Worktree,
        sessionId: String,
        socketPath: String?,
        inheritParent: Bool,
        parent: [String: String] = ProcessInfo.processInfo.environment,
        zmxDir: String? = nil
    ) -> [String: String] {
        var env: [String: String] = inheritParent
            ? parent.filter { !strippedKeys.contains($0.key) }
            : [:]
        if project.host == nil {
            // Local Ghostty starts from the Alas process environment and overlays
            // these values, so omission cannot remove a ZMX_SESSION inherited by
            // an Alas instance launched from a persistent terminal. An empty value
            // makes zmx take its normal attach path instead of switchSesh.
            env["ZMX_SESSION"] = ""
        }
        env["ALAS_REPO"] = project.name
        env["ALAS_BRANCH"] = worktree.branch
        env["ALAS_WORKTREE"] = worktree.path.path
        env["ALAS_SESSION_ID"] = sessionId
        // Always strip any inherited ALAS_SOCKET_PATH before deciding what to
        // set: leaving a parent Alas's socket path in env when we have no
        // server of our own would point this session's hooks at the wrong
        // process and drive incorrect harness state there.
        env.removeValue(forKey: "ALAS_SOCKET_PATH")
        if let socketPath { env["ALAS_SOCKET_PATH"] = socketPath }
        // Pin the daemon/socket dir so spawned shells and any subsequent
        // `zmx kill` from Alas talk to the same daemon instance.
        if let zmxDir { env["ZMX_DIR"] = zmxDir }
        return env
    }
}
