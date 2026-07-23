import AppKit
import Foundation
import os

extension GitService {
    private static let imageDiffLogger = Logger(subsystem: "io.nlopez.alas", category: "git-service")
    private static let workingTreeImageRevision = "__alas_working_tree__"
    private static let blobImageRevisionPrefix = "__alas_blob__:"

    func imageSide(
        worktreePath: URL,
        revision: String,
        path: String
    ) async -> ImageDiffSide {
        if revision == Self.workingTreeImageRevision {
            let fileURL = worktreePath.appendingPathComponent(path)
            guard let image = NSImage(contentsOf: fileURL) else {
                Self.logImageSideFailure(
                    category: "changed-on-disk", worktreePath: worktreePath, revision: revision, path: path,
                    diagnostic: "Unable to decode working-tree image"
                )
                return .failed(ImageDiffLoadFailure(message: "changed-on-disk"))
            }
            return .image(image, frameCount: frameCount(for: image))
        }

        if Self.isImmutableImageRevision(revision) {
            let key = ImageDiffDecodedCache.Key(
                repository: worktreePath.standardizedFileURL.path,
                revision: revision,
                path: path
            )
            return await ImageDiffDecodedCache.shared.side(
                for: key,
                cost: ImageDiffDecodedCache.decodedImageCost,
                makeImageSide: { image in .image(image, frameCount: self.frameCount(for: image)) }
            ) {
                await self.loadImageBlob(worktreePath: worktreePath, revision: revision, path: path)
            }
        }

        return await loadImageBlob(worktreePath: worktreePath, revision: revision, path: path)
    }

    func workingCopyImageProvider(
        worktreePath: URL,
        change: ChangedFile
    ) async -> DiffReviewImageProvider {
        let staged = change.stage == .staged
        let resolution = ImageDiffPairResolver.resolveWorkingCopy(
            entry: change,
            fileExistsOnDisk: FileManager.default.fileExists(
                atPath: worktreePath.appendingPathComponent(change.path).path
            ),
            staged: staged
        )
        let indexPath = staged ? change.path : (resolution.oldPath ?? change.path)
        let indexRevision = await indexObjectID(worktreePath: worktreePath, path: indexPath)
        let diskToken = fileMetadataToken(worktreePath: worktreePath, path: change.path)
        let indexImageRevision = Self.imageRevision(forIndexObjectID: indexRevision)
        let beforeRevision = staged ? "HEAD" : indexImageRevision
        let afterRevision = staged ? indexImageRevision : Self.workingTreeImageRevision

        return imageProvider(
            source: .workingCopy,
            worktreePath: worktreePath,
            beforeRevision: "\(change.stage.rawValue):\(beforeRevision)",
            afterRevision: "\(afterRevision):\(diskToken)",
            beforePath: resolution.oldPath,
            afterPath: change.path
        ) { [self] in
            let before: ImageDiffSide = switch resolution.kind {
            case .added: .missing
            default: await imageSide(
                worktreePath: worktreePath,
                revision: beforeRevision,
                path: resolution.oldPath ?? change.path
            )
            }
            let after: ImageDiffSide = switch resolution.kind {
            case .deleted: .missing
            default: await imageSide(
                worktreePath: worktreePath,
                revision: afterRevision,
                path: change.path
            )
            }
            return ImageDiffPair(before: before, after: after, oldPath: resolution.oldPath, kind: resolution.kind)
        }
    }

