import Foundation

/// Environment injected into locally spawned ACP adapter processes so any
/// agent's shell can drive the `alas` CLI (open files, worktrees, reviews,
/// notify) against the running app. The same tool surface the built-in MCP
/// server shims; for adapters that ignore ACP MCP config (see
/// `ACPMCPInjectionSupport.external`) this is the only path to Alas tools.
enum AlasCLIEnvInjection {
    /// The extra process env, or nil when the CLI is unavailable
    /// (feature disabled, managed binary or app socket missing).
    static func environment(
        enabled: Bool,
        binDirPath: String?,
        socketPath: String?,
        worktreePath: String,
        sessionId: String,
        parentSessionId: String?,
        basePATH: String?
    ) -> [String: String]? {
        guard enabled, let binDirPath, let socketPath else { return nil }
        var env: [String: String] = [
            "ALAS_SOCKET_PATH": socketPath,
            "ALAS_WORKTREE_DIR": worktreePath,
            "ALAS_SESSION_ID": sessionId,
            "PATH": TerminalCLIInjection.pathValue(prepending: binDirPath, to: basePATH),
        ]
        if let parentSessionId {
            env["ALAS_PARENT_SESSION_ID"] = parentSessionId
        }
        return env
    }
}
