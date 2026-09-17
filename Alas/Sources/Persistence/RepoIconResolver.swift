import Foundation
import os

/// Picks the icon a project displays once the repo-local `.alas/` layer is
/// applied under the per-user project settings. See
/// docs/plans/2026-09-17-repo-local-config-design.md.
enum RepoIconResolver {
    /// Outcome of resolving a project icon, including which repo file supplied
    /// it, so callers can cache the result on that file's identity instead of
    /// re-deriving which candidate won.
    struct RepoIconResolution: Equatable {
        /// Icon to display: a staged image icon, or the app icon unchanged.
        let icon: ProjectIcon
        /// The repo file the icon came from, or nil when the app icon was used.
        let sourceURL: URL?
        let sourceModificationDate: Date?
        let sourceFileSize: Int?

        /// The identity of the file this resolution came from, or nil when the
        /// app icon was used and there is nothing to cache on.
        var sourceIdentity: SourceIdentity? {
            guard let sourceURL else { return nil }
            return SourceIdentity(
                url: sourceURL,
                modificationDate: sourceModificationDate,
                fileSize: sourceFileSize
            )
        }
    }

    /// The repo file that supplies an icon, with the identity stamp a caller
    /// keys its cache on. Produced from filesystem stats alone: no reads, no
    /// staging.
    struct SourceIdentity: Equatable {
        let url: URL
        let modificationDate: Date?
        let fileSize: Int?
    }

    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "repo-config")

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

    /// The icon alone, for the render path. Callers that need to cache the
    /// result must use `resolve` and key on the reported source instead.
    static func effectiveIcon(
        appIcon: ProjectIcon,
        projectID: String,
        repoConfig: RepoConfig?,
        primaryCheckout: URL,
        store: RepoConfigStore,
        stagingRoot: URL = Paths.projectIconsRoot
    ) -> ProjectIcon {
        resolve(
            appIcon: appIcon,
            projectID: projectID,
            repoConfig: repoConfig,
            primaryCheckout: primaryCheckout,
            store: store,
            stagingRoot: stagingRoot
        ).icon
    }

    /// The repo file that would currently supply the icon, with the stamp a
    /// render-time cache keys on. Stats only: no reads, no staging, no logging.
    ///
    /// Returns nil when the app icon is in effect (it is explicit) and when no
    /// usable candidate exists — the same two cases where `resolve` has nothing
    /// to read, so a caller that resolves anyway pays no more than this probe.
    static func sourceIdentity(
        repoConfig: RepoConfig?,
        appIcon: ProjectIcon,
        primaryCheckout: URL,
        store: RepoConfigStore
    ) -> SourceIdentity? {
        guard !iconIsExplicit(appIcon) else { return nil }

        for candidate in candidates(
            repoConfig: repoConfig,
            primaryCheckout: primaryCheckout,
            store: store
        ) {
            // An oversized candidate is skipped here too, so the probe and
            // `resolve` agree on which file wins instead of the caller caching
            // an identity `resolve` would refuse to use.
            guard let values = try? candidate.url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ), !isOversized(values)
            else { continue }
            return SourceIdentity(
                url: candidate.url,
                modificationDate: values.contentModificationDate,
                fileSize: values.fileSize
            )
        }
        return nil
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
    ///
    /// `stagingRoot` is a test seam: it must be `Paths.projectIconsRoot` in the
    /// app, because the renderer resolves the returned `imagePath` against that
    /// root. Any other value stages an icon the renderer cannot load.
    static func resolve(
        appIcon: ProjectIcon,
        projectID: String,
        repoConfig: RepoConfig?,
        primaryCheckout: URL,
        store: RepoConfigStore,
        stagingRoot: URL = Paths.projectIconsRoot
    ) -> RepoIconResolution {
        guard !iconIsExplicit(appIcon) else { return appIconResolution(appIcon) }

        for candidate in candidates(
            repoConfig: repoConfig,
            primaryCheckout: primaryCheckout,
            store: store
        ) {
            // One stat decides both whether the file is there and whether it is
            // worth reading: an oversized icon is refused before it is loaded,
            // so a 10+ MB file never lands in memory on the render path.
            let values = try? candidate.url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            guard !isOversized(values) else {
                logUnusableConfigIcon(candidate, exists: true)
                continue
            }
            guard let data = try? Data(contentsOf: candidate.url),
                  let staged = try? ProjectIconImageStaging.stage(
                      data: data,
                      projectId: projectID,
                      root: stagingRoot
                  )
            else {
                logUnusableConfigIcon(candidate, exists: values != nil)
                continue
            }
            return RepoIconResolution(
                icon: ProjectIcon(
                    mode: .image,
                    color: appIcon.color,
                    imagePath: staged.imagePath,
                    transparentBackground: appIcon.transparentBackground
                ),
                sourceURL: candidate.url,
                sourceModificationDate: values?.contentModificationDate,
                sourceFileSize: values?.fileSize
            )
        }
        return appIconResolution(appIcon)
    }

    /// The app icon was used, so there is no repo file to cache on.
    private static func appIconResolution(_ icon: ProjectIcon) -> RepoIconResolution {
        RepoIconResolution(
            icon: icon,
            sourceURL: nil,
            sourceModificationDate: nil,
            sourceFileSize: nil
        )
    }

    /// The repo's own icon files, most explicit first.
    private static func candidates(
        repoConfig: RepoConfig?,
        primaryCheckout: URL,
        store: RepoConfigStore
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        // Defence in depth: decoding already drops unsafe paths, but a
        // hand-built `RepoConfig` never went through it.
        if let image = repoConfig?.icon?.image,
           let safeImage = RepoConfig.sanitizedIconPath(image) {
            candidates.append(Candidate(
                url: primaryCheckout
                    .appendingPathComponent(".alas", isDirectory: true)
                    .appendingPathComponent(safeImage),
                source: .configKey
            ))
        }
        if let discovered = store.discoveredIconURL(worktreeRoot: primaryCheckout) {
            candidates.append(Candidate(url: discovered, source: .discovered))
        }
        return candidates
    }

    /// A repo icon past the staging limit can never be used, and the file size
    /// is already known from the stat that decided the candidate was there.
    private static func isOversized(_ values: URLResourceValues?) -> Bool {
        guard let size = values?.fileSize else { return false }
        return size > ProjectIconImageStaging.maxBytes
    }

    /// The configured file is a deliberate team decision, so one that is
    /// present but unusable (`logo.svg`, an oversized image, a broken file) is
    /// worth a diagnostic. A path that does not exist stays quiet: it would log
    /// on every render pass instead.
    private static func logUnusableConfigIcon(_ candidate: Candidate, exists: Bool) {
        guard candidate.source == .configKey, exists else { return }
        // `public` on purpose: the useful part of this diagnostic is *which*
        // repo needs fixing, and a redacted path makes it useless.
        logger.error(
            "Repo icon \(candidate.url.path, privacy: .public) from .alas/config.json could not be used; falling back"
        )
    }

    private enum CandidateSource {
        case configKey
        case discovered
    }

    private struct Candidate {
        let url: URL
        let source: CandidateSource
    }
}