    func stagedImageProvider(
        worktreePath: URL,
        file: CommitChangedFile
    ) async -> DiffReviewImageProvider {
        let resolution = ImageDiffPairResolver.resolveCommit(entry: file)
        let indexRevision = await indexObjectID(worktreePath: worktreePath, path: file.path)
        let indexImageRevision = Self.imageRevision(forIndexObjectID: indexRevision)

        return imageProvider(
            source: .workingCopy,
            worktreePath: worktreePath,
            beforeRevision: "staged:HEAD",
            afterRevision: "index:\(indexRevision)",
            beforePath: resolution.oldPath,
            afterPath: file.path
        ) { [self] in
            let before: ImageDiffSide = switch resolution.kind {
            case .added: .missing
            default: await imageSide(
                worktreePath: worktreePath,
                revision: "HEAD",
                path: resolution.oldPath ?? file.path
            )
            }
            let after: ImageDiffSide = switch resolution.kind {
            case .deleted: .missing
            default: await imageSide(worktreePath: worktreePath, revision: indexImageRevision, path: file.path)
            }
            return ImageDiffPair(before: before, after: after, oldPath: resolution.oldPath, kind: resolution.kind)
        }
    }

    func commitImageProvider(
        worktreePath: URL,
        sha: String,
        file: CommitChangedFile
    ) -> DiffReviewImageProvider {
        let resolution = ImageDiffPairResolver.resolveCommit(entry: file)
        let beforeRevision = "\(sha)^"

        return imageProvider(
            source: .commit,
            worktreePath: worktreePath,
            beforeRevision: beforeRevision,
            afterRevision: sha,
            beforePath: resolution.oldPath,
            afterPath: file.path
        ) { [self] in
            let before: ImageDiffSide = switch resolution.kind {
            case .added: .missing
            default: await imageSide(
                worktreePath: worktreePath,
                revision: beforeRevision,
                path: resolution.oldPath ?? file.path
            )
            }
            let after: ImageDiffSide = switch resolution.kind {
            case .deleted: .missing
            default: await imageSide(worktreePath: worktreePath, revision: sha, path: file.path)
            }
            return ImageDiffPair(before: before, after: after, oldPath: resolution.oldPath, kind: resolution.kind)
        }
    }

    func rangeImageProvider(
        worktreePath: URL,
        revisions: (before: String, after: String),
        file: CommitChangedFile
    ) -> DiffReviewImageProvider {
        let resolution = ImageDiffPairResolver.resolveCommit(entry: file)

        return imageProvider(
            source: .range,
            worktreePath: worktreePath,
            beforeRevision: revisions.before,
            afterRevision: revisions.after,
            beforePath: resolution.oldPath,
            afterPath: file.path
        ) { [self] in
            let before: ImageDiffSide = switch resolution.kind {
            case .added: .missing
            default: await imageSide(
                worktreePath: worktreePath,
                revision: revisions.before,
                path: resolution.oldPath ?? file.path
            )
            }
            let after: ImageDiffSide = switch resolution.kind {
            case .deleted: .missing
            default: await imageSide(
                worktreePath: worktreePath,
                revision: revisions.after,
                path: file.path
            )
            }
            return ImageDiffPair(before: before, after: after, oldPath: resolution.oldPath, kind: resolution.kind)
        }
    }

    /// Commit variant. Returns the before/after `NSImage`s for an image
    /// file changed in commit `sha`. The caller passes the
    /// `CommitChangedFile` (which already carries status + originalPath)
    /// to avoid re-running diff-tree.
    ///
    /// before = `git show <parent>:<oldPath>` (nil for added / initial-commit cases)
    /// after  = `git show <sha>:<path>`        (nil for deleted)
    func imageDiffPairForCommit(
        worktreePath: URL,
        sha: String,
        file: CommitChangedFile
    ) async throws -> ImageDiffPair {
        let resolution = ImageDiffPairResolver.resolveCommit(entry: file)

        // Parent. Empty for initial commits — handled below as no `before`.
        let parentsResult = try await Process.git(
            ["rev-list", "--parents", "-n", "1", sha], cwd: worktreePath
        )
        let parts = parentsResult.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        let parentSha: String? = parts.count > 1 ? String(parts[1]) : nil

        let beforePath = resolution.oldPath ?? file.path
        let before: NSImage?
        if let parentSha, resolution.kind != .added {
            before = try await loadBlobImage(
                worktreePath: worktreePath, ref: parentSha, path: beforePath
            )
        } else {
            before = nil
        }

        let after: NSImage?
        if resolution.kind != .deleted {
            after = try await loadBlobImage(
                worktreePath: worktreePath, ref: sha, path: file.path
            )
        } else {
            after = nil
        }

        return ImageDiffPair(
            before: before,
            after: after,
            oldPath: resolution.oldPath,
            kind: resolution.kind,
            beforeFrameCount: frameCount(for: before),
            afterFrameCount: frameCount(for: after)
        )
    }

