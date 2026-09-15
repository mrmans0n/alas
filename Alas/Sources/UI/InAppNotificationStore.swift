import Foundation
import Observation

enum InAppNotificationSeverity: Equatable {
    case success, error, information, progress

    var duration: TimeInterval? {
        switch self {
        case .success, .information: 4
        case .error: 8
        case .progress: nil
        }
    }
}

/// Transient feedback for local actions. Never forwards to the attention inbox or macOS.
@MainActor @Observable
final class InAppNotificationStore {
    struct Entry: Identifiable {
        let id: UUID
        let worktreeID: String
        let message: String
        let severity: InAppNotificationSeverity
        var expiresAt: Date?
        var pausedAt: Date?
        let cancel: (() -> Void)?
    }

    private(set) var entries: [Entry] = []

    @discardableResult
    func post(_ message: String, severity: InAppNotificationSeverity, worktreeID: String,
              now: Date = Date(), cancel: (() -> Void)? = nil) -> UUID {
        expire(now: now)
        let id = UUID()
        entries.append(Entry(id: id, worktreeID: worktreeID, message: message, severity: severity,
                             expiresAt: severity.duration.map { now.addingTimeInterval($0) }, cancel: cancel))
        // Bound bursts without evicting active operations or persistent run failures.
        let completed = entries.filter { $0.worktreeID == worktreeID && $0.severity != .progress }
        for entry in completed.dropLast(5) { dismiss(entry.id) }
        return id
    }

    func notifications(in worktreeID: String) -> [Entry] {
        entries.filter { $0.worktreeID == worktreeID }
    }

    func dismiss(_ id: UUID) { entries.removeAll { $0.id == id } }

    func cancel(_ id: UUID) {
        let action = entries.first { $0.id == id }?.cancel
        dismiss(id)
        action?()
    }

    func remove(worktreeID: String) {
        let ids = notifications(in: worktreeID).map(\.id)
        for id in ids { cancel(id) }
    }

    func setPaused(_ paused: Bool, id: UUID, now: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if paused {
            if entries[index].pausedAt == nil { entries[index].pausedAt = now }
        } else if let start = entries[index].pausedAt {
            entries[index].expiresAt = entries[index].expiresAt?.addingTimeInterval(now.timeIntervalSince(start))
            entries[index].pausedAt = nil
        }
    }

    func expire(now: Date = Date()) {
        let expired = entries.filter { $0.pausedAt == nil && $0.expiresAt.map { $0 <= now } == true }.map(\.id)
        guard !expired.isEmpty else { return }
        entries.removeAll { expired.contains($0.id) }
    }
}
