import Foundation

final class HookWatcher {
    var onEvent: ((HookEvent) -> Void)?
    private let dir: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "io.nlopez.alas.hook-watcher")
    private var seenFiles: Set<String> = []

    init(dir: URL) { self.dir = dir }

    func start() {
        try? Paths.ensureDirectoryExists(dir)
        try? Paths.ensureDirectoryExists(dir.appendingPathComponent("processed"))
        let path = dir.path
        fd = open(path, O_EVTONLY)
        guard fd != -1 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd != -1 { close(fd) }
            self?.fd = -1
        }
        s.resume()
        source = s
        // Initial scan in case files were left over from a previous run.
        scan()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }

    private func scan() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.pathExtension == "json" {
            if seenFiles.contains(entry.lastPathComponent) { continue }
            seenFiles.insert(entry.lastPathComponent)
            guard let data = try? Data(contentsOf: entry) else { continue }
            guard let event = try? HookEvent.decode(data) else { continue }
            DispatchQueue.main.async { self.onEvent?(event) }
            // Move processed file aside
            let processed = dir.appendingPathComponent("processed").appendingPathComponent(entry.lastPathComponent)
            try? FileManager.default.moveItem(at: entry, to: processed)
            // Trim processed/ to last 100 entries
            trimProcessed()
        }
    }

    private func trimProcessed() {
        let processedDir = dir.appendingPathComponent("processed")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: processedDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        if entries.count <= 100 { return }
        let sorted = entries.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast)
        }
        for url in sorted.prefix(sorted.count - 100) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
