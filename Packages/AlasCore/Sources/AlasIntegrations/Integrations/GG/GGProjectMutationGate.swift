import Foundation

/// Serializes native and plugin mutations across every worktree of a project.
/// Closing an owner prevents new work, but does not release processes still settling.
@MainActor
public final class GGProjectMutationGate {
    public static let shared = GGProjectMutationGate()

    private struct Reservation {
        let owner: String
        let token: String
        var closing = false
        var problem: String?
    }
    private struct ProcessOwner {
        let project: String
        let owner: String
    }
    private var reservations: [String: Reservation] = [:]
    private var processes: [UUID: ProcessOwner] = [:]
    private var revisions: [String: UInt64] = [:]

    public init() {}

    public func isBusy(project: String) -> Bool { reservations[project] != nil }
    public func revision(project: String) -> UInt64 { revisions[project, default: 0] }
    public func problem(project: String) -> String? { reservations[project]?.problem }
    public func markUnknown(project: String, owner: String, reason: String) {
        guard reservations[project]?.owner == owner else { return }
        reservations[project]?.problem = reason
        invalidate(project: project)
    }
    public func invalidate(project: String) { revisions[project, default: 0] &+= 1 }

    public func acquire(project: String, owner: String) -> String? {
        guard reservations[project] == nil else { return nil }
        let token = UUID().uuidString
        reservations[project] = Reservation(owner: owner, token: token)
        invalidate(project: project)
        return token
    }

    @discardableResult
    public func release(project: String, owner: String, token: String) -> Bool {
        guard let current = reservations[project], current.owner == owner,
              current.token == token, !current.closing else { return false }
        close(project: project, owner: owner)
        return true
    }

    public func endOwner(project: String, owner: String) {
        guard reservations[project]?.owner == owner else { return }
        close(project: project, owner: owner)
    }

    /// Register before launching, including before awaiting a remote process start.
    public func beginProcess(project: String, owner: String) -> UUID? {
        if let reservation = reservations[project], reservation.owner == owner, reservation.closing { return nil }
        let ticket = UUID()
        processes[ticket] = ProcessOwner(project: project, owner: owner)
        return ticket
    }

    public func endProcess(_ ticket: UUID) {
        guard let process = processes.removeValue(forKey: ticket),
              let reservation = reservations[process.project],
              reservation.owner == process.owner else { return }
        if !processes.values.contains(where: { $0.project == process.project && $0.owner == process.owner }), reservation.problem != nil {
            reservations[process.project]?.problem = nil
            invalidate(project: process.project)
        }
        if reservation.closing { finishClosing(project: process.project, owner: process.owner) }
    }

    private func close(project: String, owner: String) {
        reservations[project]?.closing = true
        finishClosing(project: project, owner: owner)
    }

    private func finishClosing(project: String, owner: String) {
        guard !processes.values.contains(where: { $0.project == project && $0.owner == owner }) else { return }
        reservations[project] = nil
        invalidate(project: project)
    }
}
