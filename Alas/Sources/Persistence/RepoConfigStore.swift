import Foundation
import os

/// Outcome of reading a worktree's `.alas/config.json`. A malformed file stays
/// distinct from a missing one so callers can tell "this repo has no config"
/// apart from "this repo's config is broken".
enum RepoConfigLoadResult: Equatable {
    case missing
    case loaded(RepoConfig)
    case malformed
}

/// Reads the repo-local `.alas/config.json` for a worktree.
///
/// Every lookup stats the file and reparses only when its modification date or
/// size changed, so `git pull` and branch switches are picked up on the next
/// lookup without file watchers, while repeated sidebar renders stay cheap.
/// Local repos only: callers treat a remote project as having no repo config.
final class RepoConfigStore {
    private struct Entry {
        let modificationDate: Date?
        let fileSize: Int?
        let result: RepoConfigLoadResult
    }

    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "repo-config")

    private var cache: [String: Entry] = [:]

    func load(worktreeRoot: URL) -> RepoConfigLoadResult {
        let file = worktreeRoot.appendingPathComponent(RepoConfig.relativePath)
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])

        if let entry = cache[file.path],
           entry.modificationDate == values?.contentModificationDate,
           entry.fileSize == values?.fileSize {
            return entry.result
        }

        let result = Self.classify(file)
        // Logged on reparse only, so a broken or unreadable file in a project
        // on screen reports once per change instead of once per render.
        if case .malformed = result {
            // `public` on purpose: the useful part of this diagnostic is *which*
            // repo needs fixing, and a redacted path makes it useless.
            Self.logger.error(
                "Repo config at \(file.path, privacy: .public) is unreadable or malformed; ignoring it"
            )
        }
        cache[file.path] = Entry(
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize,
            result: result
        )
        return result
    }

    /// Convenience for hot callers (icon rendering, session attach): anything
    /// that is not a readable config means the repo contributes nothing.
    func config(worktreeRoot: URL) -> RepoConfig? {
        switch load(worktreeRoot: worktreeRoot) {
        case .loaded(let config): config
        case .missing, .malformed: nil
        }
    }

    /// PNG, JPEG, GIF and WebP are the formats the icon staging pipeline can
    /// identify by magic bytes; SVG is deliberately not discovered.
    static let discoveredIconExtensions = ["png", "jpg", "jpeg", "gif", "webp"]

    /// The repo's conventional icon file, if it committed one. The explicit
    /// `icon.image` key in `config.json` takes precedence over this.
    func discoveredIconURL(worktreeRoot: URL) -> URL? {
        let fileManager = FileManager.default
        for ext in Self.discoveredIconExtensions {
            let url = worktreeRoot.appendingPathComponent(".alas/icon.\(ext)")
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// A path that does not exist reads as missing. Anything else that cannot
    /// become a config — unreadable (permissions, or a directory in the file's
    /// place), or readable but undecodable — is malformed, so "this repo has no
    /// config" stays distinguishable from "this repo's config is broken".
    private static func classify(_ file: URL) -> RepoConfigLoadResult {
        guard let data = try? Data(contentsOf: file) else {
            // The happy path keeps its single stat: only a failed read pays for
            // the extra existence check.
            return FileManager.default.fileExists(atPath: file.path) ? .malformed : .missing
        }
        guard let config = RepoConfig(jsonData: data) else { return .malformed }
        return .loaded(config)
    }
}
