import Foundation

/// Pure helper that resolves the effective startup script for a project by
/// combining the global `AppConfig.Terminal` setting with the project's own
/// `startupScripts`.
enum StartupScriptResolver {
    /// Compute the effective "session open" script for a terminal pane.
    static func sessionOpenScript(
        global: AppConfig.Terminal,
        project: ProjectConfig
    ) -> String {
        resolve(globalScript: global.startupScript, projectConfig: project.startupScripts.sessionOpenMode, projectScript: project.startupScripts.sessionOpenScript)
    }

    /// Compute the effective "worktree create" script for a newly-created worktree.
    static func worktreeCreateScript(
        global: AppConfig.Terminal,
        project: ProjectConfig
    ) -> String {
        resolve(globalScript: global.worktreeCreateScript, projectConfig: project.startupScripts.worktreeCreateMode, projectScript: project.startupScripts.worktreeCreateScript)
    }

    private static func resolve(globalScript: String, projectConfig: ProjectStartupScriptMode, projectScript: String) -> String {
        let global = globalScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = projectScript.trimmingCharacters(in: .whitespacesAndNewlines)

        switch projectConfig {
        case .useGlobal:
            return global
        case .appendToGlobal:
            if global.isEmpty {
                return local
            }
            if local.isEmpty {
                return global
            }
            return global + "\n" + local
        case .overrideGlobal:
            return local
        case .disabled:
            return ""
        }
    }
}
