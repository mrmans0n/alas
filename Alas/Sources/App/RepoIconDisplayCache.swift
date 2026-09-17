import Foundation

/// Remembers the icon a project displays once its repo's `.alas/` layer is
/// applied, keyed on the identity of the repo file that supplied it.
///
/// Resolving a repo icon reads and hashes the image to stage it, and the
/// sidebar asks for a project's icon on every render pass, so the answer has to
/// be kept. Keying on the source file's identity — not on the project alone —
/// is what makes a replaced icon, an edited `config.json` pointing elsewhere,
/// or a branch switch invalidate the entry without any explicit refresh.
///
/// Main-actor confined, like `RepoConfigStore`: `AppState` owns the single
/// instance and only its render paths read it.
final class RepoIconDisplayCache {
    /// Identity of the repo file an icon was staged from.
    private struct Key: Equatable {
        let sourcePath: String
        let modificationDate: Date?
        let fileSize: Int?
    }

    private struct Entry: Equatable {
        let key: Key
        let icon: ProjectIcon
    }

    /// One entry per project: a project has at most one repo icon, so a new
    /// revision replaces the previous one instead of piling up per render.
    private var entries: [String: Entry] = [:]

    /// The icon staged from this exact repo file revision, or nil when the
    /// resolution has no repo source or that source has changed since.
    func icon(for resolution: RepoIconResolver.RepoIconResolution, projectID: String) -> ProjectIcon? {
        guard let key = Self.key(for: resolution),
              let entry = entries[projectID],
              entry.key == key
        else { return nil }
        return entry.icon
    }

    /// Caches an icon that came from a repo file. An icon that fell back to the
    /// app icon is deliberately not cached: it costs a few stats to recompute,
    /// and remembering it would hide an `.alas/icon.png` added later.
    func store(_ resolution: RepoIconResolver.RepoIconResolution, projectID: String) {
        guard let key = Self.key(for: resolution) else { return }
        entries[projectID] = Entry(key: key, icon: resolution.icon)
    }

    private static func key(for resolution: RepoIconResolver.RepoIconResolution) -> Key? {
        guard let sourceURL = resolution.sourceURL else { return nil }
        return Key(
            sourcePath: sourceURL.path,
            modificationDate: resolution.sourceModificationDate,
            fileSize: resolution.sourceFileSize
        )
    }
}
