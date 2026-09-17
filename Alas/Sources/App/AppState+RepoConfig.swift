import Foundation

extension AppState {
    /// The repo-local `.alas/config.json` for a worktree, or nil when the repo
    /// has none. A config that is present but broken also reads as nil here —
    /// `RepoConfigStore` logs that case.
    func repoConfig(worktreeRoot: URL) -> RepoConfig? {
        repoConfigStore.config(worktreeRoot: worktreeRoot)
    }

    /// The icon a project displays once its repo's `.alas/` layer is applied.
    ///
    /// An explicit app icon and every remote project keep their own icon and
    /// never touch the filesystem. Otherwise the repo's primary checkout is
    /// consulted, so the result does not depend on which worktree has focus.
    ///
    /// This runs on sidebar render paths, and staging a repo icon reads and
    /// hashes the image, so the answer is cached on the identity of the file
    /// that supplied it.
    func effectiveIcon(for project: ProjectConfig) -> ProjectIcon {
        guard project.host == nil else { return project.icon }
        let checkout = URL(fileURLWithPath: project.path, isDirectory: true)
        let resolution = RepoIconResolver.resolve(
            appIcon: project.icon,
            projectID: project.id,
            repoConfig: repoConfig(worktreeRoot: checkout),
            primaryCheckout: checkout,
            store: repoConfigStore
        )
        if let cached = repoIconDisplayCache.icon(for: resolution, projectID: project.id) {
            return cached
        }
        repoIconDisplayCache.store(resolution, projectID: project.id)
        return resolution.icon
    }
}
