import Foundation

/// All inputs `RepoSelectorModel` needs from the rest of the app, isolated
/// for testing. Closures capture `AppState` in production wiring.
@MainActor
struct RepoSelectorEnvironment {
    /// Configured projects in global sidebar order (`AppState.projects`).
    var projects: () -> [ProjectConfig]
    /// Visible worktrees for a given project, in global sidebar order
    /// (`ProjectsManager.visibleWorktrees(projectId:)`).
    var visibleWorktrees: (String) -> [Worktree]
    /// Read the current recents value (from `AppConfig`).
    var readRecents: () -> RepoSelectorRecents
    /// Write a mutated recents value back to `AppConfig` and persist.
    var writeRecents: (RepoSelectorRecents) -> Void
    /// Focus a worktree globally; may switch the active space before selecting.
    var focusWorktree: (_ worktreeId: String, _ projectId: String) -> Void
    /// Open `NewProjectDialog` (post `.alasCreateProject`).
    var openNewProject: () -> Void
    /// Open `NewWorktreeDialog` for the given project.
    var openNewWorktree: (_ projectId: String) -> Void
    /// The worktree currently focused in the app (`AppState.selectedWorktreeId`).
    /// Used to mark the "current" worktree in the list.
    var currentWorktreeId: () -> String?
}
