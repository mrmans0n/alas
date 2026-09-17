import Foundation

/// Remembers the icon a project displays once its repo's `.alas/` layer is
/// applied, keyed on the identity of the repo file that supplied it.
///
/// Staging a repo icon reads and hashes the image, and the sidebar asks for a
/// project's icon on every render pass, so the answer has to be kept. The
/// lookup takes the same candidate chain a stats-only probe produces, which
/// is what keeps the steady state free of reads and hashes: the expensive
/// resolve happens only on a miss. Keying on the candidates' identities —
/// not on the project alone — is what makes a replaced icon, an edited
/// `config.json` pointing elsewhere, or a branch switch invalidate the entry
/// with no explicit refresh.
///
/// Main-actor confined, like `RepoConfigStore`: `AppState` owns the single
/// instance and only its render paths read it.
final class RepoIconDisplayCache {
    /// What an icon is cached against: the stamps of every repo file that could
    /// currently supply it, in `resolve`'s candidate order, plus the app-icon
    /// preferences carried onto the rendered icon.
    ///
    /// The whole chain, not just the winning file, because a head candidate that
    /// exists but cannot be used makes `resolve` fall through to the next one —
    /// and keying that outcome on the winner alone would keep serving a stale
    /// fallback while the fallback file itself is edited or deleted.
    struct Key: Hashable {
        let chain: [RepoIconResolver.SourceIdentity]
        let color: String
        let transparentBackground: Bool

        init(chain: [RepoIconResolver.SourceIdentity], appIcon: ProjectIcon) {
            self.chain = chain
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

    /// The icon staged from these exact candidate revisions, or nil when
    /// nothing was stored for the project or any candidate has moved on since.
    func icon(for key: Key, projectID: String) -> ProjectIcon? {
        guard let entry = entries[projectID], entry.key == key else { return nil }
        return entry.icon
    }

    /// Caches the icon the current candidates resolved to. A resolution that
    /// fell back to the app icon has no source to key on and is deliberately
    /// not cached: it costs a few stats to recompute, and remembering it would
    /// hide an `.alas/icon.png` added later.
    func store(_ resolution: RepoIconResolver.RepoIconResolution, chain: [RepoIconResolver.SourceIdentity], appIcon: ProjectIcon, projectID: String) {
        guard !chain.isEmpty else { return }
        store(resolution.icon, for: Key(chain: chain, appIcon: appIcon), projectID: projectID)
    }

    /// Caches an already-resolved icon under a chain a probe reported.
    func store(_ icon: ProjectIcon, for key: Key, projectID: String) {
        entries[projectID] = Entry(key: key, icon: icon)
    }
}
