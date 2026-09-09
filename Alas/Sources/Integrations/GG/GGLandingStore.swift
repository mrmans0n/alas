import Foundation
import Observation

enum GGLandingPhase: Equatable, Sendable {
    case running, cancelling, cancelled, succeeded, failed
}

struct GGLandingRow: Equatable, Identifiable, Sendable {
    let position: Int
    let title: String
    let ggId: String?
    let prNumber: Int?
    var wait: GGLandWait? = nil
    var outcome: GGLandedEntry? = nil

    var id: Int { position }
}

struct GGLandingSession: Equatable, Identifiable, Sendable {
    struct Seed: Sendable {
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
    let startedAt: Date
    var rows: [GGLandingRow]
    var phase: GGLandingPhase
    var activeWait: GGLandWait?
    var warning: String?
    var result: GGLandResult?
    var error: String?
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

    @discardableResult
    func begin(_ seed: GGLandingSession.Seed, now: Date = Date()) -> Bool {
        guard operations[seed.projectId] == nil else { return false }
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
            startedAt: now,
            rows: seed.rows,
            phase: .running,
            activeWait: nil,
            warning: nil,
            result: nil,
            error: nil
        )
        return true
    }

    func receive(_ event: GGLandEvent, projectId: String) {
        guard var session = sessions[projectId],
              session.phase == .running || session.phase == .cancelling
        else { return }

        switch event {
        case .start:
            break

        case .wait(let wait):
            session.activeWait = wait
            session.warning = wait.error
            if let index = session.rows.firstIndex(where: { $0.position == wait.position }) {
                session.rows[index].wait = wait
            }

        case .entry(let entry):
            if let index = session.rows.firstIndex(where: { $0.position == entry.position }) {
                session.rows[index].wait = nil
                session.rows[index].outcome = entry
            }
            if session.activeWait?.position == entry.position {
                session.activeWait = nil
                session.warning = nil
            }

        case .summary(let result):
            session.result = result
            session.activeWait = nil
            session.warning = nil
            for entry in result.landed {
                if let index = session.rows.firstIndex(where: { $0.position == entry.position }) {
                    session.rows[index].wait = nil
                    session.rows[index].outcome = entry
                }
            }
            if session.phase == .running {
                session.phase = result.error == nil ? .succeeded : .failed
                session.error = result.error
            }

        case .error(let message):
            if session.phase == .running {
                session.phase = .failed
                session.activeWait = nil
                session.warning = nil
                session.error = message
            }
        }

        sessions[projectId] = session
    }

    func attach(
        projectId: String,
        task: Task<Void, Error>,
        cancel: @escaping @MainActor () -> Void
    ) {
        guard let session = sessions[projectId],
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
        let activeOperations = operations
        for projectId in activeOperations.keys {
            if sessions[projectId]?.phase == .running {
                sessions[projectId]?.phase = .cancelling
            }
            requestCancellation(projectId: projectId)
        }
        for operation in activeOperations.values {
            await operation.monitor.value
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
        guard var operation = operations[projectId], !operation.cancellationRequested else { return }
        operation.cancellationRequested = true
        operations[projectId] = operation
        operation.cancel()
    }
}
