import Foundation
import Observation

@Observable
@MainActor
final class MissionController {
    private(set) var aggregates: [MissionAggregate] = []
    private(set) var loadError: String?

    @ObservationIgnored
    private let persistence: MissionPersistence
    @ObservationIgnored
    private let environment: MissionCoordinator.Environment
    @ObservationIgnored
    private lazy var coordinator = MissionCoordinator(environment: .init(
        persistence: environment.persistence,
        now: environment.now,
        makeID: environment.makeID,
        worktreeAtDestination: environment.worktreeAtDestination,
        createWorktree: environment.createWorktree,
        startACP: environment.startACP,
        notifyChanged: { [weak self] aggregate in
            self?.environment.notifyChanged(aggregate)
            self?.replace(aggregate)
        }
    ))

    init(environment: MissionCoordinator.Environment) {
        persistence = environment.persistence
        self.environment = environment
    }

    func load() async {
        do {
            aggregates = Self.sorted(try await persistence.list(includeCompleted: true))
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func create(_ draft: MissionDraft, allowDuplicate: Bool) async throws -> MissionID {
        let id = try await coordinator.create(draft, allowDuplicate: allowDuplicate)
        loadError = nil
        return id
    }

    func retry(_ id: MissionID, agentId: String? = nil) async {
        do {
            if let agentId,
               var aggregate = try await persistence.aggregate(id: id),
               aggregate.mission.state == .needsAttention,
               aggregate.mission.setupCheckpoint == .startingAgent,
               var leg = aggregate.primaryLeg {
                leg.agentId = agentId
                try await persistence.updateLeg(leg, event: nil)
                aggregate.legs = [leg]
                environment.notifyChanged(aggregate)
                replace(aggregate)
            }
            await coordinator.retry(id: id)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reconcileInterrupted() async {
        await coordinator.reconcileInterrupted()
    }

    func aggregate(id: MissionID) -> MissionAggregate? {
        aggregates.first { $0.mission.id == id }
    }

    private func replace(_ aggregate: MissionAggregate) {
        if let index = aggregates.firstIndex(where: { $0.mission.id == aggregate.mission.id }) {
            aggregates[index] = aggregate
        } else {
            aggregates.append(aggregate)
        }
        aggregates = Self.sorted(aggregates)
    }

    private static func sorted(_ aggregates: [MissionAggregate]) -> [MissionAggregate] {
        aggregates.sorted { lhs, rhs in
            let lhsCompleted = lhs.mission.state == .completed
            let rhsCompleted = rhs.mission.state == .completed
            if lhsCompleted != rhsCompleted { return !lhsCompleted }
            if lhs.mission.updatedAt != rhs.mission.updatedAt {
                return lhs.mission.updatedAt > rhs.mission.updatedAt
            }
            return lhs.mission.id.rawValue < rhs.mission.id.rawValue
        }
    }
}
