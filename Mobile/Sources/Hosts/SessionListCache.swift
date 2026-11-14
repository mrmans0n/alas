import AlasRemoteKit
import Foundation

/// Last session list per host, one JSON file each, so a cold start shows
/// sessions before any host connects. Writes run off the main actor and
/// coalesce: a list that arrives while one is waiting replaces it.
actor SessionListCache {
    private let directory: URL
    private var pending: [UUID: [RemoteSessionSummary]] = [:]
    /// Highest sequence number seen per host. Detached callers reach the actor
    /// in any order, so anything older than this (a late list, or a save
    /// arriving after `delete`) is dropped.
    private var newest: [UUID: Int] = [:]

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "session-lists")) {
        self.directory = directory
    }

    /// Synchronous so `HostHub.init` can fill its lists before the first frame.
    nonisolated func load(_ id: UUID) -> [RemoteSessionSummary]? {
        let url = fileURL(id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode([RemoteSessionSummary].self, from: data)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func save(_ list: [RemoteSessionSummary], for id: UUID, seq: Int) async {
        guard seq > newest[id, default: 0] else { return }
        newest[id] = seq
        let alreadyQueued = pending[id] != nil
        pending[id] = list
        guard !alreadyQueued else { return }
        // Yield so lists arriving in a burst replace the pending one.
        await Task.yield()
        guard let newest = pending.removeValue(forKey: id) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(newest).write(to: fileURL(id), options: .atomic)
    }

    func delete(_ id: UUID, seq: Int) {
        guard seq > newest[id, default: 0] else { return }
        newest[id] = seq
        pending[id] = nil
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    private nonisolated func fileURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