    func imageDiffPairForRange(
        worktreePath: URL,
        base: String,
        head: String,
        threeDot: Bool,
        file: CommitChangedFile
    ) async throws -> ImageDiffPair {
        let revisions = try await resolvedRangeTrees(
            worktreePath: worktreePath,
            base: base,
            head: head,
            threeDot: threeDot
        )
        return await rangeImageProvider(
            worktreePath: worktreePath,
            revisions: revisions,
            file: file
        ).load()
    }

    /// Working-copy variant. Returns the before/after `NSImage`s and the
    /// kind of change (added/deleted/renamed/modified) for an image file.
    ///
    /// `staged == false`: before = HEAD blob, after = working-tree file.
    /// `staged == true`:  before = HEAD blob, after = index blob.
    func imageDiffPair(
        worktreePath: URL,
        relativePath: String,
        staged: Bool
    ) async throws -> ImageDiffPair {
        // Use a dedicated status fetch with a more permissive rename
        // threshold than `GitService.status(...)` uses for the rest of
        // the app. Image renames frequently come with significant edits
        // (logo redesign, compression change, format conversion), and
        // git's default 50%-similarity heuristic misses those. A 30%
        // threshold catches the realistic cases without producing false
        // pairings between unrelated images.
        let entries = try await imageDiffStatus(worktreePath: worktreePath)
        // A path can appear twice in status when it has both staged AND
        // unstaged changes. Pick the entry whose stage matches the caller's
        // intent; fall back to the other side only if the requested stage
        // has no entry (e.g. an untracked file shows up only as unstaged).
        let requestedStage: ChangeStage = staged ? .staged : .unstaged
        let entry = entries.first { $0.path == relativePath && $0.stage == requestedStage }
            ?? entries.first { $0.path == relativePath }

        let fileURL = worktreePath.appendingPathComponent(relativePath)
        let fileExistsOnDisk = FileManager.default.fileExists(atPath: fileURL.path)
        let resolution = ImageDiffPairResolver.resolveWorkingCopy(
            entry: entry, fileExistsOnDisk: fileExistsOnDisk, staged: staged
        )

        // Fetch the "before" blob. For renames, use the old path. The
        // resolver guarantees `.renamed` carries a non-nil oldPath (and
        // falls back to `.modified` if a "R" entry had a missing rename
        // source), so the `??` is defensive — not load-bearing on any
        // path the resolver actually emits.
        //
        // Semantics:
        //   staged == true  → HEAD vs index:  before = HEAD blob.
        //   staged == false → index vs worktree: before = index blob.
        //
        // Using the index as "before" for the unstaged side is important
        // when a file has been staged-added (no HEAD blob) and then
        // deleted from the working tree: HEAD has nothing, but the index
        // has the blob that should appear on the left side of the diff.
        let beforeRef: String = staged ? "HEAD" : ""
        let beforePath = resolution.oldPath ?? relativePath
        let before: NSImage?
        switch resolution.kind {
        case .added:
            before = nil
        default:
            before = try await loadBlobImage(
                worktreePath: worktreePath, ref: beforeRef, path: beforePath
            )
        }

        // Fetch the "after" blob.
        let after: NSImage?
        switch resolution.kind {
        case .deleted:
            after = nil
        default:
            if staged {
                // Read the index version (`:` is the index ref).
                after = try await loadBlobImage(
                    worktreePath: worktreePath, ref: "", path: relativePath
                )
            } else {
                // Read the file from disk.
                if fileExistsOnDisk {
                    after = NSImage(contentsOf: fileURL)
                } else {
                    after = nil
                }
            }
        }

        return ImageDiffPair(
            before: before,
            after: after,
            oldPath: resolution.oldPath,
            kind: resolution.kind,
            beforeFrameCount: frameCount(for: before),
            afterFrameCount: frameCount(for: after)
        )
    }

