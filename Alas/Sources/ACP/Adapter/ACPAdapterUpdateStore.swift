import Foundation

/// Per-`agentID` store for ACP adapter update checks.
///
/// Owns three things:
///   1. TTL-cached results of the last version check (success = 24h, failure = 30m).
///   2. Per-agent dismissal of a specific `latest` version (banner stays hidden
///      until npm publishes something newer than the dismissed version).
///   3. Coalescing of concurrent in-flight version checks per `agentID`.
///
/// Backed by a small JSON file under Application Support.
actor ACPAdapterUpdateStore {
    struct Entry: Codable, Equatable {
        var checkedAt: Date
        var state: AdapterUpdateState
        var dismissedLatest: String?
    }

    private struct DiskShape: Codable {
        var entries: [String: Entry]
    }

    private let fileURL: URL
    private let successTTL: TimeInterval
    private let failureTTL: TimeInterval
    private let now: @Sendable () -> Date

    private var entries: [String: Entry]
    private var inFlight: [String: Task<AdapterUpdateState, Never>] = [:]
    private var loaded = false

    init(
        fileURL: URL = Paths.acpAdapterUpdatesFile,
        successTTL: TimeInterval = 24 * 60 * 60,
        failureTTL: TimeInterval = 30 * 60,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.successTTL = successTTL
        self.failureTTL = failureTTL
        self.now = now
        self.entries = [:]
    }

    // MARK: - Public API

    func read(agentID: String) -> AdapterUpdateState? {
        loadIfNeeded()
        guard let entry = entries[agentID] else { return nil }
        let ttl: TimeInterval = (entry.state == .unknown) ? failureTTL : successTTL
        if now().timeIntervalSince(entry.checkedAt) > ttl { return nil }
        return entry.state
    }

    func write(agentID: String, state: AdapterUpdateState) {
        loadIfNeeded()
        let timestamp = now()
        var entry = entries[agentID] ?? Entry(checkedAt: timestamp, state: state, dismissedLatest: nil)
        entry.checkedAt = timestamp
        entry.state = state
        entries[agentID] = entry
        persist()
    }

    func dismiss(agentID: String, latest: String) {
        loadIfNeeded()
        var entry = entries[agentID] ?? Entry(checkedAt: now(), state: .unknown, dismissedLatest: nil)
        entry.dismissedLatest = latest
        entries[agentID] = entry
        persist()
    }

    func isDismissed(agentID: String, latest: String) -> Bool {
        loadIfNeeded()
        return entries[agentID]?.dismissedLatest == latest
    }

    func clear(agentID: String) {
        loadIfNeeded()
        entries.removeValue(forKey: agentID)
        persist()
    }

    /// Returns the cached state if fresh; otherwise runs `compute`, stores
    /// the result, and returns it. Concurrent callers for the same
    /// `agentID` share one in-flight task.
    func checkOrCompute(
        agentID: String,
        compute: @Sendable @escaping () async -> AdapterUpdateState
    ) async -> AdapterUpdateState {
        if let cached = read(agentID: agentID) { return cached }
        if let existing = inFlight[agentID] { return await existing.value }

        let task = Task { @Sendable in await compute() }
        inFlight[agentID] = task
        let result = await task.value
        // removeValue and write run in one synchronous actor turn — no suspension between them,
        // so a third caller cannot observe a state where inFlight is empty and the cache is stale.
        inFlight.removeValue(forKey: agentID)
        write(agentID: agentID, state: result)
        return result
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let shape = try? JSONDecoder.iso8601.decode(DiskShape.self, from: data)
        else { return }
        entries = shape.entries
    }

    private func persist() {
        let shape = DiskShape(entries: entries)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder.iso8601.encode(shape)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence is best-effort. In-memory state remains correct.
        }
    }
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
