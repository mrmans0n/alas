import Foundation

public struct GGUndoMarker: Codable, Equatable, Sendable {
    public let operationID: String
    public let removedFinalStackCommit: Bool
    /// Branch the recovery was recorded on. Used to scope a final-drop
    /// recovery (where the stack becomes empty, so `currentStackName` is nil)
    /// to the branch where the drop happened. Optional for backward
    /// compatibility with markers persisted before this field existed.
    public let branch: String?

    public init(operationID: String, removedFinalStackCommit: Bool = false, branch: String? = nil) {
        self.operationID = operationID
        self.removedFinalStackCommit = removedFinalStackCommit
        self.branch = branch
    }
}

public protocol GGUndoMarkerStoring: Sendable {
    func marker(worktreeId: String) -> GGUndoMarker?
    func set(_ marker: GGUndoMarker, worktreeId: String)
    func clear(worktreeId: String)
}

extension GGUndoMarkerStoring {
    public func set(operationID: String, worktreeId: String) {
        set(GGUndoMarker(operationID: operationID), worktreeId: worktreeId)
    }
}

public final class GGUndoMarkerStore: GGUndoMarkerStoring, @unchecked Sendable {
    public static let defaultsKey = "gg.undoMarkersByWorktree"
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = AlasProfile.userDefaults) {
        self.defaults = defaults
    }

    public func marker(worktreeId: String) -> GGUndoMarker? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return markers()[worktreeId]
    }

    public func set(_ marker: GGUndoMarker, worktreeId: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var values = markers()
        values[worktreeId] = marker
        persist(values)
    }

    public func clear(worktreeId: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var values = markers()
        guard values.removeValue(forKey: worktreeId) != nil else { return }
        persist(values)
    }

    private func markers() -> [String: GGUndoMarker] {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let markers = try? JSONDecoder().decode([String: GGUndoMarker].self, from: data) {
            return markers
        }
        let legacy = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        return legacy.mapValues { GGUndoMarker(operationID: $0) }
    }

    private func persist(_ markers: [String: GGUndoMarker]) {
        guard let data = try? JSONEncoder().encode(markers) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