    func imageDiffPairAgainstHEAD(
        worktreePath: URL,
        relativePath: String,
        originalPath: String? = nil
    ) async throws -> ImageDiffPair {
        let headPath = originalPath ?? relativePath
        let fileURL = worktreePath.appendingPathComponent(relativePath)
        let fileExistsOnDisk = FileManager.default.fileExists(atPath: fileURL.path)

        let before = try await loadBlobImage(
            worktreePath: worktreePath,
            ref: "HEAD",
            path: headPath
        )
        let after = fileExistsOnDisk ? NSImage(contentsOf: fileURL) : nil
        let oldPath = originalPath ?? (before != nil && relativePath != headPath ? headPath : nil)
        let kind: ImageDiffPairKind
        switch (before != nil, after != nil, oldPath != nil) {
        case (false, true, _):
            kind = .added
        case (true, false, _):
            kind = .deleted
        case (true, true, true):
            kind = .renamed
        default:
            kind = .modified
        }

        return ImageDiffPair(
            before: before,
            after: after,
            oldPath: oldPath,
            kind: kind,
            beforeFrameCount: frameCount(for: before),
            afterFrameCount: frameCount(for: after)
        )
    }

    /// Internal: `git show <ref>:<path>` → `NSImage`. `ref == ""` means
    /// the index (i.e. `:path`).
    fileprivate func loadBlobImage(
        worktreePath: URL,
        ref: String,
        path: String
    ) async throws -> NSImage? {
        let spec = "\(ref):\(path)"
        let result = try await Process.gitData(
            ["show", spec], cwd: worktreePath
        )
        guard result.exitCode == 0 else {
            // The expected non-zero is "path does not exist in <ref>",
            // which is a legitimate missing-side signal (added: no HEAD
            // blob; deleted: no current blob). Anything else (corrupted
            // repo, bad ref, disk error) is unexpected — surface to the
            // log so it can be diagnosed, but still return nil so the
            // caller's missing-side handling keeps working.
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let isExpectedMissing = stderr.contains("does not exist") ||
                                    stderr.contains("exists on disk, but not in")
            if !isExpectedMissing {
                Self.imageDiffLogger.error("git show \(spec, privacy: .public) failed: \(stderr, privacy: .public)")
            }
            return nil
        }
        return await GitLFSBlobResolver.image(
            fromGitBlobData: result.stdout,
            worktreePath: worktreePath
        )
    }

    fileprivate func frameCount(for image: NSImage?) -> Int {
        guard let image,
              let rep = image.representations.first as? NSBitmapImageRep,
              let value = rep.value(forProperty: .frameCount) as? Int
        else { return image == nil ? 0 : 1 }
        return value
    }

