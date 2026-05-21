import AppKit
import Foundation

extension GitService {
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
        let entries = try await status(worktreePath: worktreePath)
        let entry = entries.first { $0.path == relativePath }

        let fileURL = worktreePath.appendingPathComponent(relativePath)
        let fileExistsOnDisk = FileManager.default.fileExists(atPath: fileURL.path)
        let resolution = ImageDiffPairResolver.resolveWorkingCopy(
            entry: entry, fileExistsOnDisk: fileExistsOnDisk
        )

        // Fetch the "before" blob from HEAD. For renames, use the old path.
        let beforePath = resolution.oldPath ?? relativePath
        let before: NSImage?
        switch resolution.kind {
        case .added:
            before = nil
        default:
            before = try await loadBlobImage(
                worktreePath: worktreePath, ref: "HEAD", path: beforePath
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
            // Missing blob (e.g. file did not exist at HEAD) → nil rather
            // than throwing. Callers treat nil as "missing side".
            return nil
        }
        return NSImage(data: result.stdout)
    }

    fileprivate func frameCount(for image: NSImage?) -> Int {
        guard let image,
              let rep = image.representations.first as? NSBitmapImageRep,
              let value = rep.value(forProperty: .frameCount) as? Int
        else { return image == nil ? 0 : 1 }
        return value
    }
}
