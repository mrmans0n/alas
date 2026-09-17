import Foundation

/// Remembers the icon a project displays once its repo's `.alas/` layer is
/// applied, keyed on the identity of the repo file that supplied it.
///
/// Staging a repo icon reads and hashes the image, and the sidebar asks for a
/// project's icon on every render pass, so the answer has to be kept. The
/// lookup takes the same identity a stats-only probe produces, which is what
/// keeps the steady state free of reads and hashes: the expensive resolve
/// happens only on a miss. Keying on the source file's identity — not on the
/// project alone — is what makes a replaced icon, an edited `config.json`
/// pointing elsewhere, or a branch switch invalidate the entry with no explicit
/// refresh.
///
/// Main-actor confined, like `RepoConfigStore`: `AppState` owns the single
/// instance and only its render paths read it.
final class RepoIconDisplayCache {
    /// What an icon is cached against: the repo file it was staged from, plus
    /// the app-icon preferences carried onto the rendered icon, so changing the
    /// project's colour shows up without waiting for the file to change.
    struct Key: Hashable {
        let sourcePath: String
        let modificationDate: Date?
        let fileSize: Int?
        let color: String
        let transparentBackground: Bool

        init(identity: RepoIconResolver.SourceIdentity, appIcon: ProjectIcon) {
            sourcePath = identity.url.path
            modificationDate = identity.modificationDate
            fileSize = identity.fileSize
            color = appIcon.color
            transparentBackground = appIcon.transparentBackground
        }
    }

    private struct Entry: Equatable {
        let key: Key
        let icon: ProjectIcon
    }

    /// One entry per project: a project has at most one repo icon, so a new
    /// revision replaces the previous one instead of piling up per render.
    private var entries: [String: Entry] = [:]

    /// How many projects hold a cached icon. Exposed so tests can prove that a
    /// repeated store replaces rather than accumulates.
    var storedEntryCount: Int { entries.count }

    /// The icon staged from this exact repo file revision, or nil when nothing
    /// was stored for the project or the identity has moved on since.
    func icon(for key: Key, projectID: String) -> ProjectIcon? {
        guard let entry = entries[projectID], entry.key == key else { return nil }
        return entry.icon
    }

    /// Caches the icon a repo file supplied. A resolution that fell back to the
    /// app icon has no source to key on and is deliberately not cached: it costs
    /// a few stats to recompute, and remembering it would hide an
    /// `.alas/icon.png` added later.
    func store(_ resolution: RepoIconResolver.RepoIconResolution, appIcon: ProjectIcon, projectID: String) {
        guard let identity = resolution.sourceIdentity else { return }
        store(resolution.icon, for: Key(identity: identity, appIcon: appIcon), projectID: projectID)
    }

    /// Caches an already-resolved icon under an identity a probe reported.
    ///
    /// Used when `resolve` had to skip the probe's first candidate — an
    /// unreadable or oversized file the probe could not rule out with a stat —
    /// and took the next one instead. Remembering that outcome under the probed
    /// identity keeps the following render a hit rather than re-reading the
    /// file that could not be used.
    func store(_ icon: ProjectIcon, for key: Key, projectID: String) {
        entries[projectID] = Entry(key: key, icon: icon)
    }
}
