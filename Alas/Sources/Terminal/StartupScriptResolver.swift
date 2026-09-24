import Foundation

/// Pure helper that resolves a startup script from global, repo, and
/// per-user project configuration.
enum StartupScriptResolver {
    /// Compute the effective "session open" script for a terminal pane.
    static func sessionOpenScript(
        global: AppConfig.Terminal,
        repoScript: String?,
        project: ProjectConfig
    ) -> String {
        resolve(
            globalScript: global.startupScript,
            repoScript: repoScript,
            projectConfig: project.startupScripts.sessionOpenMode,
            projectScript: project.startupScripts.sessionOpenScript
        )
    }

    /// Compute the effective "worktree create" script for a newly-created worktree.
    static func worktreeCreateScript(
        global: AppConfig.Terminal,
        repoScript: String?,
        project: ProjectConfig
    ) -> String {
        resolve(
            globalScript: global.worktreeCreateScript,
            repoScript: repoScript,
            projectConfig: project.startupScripts.worktreeCreateMode,
            projectScript: project.startupScripts.worktreeCreateScript
        )
    }

    private static func resolve(
        globalScript: String,
        repoScript: String?,
        projectConfig: ProjectStartupScriptMode,
        projectScript: String
    ) -> String {
        let inherited = joined(globalScript, repoScript ?? "")
        let local = projectScript.trimmingCharacters(in: .whitespacesAndNewlines)

        switch projectConfig {
        case .useGlobal:
            return inherited
        case .appendToGlobal:
            return joined(inherited, local)
        case .overrideGlobal:
            return local
        case .disabled:
            return ""
        }
    }

    private static func joined(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)

        return switch (first.isEmpty, second.isEmpty) {
        case (true, true): ""
        case (true, false): second
        case (false, true): first
        case (false, false): first + "\n" + second
        }
    }
}
