import Foundation

enum EnvBuilder {
    static func build(
        project: ProjectConfig,
        worktree: Worktree,
        sessionId: String,
        hookDir: URL,
        inheritParent: Bool,
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = inheritParent ? parent : [:]
        env["ALAS_REPO"] = project.name
        env["ALAS_BRANCH"] = worktree.branch
        env["ALAS_WORKTREE"] = worktree.path.path
        env["ALAS_SESSION_ID"] = sessionId
        env["ALAS_HOOK_DIR"] = hookDir.path
        return env
    }
}
