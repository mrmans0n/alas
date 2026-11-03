import AlasCore
import Darwin
import Foundation

/// The disk VM files actually use: allocated blocks, not logical sizes, since disk images are
/// sparse. Read with `lstat`, which never answers from a cache as `URL.resourceValues` does.
enum VMDiskUsage {
    /// The allocated bytes of one file; nil when it can't be read.
    nonisolated static func allocatedBytes(of file: URL) -> Int64? {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return nil }
        return Int64(info.st_blocks) * 512
    }

    /// The allocated bytes of every file at or under `url`, without following symbolic links;
    /// zero when nothing is there.
    nonisolated static func allocatedBytes(inTree url: URL) -> Int64 {
        guard var total = allocatedBytes(of: url) else { return 0 }
        guard let entries = FileManager.default.enumerator(atPath: url.path) else { return total }
        for case let relative as String in entries {
            total += allocatedBytes(of: url.appendingPathComponent(relative)) ?? 0
        }
        return total
    }

    /// Files an interrupted reset (`disk.img.resetting`) or clean point (`clean.partial/`) left
    /// in a bundle. Only stale while no Alas runs the VM or works on its disk.
    nonisolated static func leftovers(in bundle: URL) -> [URL] {
        ["disk.img.resetting", "clean.partial"]
            .map { bundle.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// What Settings › Worktree VMs lists: base images and VMs, and the orphaned VM bundles.
struct VMDiskUse: Sendable {
    var bundles: [VMBundleSummary] = []
    var orphans: [VMBundleSummary] = []
}

/// A base image or worktree VM bundle, as Settings › Worktree VMs lists it.
struct VMBundleSummary: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case golden, worktree }

    /// `golden:<build>` or `golden-linux:<serial>` for base images, `worktrees/<folder>` for VMs.
    let id: String
    let kind: Kind
    let guest: VMGuestOS
    /// A base image's build or serial; a VM's bundle folder name.
    let name: String
    /// A macOS base image's version ("27.2"), when its install kept it.
    var osVersion: String?
    /// The worktree a VM's record names; nil for base images and bundles no record names.
    let worktreeID: String?
    let url: URL
    /// Whether this process runs the VM, boots it, or works on its disk.
    let runningHere: Bool
    /// The label of the other Alas that runs it, if one does.
    let runningElsewhere: String?
    /// A VM bundle no live worktree owns (see `VMOrphans`).
    let isOrphan: Bool
    /// A VM bundle only a record this build can't decode names: another Alas version's, left alone.
    var fromOtherBuild = false
    /// Stale leftovers Clean up removes; empty while the VM runs anywhere.
    let leftovers: [URL]
    /// For a base image, how many VMs were cloned from it; it can't be deleted while any exist.
    var clones = 0
    /// Disk the bundle uses, leftovers excluded; filled in off the main actor.
    var allocatedBytes: Int64 = 0
    var leftoverBytes: Int64 = 0

    /// The VM's registry id, when a record names it.
    var recordID: String? { worktreeID.map { VMIdentity.recordID(worktree: $0, guest: guest) } }

    /// Sizes for `bundles`, read off the main actor.
    static func measured(_ bundles: [VMBundleSummary]) async -> [VMBundleSummary] {
        await Task.detached(priority: .utility) {
            bundles.map { bundle in
                var bundle = bundle
                bundle.leftoverBytes = bundle.leftovers.reduce(0) { $0 + VMDiskUsage.allocatedBytes(inTree: $1) }
                bundle.allocatedBytes = VMDiskUsage.allocatedBytes(inTree: bundle.url) - bundle.leftoverBytes
                return bundle
            }
        }.value
    }
}