    /// Internal: `git status` with a more permissive rename threshold
    /// than the app-wide `GitService.status(...)`. The image-diff path
    /// needs this because real image renames (logo redesigns, format
    /// conversions, palette swaps) frequently fall below git's default
    /// 50% similarity threshold.
    ///
    /// Mirrors `status(...)`'s arg shape and parses via the same
    /// `StatusParser`, but doesn't enrich with numstat — the loader
    /// only needs `path`/`status`/`stage`/`renameFrom`.
    fileprivate func imageDiffStatus(worktreePath: URL) async throws -> [ChangedFile] {
        let result = try await Process.git(
            [
                "status", "--porcelain=v2", "-z",
                "--untracked-files=all",
                "--find-renames=30%",
            ],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else { return [] }
        return try StatusParser.parse(result.stdout)
    }

    private func imageProvider(
        source: DiffReviewImageProviderID.Source,
        worktreePath: URL,
        beforeRevision: String,
        afterRevision: String,
        beforePath: String?,
        afterPath: String,
        load: @escaping @MainActor () async -> ImageDiffPair
    ) -> DiffReviewImageProvider {
        DiffReviewImageProvider(
            id: DiffReviewImageProviderID(
                source: source,
                repository: worktreePath.standardizedFileURL.path,
                beforeRevision: beforeRevision,
                afterRevision: afterRevision,
                beforePath: beforePath,
                afterPath: afterPath
            ),
            load: load
        )
    }

    private func indexObjectID(worktreePath: URL, path: String) async -> String {
        do {
            let result = try await Process.git(["rev-parse", ":\(path)"], cwd: worktreePath)
            guard result.exitCode == 0 else { return "missing-index" }
            let objectID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return objectID.isEmpty ? "missing-index" : objectID
        } catch {
            Self.logImageSideFailure(
                category: "Git", worktreePath: worktreePath, revision: "index", path: path,
                diagnostic: error.localizedDescription
            )
            return "missing-index"
        }
    }

    private func fileMetadataToken(worktreePath: URL, path: String) -> String {
        let fileURL = worktreePath.appendingPathComponent(path)
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return "missing-on-disk" }
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let size = values.fileSize ?? 0
        return "\(modified):\(size)"
    }

    private func loadImageBlob(worktreePath: URL, revision: String, path: String) async -> ImageDiffSide {
        let spec = Self.blobObjectID(from: revision) ?? "\(revision):\(path)"
        do {
            let result = try await Process.gitData(["show", spec], cwd: worktreePath)
            guard result.exitCode == 0 else {
                let diagnostic = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                Self.logImageSideFailure(
                    category: "Git", worktreePath: worktreePath, revision: revision, path: path,
                    diagnostic: diagnostic
                )
                return .failed(ImageDiffLoadFailure(message: "Git"))
            }

            if let image = await GitLFSBlobResolver.image(fromGitBlobData: result.stdout, worktreePath: worktreePath) {
                return .image(image, frameCount: frameCount(for: image))
            }

            let category = Self.isLFSPointer(result.stdout) ? "LFS" : "decode"
            Self.logImageSideFailure(
                category: category, worktreePath: worktreePath, revision: revision, path: path,
                diagnostic: "Image data could not be decoded"
            )
            return .failed(ImageDiffLoadFailure(message: category))
        } catch {
            Self.logImageSideFailure(
                category: "Git", worktreePath: worktreePath, revision: revision, path: path,
                diagnostic: error.localizedDescription
            )
            return .failed(ImageDiffLoadFailure(message: "Git"))
        }
    }

    private static func isImmutableImageRevision(_ revision: String) -> Bool {
        revision != "HEAD" && revision != workingTreeImageRevision && revision != "missing-index"
    }

    private static func imageRevision(forIndexObjectID objectID: String) -> String {
        objectID == "missing-index" ? objectID : "\(blobImageRevisionPrefix)\(objectID)"
    }

    private static func blobObjectID(from revision: String) -> String? {
        guard revision.hasPrefix(blobImageRevisionPrefix) else { return nil }
        return String(revision.dropFirst(blobImageRevisionPrefix.count))
    }

    private static func isLFSPointer(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8)?.hasPrefix("version https://git-lfs.github.com/spec/v1") == true
    }

    private static func logImageSideFailure(
        category: String,
        worktreePath: URL,
        revision: String,
        path: String,
        diagnostic: String
    ) {
        imageDiffLogger.error(
            "Image side \(category, privacy: .public) failed for \(worktreePath.path, privacy: .public) \(revision, privacy: .public):\(path, privacy: .public): \(diagnostic, privacy: .public)"
        )
    }
}
