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
    /// This runs on sidebar render paths and staging a repo icon reads and
    /// hashes the image, so the icon is looked up first against a stats-only
    /// probe of the file that supplies it: a hit returns without reading
    /// anything, and the resolve below runs only on a miss.
    func effectiveIcon(for project: ProjectConfig) -> ProjectIcon {
        guard project.host == nil else { return project.icon }
        let checkout = URL(fileURLWithPath: project.path, isDirectory: true)
        let repoConfig = repoConfig(worktreeRoot: checkout)
        let appIcon = project.icon

        guard let identity = RepoIconResolver.sourceIdentity(
            repoConfig: repoConfig,
            appIcon: appIcon,
            primaryCheckout: checkout,
            store: repoConfigStore
        ) else {
            // No usable repo file: resolving costs the same stats and reads
            // nothing, so there is nothing to cache either.
            return RepoIconResolver.resolve(
                appIcon: appIcon,
                projectID: project.id,
                repoConfig: repoConfig,
                primaryCheckout: checkout,
                store: repoConfigStore,
                stagingRoot: repoIconStagingRoot
            ).icon
        }

        let key = RepoIconDisplayCache.Key(identity: identity, appIcon: appIcon)
        if let cached = repoIconDisplayCache.icon(for: key, projectID: project.id) {
            return cached
        }

        let resolution = RepoIconResolver.resolve(
            appIcon: appIcon,
            projectID: project.id,
            repoConfig: repoConfig,
            primaryCheckout: checkout,
            store: repoConfigStore,
            stagingRoot: repoIconStagingRoot
        )
        repoIconDisplayCache.store(resolution, appIcon: appIcon, projectID: project.id)
        // When the probe named a file resolve had to skip, the stored identity
        // is a different one. Remember the outcome under the probed identity as
        // well, so the next render is a hit instead of re-reading that file.
        if let resolvedIdentity = resolution.sourceIdentity,
           RepoIconDisplayCache.Key(identity: resolvedIdentity, appIcon: appIcon) != key {
            repoIconDisplayCache.store(resolution.icon, for: key, projectID: project.id)
        }
        return resolution.icon
    }
}
