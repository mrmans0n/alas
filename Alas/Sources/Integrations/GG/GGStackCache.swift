import Foundation

/// Shares one `gg ls --json` per worktree across every followed tab until
/// the stack can have changed. `gg ls` can hit the forge for PR and CI
/// state, so a per-tab-per-refresh load is not affordable.
///
/// Invalidation is event-based, not time-based: `AppState` invalidates on
/// the same HEAD-update signal that clears `GGStackSummaryStore`, which is
/// what every gg mutation ultimately produces.
actor GGStackCache {
    static let shared = GGStackCache()

    private var generation = 0
    private var cached: [String: (generation: Int, task: Task<GGStack?, any Error>)] = [:]

    init() {}

    func stack(
        at worktreePath: URL,
        load: @escaping @Sendable () async throws -> GGStack?
    ) async throws -> GGStack? {
        let key = worktreePath.standardizedFileURL.path
        if let entry = cached[key], entry.generation == generation {
            return try await entry.task.value
        }
        let currentGeneration = generation
        let task = Task { try await load() }
        cached[key] = (currentGeneration, task)
        do {
            return try await task.value
        } catch {
            // A failed load must not stick: the next refresh retries.
            if cached[key]?.generation == currentGeneration {
                cached[key] = nil
            }
            throw error
        }
    }

    func invalidate() {
        generation &+= 1
        cached.removeAll()
    }
}
