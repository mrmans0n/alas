import Foundation

enum EnvBuilder {
    /// Variables stripped from the inherited parent env before they reach the new
    /// shell. Ghostty's PTY layer sets these itself (TERM=xterm-ghostty etc.); if
    /// we also pass them through Ghostty's `config.env`, they get applied as
    /// `env_override` AFTER Ghostty's injection and clobber it. Most commonly
    /// Alas inheriting `TERM=dumb` from a non-TTY parent (Finder/launchd via
    /// some IDEs, or being run from a `dumb` shell) — strip aggressively.
    private static let strippedKeys: Set<String> = [
        "TERM",
        "TERMINFO",
        "TERMINFO_DIRS",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "COLORTERM",
    ]

    static func build(
        project: ProjectConfig,
        worktree: Worktree,
        sessionId: String,
        hookDir: URL,
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
        env["ALAS_HOOK_DIR"] = hookDir.path
        return env
    }
}
