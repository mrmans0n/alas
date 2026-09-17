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
        /// Canonical path of the file the result was parsed from. Part of the
        /// identity because two distinct files can share size and modification
        /// date: a symlink repointed between them would otherwise keep serving
        /// the previous file's config.
        let targetPath: String?
        let modificationDate: Date?
        let fileSize: Int?
        let result: RepoConfigLoadResult
    }

    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "repo-config")

    private var cache: [String: Entry] = [:]

    func load(worktreeRoot: URL) -> RepoConfigLoadResult {
        let file = worktreeRoot.appendingPathComponent(RepoConfig.relativePath)
        // A committed symlink can point anywhere — including a character
        // device whose read would never return, on the main actor, before the
        // MCP trust prompt offers any protection. Only a bounded regular file
        // inside the repo's `.alas/` directory is ever read.
        let target = Self.confinedRegularFile(
            file,
            under: worktreeRoot.appendingPathComponent(".alas", isDirectory: true),
            checkout: worktreeRoot
        )
        let values = target.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) }

        if let entry = cache[file.path],
           entry.targetPath == target?.path,
           entry.modificationDate == values?.contentModificationDate,
           entry.fileSize == values?.fileSize {
            return entry.result
        }

        let result: RepoConfigLoadResult
        if let target {
            result = Self.classify(target)
        } else {
            // Present but not a bounded regular file inside `.alas/`: treat it
            // exactly like a malformed config so the repo contributes nothing.
            result = FileManager.default.fileExists(atPath: file.path) ? .malformed : .missing
        }
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
            targetPath: target?.path,
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

    /// The repo's conventional icon files, in extension order. The explicit
    /// `icon.image` key in `config.json` takes precedence over these. All
    /// existing candidates are returned, not just the first: a broken or
    /// oversized head entry must not mask a usable one behind it, and the
    /// resolver decides usability by staging.
    static func discoveredIconCandidates(worktreeRoot: URL) -> [URL] {
        Self.discoveredIconExtensions.compactMap { ext in
            let url = worktreeRoot.appendingPathComponent(".alas/icon.\(ext)")
            return Self.confinedRegularFile(
                url,
                under: worktreeRoot.appendingPathComponent(".alas", isDirectory: true),
                checkout: worktreeRoot
            )
        }
    }

    /// Resolves a path through any symlink components and only accepts it when
    /// it names a regular, non-device file inside the confinement root. A repo
    /// can commit a symlink pointing at anything — including a character
    /// device such as `/dev/zero`, whose read would never return — so the
    /// canonical target is validated before any caller reads bytes.
    ///
    /// When `checkout` is given, the canonical confinement root must itself
    /// stay inside the canonical checkout: a symlinked `.alas` pointing
    /// outside the repo would otherwise canonicalize both sides to the outside
    /// directory and pass a naive prefix check. Returns the canonical URL to
    /// read from, or nil.
    static func confinedRegularFile(
        _ file: URL,
        under root: URL,
        checkout: URL? = nil
    ) -> URL? {
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(canonicalRoot.path + "/") else { return nil }
        if let checkout {
            let canonicalCheckout = checkout.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalRoot.path.hasPrefix(canonicalCheckout.path + "/") else { return nil }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular
        else { return nil }
        return resolved
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
