import Foundation
import Observation

enum GGLandingPhase: Equatable, Sendable {
    case running, cancelling, cancelled, succeeded, failed
}

struct GGLandingRow: Equatable, Identifiable, Sendable {
    let position: Int
    let title: String
    let ggId: String?
    var stableID: String? = nil
    let prNumber: Int?
    var wait: GGLandWait? = nil
    var outcome: GGLandedEntry? = nil

    var id: Int { position }
}

struct GGLandingSession: Equatable, Identifiable, Sendable {
    struct Seed: Equatable, Sendable {
        let projectId: String
        let worktreeId: String
        let stack: String
        let base: String
        let target: String
        let rows: [GGLandingRow]
    }

    let id: UUID
    let projectId: String
    let worktreeId: String
    let stack: String
    let base: String
    let target: String
    let confirmedScope: Seed
    let startedAt: Date
    var rows: [GGLandingRow]
    var phase: GGLandingPhase
    var activeWait: GGLandWait?
    var warning: String?
    var result: GGLandResult?
    var error: String?
    var completedIDs: Set<String>
    var endedAt: Date? = nil
}

@MainActor
@Observable
final class GGLandingStore {
    private struct Operation {
        let id: UUID
        let monitor: Task<Void, Never>
        let cancel: @MainActor () -> Void
        var cancellationRequested = false
    }

    static let shared = GGLandingStore()

    private(set) var sessions: [String: GGLandingSession] = [:]
    @ObservationIgnored private var operations: [String: Operation] = [:]
    @ObservationIgnored private var preparations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var isCancellingAll = false

    @discardableResult
    func begin(
        _ seed: GGLandingSession.Seed,
        completedIDs: Set<String> = [],
        now: Date = Date()
    ) -> Bool {
        guard !isCancellingAll, operations[seed.projectId] == nil else { return false }
        if let session = sessions[seed.projectId],
           session.phase == .running || session.phase == .cancelling
        {
            return false
        }
        sessions[seed.projectId] = GGLandingSession(
            id: UUID(),
            projectId: seed.projectId,
            worktreeId: seed.worktreeId,
            stack: seed.stack,
            base: seed.base,
            target: seed.target,
            confirmedScope: seed,
            startedAt: now,
            rows: seed.rows,
            phase: .running,
            activeWait: nil,
            warning: nil,
            result: nil,
            error: nil,
            completedIDs: completedIDs
        )
        return true
    }

    func updatePendingRows(_ rows: [GGLandingRow], projectId: String) {
        guard sessions[projectId]?.phase == .running else { return }
        sessions[projectId]?.rows = rows
    }

    @discardableResult
    func receive(_ event: GGLandEvent, projectId: String) -> Bool {
        guard var session = sessions[projectId] else { return true }
        let streamFailedAfterSummary: Bool
        if case .error = event {
            streamFailedAfterSummary = session.phase == .succeeded && operations[projectId] != nil
        } else {
            streamFailedAfterSummary = false
        }
        guard session.phase == .running || session.phase == .cancelling || streamFailedAfterSummary
        else { return true }

        switch event {
        case .start(let stack, let base, let totalEntries):
            guard stack == session.confirmedScope.stack,
                  base == session.confirmedScope.base,
                  totalEntries == session.rows.count
            else {
                session.phase = .failed
                session.activeWait = nil
                session.warning = nil
                session.error = "gg land started for a different stack. Refresh and try again."
                session.endedAt = Date()
                sessions[projectId] = session
                return false
            }

        case .wait(let wait):
            guard let index = session.rows.firstIndex(where: { $0.position == wait.position }),
                  Self.row(session.rows[index], matches: wait)
            else {
                Self.rejectStreamMismatch(&session)
                sessions[projectId] = session
                return false
            }
            session.activeWait = wait
            session.warning = wait.error
            session.rows[index].wait = wait

        case .entry(let entry):
            guard let index = session.rows.firstIndex(where: { $0.position == entry.position }),
                  Self.row(session.rows[index], matches: entry)
            else {
                Self.rejectStreamMismatch(&session)
                sessions[projectId] = session
                return false
            }
            session.rows[index].wait = nil
            session.rows[index].outcome = entry
            if entry.error == nil, let id = Self.completedID(for: session.rows[index]) {
                session.completedIDs.insert(id)
            }
            if session.activeWait?.position == entry.position {
                session.activeWait = nil
                session.warning = nil
            }

        case .summary(let result):
            for entry in result.landed {
                guard let index = session.rows.firstIndex(where: { $0.position == entry.position }),
                      Self.row(session.rows[index], matches: entry)
                else {
                    Self.rejectStreamMismatch(&session)
                    sessions[projectId] = session
                    return false
                }
            }
            session.result = result
            session.activeWait = nil
            session.warning = nil
            for entry in result.landed {
                if let index = session.rows.firstIndex(where: { $0.position == entry.position }) {
                    session.rows[index].wait = nil
                    session.rows[index].outcome = entry
                    if let id = Self.completedID(for: session.rows[index]) {
                        if entry.error == nil {
                            session.completedIDs.insert(id)
                        } else {
                            session.completedIDs.remove(id)
                        }
                    }
                }
            }
            if session.phase == .running {
                session.phase = result.error == nil ? .succeeded : .failed
                session.error = result.error
            }

        case .error(let message):
            if session.phase != .cancelling {
                session.phase = .failed
                session.activeWait = nil
                session.warning = nil
                session.error = message
            }
        }

        if session.phase == .succeeded || session.phase == .failed {
            session.endedAt = Date()
        }
        sessions[projectId] = session
        return true
    }

