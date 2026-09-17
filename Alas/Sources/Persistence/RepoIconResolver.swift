import Foundation

/// Picks the icon a project displays once the repo-local `.alas/` layer is
/// applied under the per-user project settings. See
/// docs/plans/2026-09-17-repo-local-config-design.md.
enum RepoIconResolver {
    /// An app-level icon counts as explicit when it is anything other than the
    /// untouched creation default: a letter tile with no chosen label or glyph.
    /// A colour pick alone is cosmetic, so it never vetoes the repo's logo.
    static func iconIsExplicit(_ icon: ProjectIcon) -> Bool {
        icon.mode != .letter
            || icon.label != nil
            || icon.symbolName != nil
            || icon.emoji != nil
            || icon.imagePath != nil
    }

    /// The icon to display for a project: an explicit app icon wins, else the
    /// repo config's `icon` key, else the discovered `.alas/icon.<ext>`, else
    /// the app icon unchanged.
    ///
    /// Repo images are staged content-addressed into the icon store instead of
    /// being referenced where they lie, because `ProjectIcon.imagePath` is
    /// resolved against that store when it renders. The app icon's colour and
    /// background preference carry over, so a personal choice survives.
    ///
    /// Never throws: a missing or undecodable repo icon is invisible to the
    /// user beyond falling back to the app icon.
    static func effectiveIcon(
        appIcon: ProjectIcon,
        projectID: String,
        repoConfig: RepoConfig?,
        primaryCheckout: URL,
        store: RepoConfigStore,
        stagingRoot: URL = Paths.projectIconsRoot
    ) -> ProjectIcon {
        guard !iconIsExplicit(appIcon) else { return appIcon }

        for candidate in candidates(
            repoConfig: repoConfig,
            primaryCheckout: primaryCheckout,
            store: store
        ) {
            guard let data = try? Data(contentsOf: candidate),
                  let staged = try? ProjectIconImageStaging.stage(
                      data: data,
                      projectId: projectID,
                      root: stagingRoot
                  )
            else { continue }
            return ProjectIcon(
                mode: .image,
                color: appIcon.color,
                imagePath: staged.imagePath,
                transparentBackground: appIcon.transparentBackground
            )
        }
        return appIcon
    }

    /// The repo's own icon files, most explicit first. `RepoConfig` has already
    /// rejected absolute paths and `..` components, so the config path stays
    /// inside the checkout by construction.
    private static func candidates(
        repoConfig: RepoConfig?,
        primaryCheckout: URL,
        store: RepoConfigStore
    ) -> [URL] {
        var urls: [URL] = []
        if let image = repoConfig?.icon?.image {
            urls.append(
                primaryCheckout
                    .appendingPathComponent(".alas", isDirectory: true)
                    .appendingPathComponent(image)
            )
        }
        if let discovered = store.discoveredIconURL(worktreeRoot: primaryCheckout) {
            urls.append(discovered)
        }
        return urls
    }
}
