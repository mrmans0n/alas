import Foundation
import Darwin
import AlasModel
import AlasPlatform

/// Watches the files paired Macs follow and publishes `fileChanged` when one's
/// content, or whether it is there, changes. Each file is watched once
/// however many follow it: the first follow starts the watch, the last
/// unfollow stops it.
@MainActor
final class HostFileWatcher {
    private let publish: @MainActor ([HostEvent]) -> Void
    /// Followers per "worktreeID/path".
    private(set) var watches: [String: Int] = [:]
    /// The files being watched; a path that is not watchable has a count but no file.
    private var files: [String: WatchedFile] = [:]
    private let queue = DispatchQueue(label: "alas.host.file-watcher")

    init(publish: @escaping @MainActor ([HostEvent]) -> Void) {
        self.publish = publish
    }

    isolated deinit {
        files.values.forEach { $0.stop() }
    }

    /// Counted per (worktree, path). Returns once the file's current version
    /// is known: changes after that are published.
    func follow(_ worktree: Worktree, path: String) async {
        let key = Self.key(worktree.id, path)
        watches[key, default: 0] += 1
        if watches[key] == 1, let url = Self.watchableURL(path, in: worktree.path) {
            let file = WatchedFile(worktreeID: worktree.id, path: path, url: url)
            files[key] = file
            file.directorySource = source(on: url.deletingLastPathComponent(), mask: .write, key: key)
            probe(key, file, publishing: false)
        }
        await files[key]?.probing?.value
    }

    func unfollow(worktreeID: String, path: String) {
        let key = Self.key(worktreeID, path)
        guard let count = watches[key] else { return }
        guard count <= 1 else {
            watches[key] = count - 1
            return
        }
        watches[key] = nil
        files.removeValue(forKey: key)?.stop()
    }

    private static func key(_ worktreeID: String, _ path: String) -> String {
        "\(worktreeID)/\(path)"
    }

    /// `path` in `root`, unless it leaves it or a folder on the way is a symlink.
    private static func watchableURL(_ path: String, in root: URL) -> URL? {
        guard let url = RemoteWorktreeFileAccess.resolve(path: path, in: root) else { return nil }
        var folder = root
        for component in url.pathComponents.dropFirst(root.pathComponents.count).dropLast() {
            folder.appendPathComponent(component)
            if RemoteWorktreeFileAccess.isSymlink(at: folder) { return nil }
        }
        return url
    }

    /// Something happened to the file or its folder.
    private func changed(_ key: String) {
        guard let file = files[key] else { return }
        probe(key, file)
    }

    /// Reads the file's version off the main actor and publishes it when it
    /// differs from the last one known. Events while a read is underway
    /// queue one more read, so a burst of them, as an atomic save makes,
    /// yields one event.
    private func probe(_ key: String, _ file: WatchedFile, publishing: Bool = true) {
        guard file.probing == nil else {
            file.isDirty = true
            return
        }
        file.probing = Task { [weak self] in
            var publishing = publishing
            repeat {
                file.isDirty = false
                // Opened before the read, so a write after the read fires it.
                // A rename save swaps the file for a new one each time.
                self?.reopenFileSource(key, file)
                let probe = await RemoteWorktreeFileAccess.probeVersion(at: file.url)
                guard let self, files[key] === file else { return }
                let version: WorktreeFileVersion? = if case .version(let version, _) = probe { version } else { nil }
                if publishing, version?.contentHash != file.contentHash {
                    publish([.fileChanged(worktreeID: file.worktreeID, path: file.path, version: version)])
                }
                file.contentHash = version?.contentHash
                publishing = true
            } while file.isDirty
            file.probing = nil
        }
    }

    private func reopenFileSource(_ key: String, _ file: WatchedFile) {
        guard files[key] === file else { return }
        file.fileSource?.cancel()
        file.fileSource = source(on: file.url, mask: [.write, .extend, .attrib, .rename, .delete], key: key, noFollow: true)
    }

    /// A source on `url`, nil while there is nothing there to watch.
    private func source(
        on url: URL, mask: DispatchSource.FileSystemEvent, key: String, noFollow: Bool = false
    ) -> DispatchSourceFileSystemObject? {
        Self.source(on: url, mask: mask, noFollow: noFollow, queue: queue) { [weak self] in
            Task { @MainActor [weak self] in self?.changed(key) }
        }
    }

    /// Nonisolated, so its handlers run on `queue` rather than claim the main actor.
    private nonisolated static func source(
        on url: URL, mask: DispatchSource.FileSystemEvent, noFollow: Bool, queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC | (noFollow ? O_NOFOLLOW : 0))
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}

/// One watched file: its sources and the version last known.
@MainActor
private final class WatchedFile {
    let worktreeID: String
    let path: String
    let url: URL
    var fileSource: DispatchSourceFileSystemObject?
    var directorySource: DispatchSourceFileSystemObject?
    /// The hash last published or read at follow time; nil when there is no file.
    var contentHash: String?
    var probing: Task<Void, Never>?
    var isDirty = false

    init(worktreeID: String, path: String, url: URL) {
        self.worktreeID = worktreeID
        self.path = path
        self.url = url
    }

    func stop() {
        fileSource?.cancel()
        directorySource?.cancel()
        fileSource = nil
        directorySource = nil
    }
}