    private static func completedID(for row: GGLandingRow) -> String? {
        row.stableID ?? row.ggId
    }

    private static func rejectStreamMismatch(_ session: inout GGLandingSession) {
        session.phase = .failed
        session.activeWait = nil
        session.warning = nil
        session.error = "gg land reported progress for a different stack. Refresh and try again."
        session.endedAt = Date()
    }

    private static func row(_ row: GGLandingRow, matches wait: GGLandWait) -> Bool {
        row.prNumber == nil || row.prNumber == wait.prNumber
    }

    private static func row(_ row: GGLandingRow, matches entry: GGLandedEntry) -> Bool {
        if let prNumber = row.prNumber, prNumber != entry.prNumber { return false }
        if let ggId = entry.ggId, ggId != row.stableID, ggId != row.ggId { return false }
        if row.ggId == nil, row.prNumber == nil, entry.sha != row.stableID { return false }
        return true
    }

    func attach(
        projectId: String,
        task: Task<Void, Error>,
        cancel: @escaping @MainActor () -> Void
    ) {
        guard !isCancellingAll, let session = sessions[projectId],
              session.phase == .running || session.phase == .cancelling,
              operations[projectId] == nil
        else {
            cancel()
            return
        }

        let sessionId = session.id
        let operationId = UUID()
        let monitor = Task { @MainActor [weak self] in
            let result = await task.result
            guard let self, self.operations[projectId]?.id == operationId else { return }
            self.operations[projectId] = nil
            guard self.sessions[projectId]?.id == sessionId else { return }

            guard let phase = self.sessions[projectId]?.phase else { return }
            if phase == .cancelling {
                self.sessions[projectId]?.phase = .cancelled
                self.sessions[projectId]?.endedAt = Date()
                self.sessions[projectId]?.activeWait = nil
                self.sessions[projectId]?.warning = nil
                self.sessions[projectId]?.error = nil
            } else if phase == .running {
                switch result {
                case .success:
                    self.fail(projectId: projectId, message: "gg land ended without a summary.")
                case .failure(let error):
                    self.fail(projectId: projectId, message: GGErrorPresentation.message(for: error))
                }
            }
        }
        operations[projectId] = Operation(id: operationId, monitor: monitor, cancel: cancel)
        if session.phase == .cancelling {
            requestCancellation(projectId: projectId)
        }
    }

    func cancel(projectId: String) {
        guard var session = sessions[projectId], session.phase == .running else { return }
        session.phase = .cancelling
        sessions[projectId] = session
        requestCancellation(projectId: projectId)
    }

    func cancelAllAndWait() async {
        isCancellingAll = true
        defer { isCancellingAll = false }
        let activeOperations = operations
        let activePreparations = preparations
        for projectId in Set(activeOperations.keys).union(activePreparations.keys) {
            if sessions[projectId]?.phase == .running {
                sessions[projectId]?.phase = .cancelling
            }
            requestCancellation(projectId: projectId)
        }
        for operation in activeOperations.values {
            await operation.monitor.value
        }
        for preparation in activePreparations.values {
            await preparation.value
        }
    }

    func startPreparation(projectId: String, operation: @escaping @MainActor () async -> Void) {
        guard !isCancellingAll, preparations[projectId] == nil else { return }
        preparations[projectId] = Task { @MainActor in
            defer { preparations[projectId] = nil }
            await operation()
        }
    }

    func waitForOperation(projectId: String) async {
        await operations[projectId]?.monitor.value
    }

    func fail(projectId: String, message: String) {
        guard var session = sessions[projectId],
              session.phase == .running || (session.phase == .cancelling && operations[projectId] == nil)
        else { return }
        session.phase = session.phase == .cancelling ? .cancelled : .failed
        session.activeWait = nil
        session.warning = nil
        session.error = session.phase == .cancelled ? nil : message
        session.endedAt = Date()
        sessions[projectId] = session
    }

    func prune(keepingProjectIds: Set<String>) {
        let removedProjectIds = sessions.keys.filter { !keepingProjectIds.contains($0) }
        for projectId in removedProjectIds {
            requestCancellation(projectId: projectId)
            sessions[projectId] = nil
        }
    }

    private func requestCancellation(projectId: String) {
        preparations[projectId]?.cancel()
        guard var operation = operations[projectId], !operation.cancellationRequested else { return }
        operation.cancellationRequested = true
        operations[projectId] = operation
        operation.cancel()
    }
}
