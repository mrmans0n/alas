import Foundation

enum EnvBuilder {
    private static let strippedKeys: Set<String> = [
        "TERM", "TERMINFO", "TERMINFO_DIRS",
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM",
        // zmx injects ZMX_SESSION into the shell it spawns. If Alas inherits
        // that env (because Alas itself was launched from a zmx-attached
        // terminal, or because we're building env for a sibling pane), passing
        // it through means a subsequent `zmx attach <other>` from anywhere in
        // the new shell falls into zmx's switchSesh path and re-attaches the
        // pane to a different session. See zmx#151. Note: ZMX_SESSION_PREFIX
        // is intentionally NOT stripped — it's a user-facing zmx config knob
        // (prefixes session names for all commands), and as long as both
        // spawned shells and Alas's own zmx CLI invocations see the same
        // prefix, name resolution stays consistent.
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
