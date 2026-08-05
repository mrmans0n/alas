import Foundation

@MainActor
final class MissionCoordinator {
    struct MissionOperationFailure: Error, Equatable, Sendable {
        let message: String
        var consumedInitialPrompt = false

        init(message: String, consumedInitialPrompt: Bool = false) {
            self.message = message
            self.consumedInitialPrompt = consumedInitialPrompt
        }
    }

    struct Environment {
        let persistence: MissionPersistence
        let now: () -> Date
        let makeID: () -> String
        let plannedWorktreeID: (MissionLeg) async -> Result<String, WorktreeCreationFailure>
        let worktreeAtDestination: (String, String) -> Worktree?
        let createWorktree: (MissionLeg) async -> Result<Worktree, WorktreeCreationFailure>
        let startACP: (MissionLeg, Worktree) async -> Result<ACPSession.ID, MissionOperationFailure>
        let notifyChanged: (MissionAggregate) -> Void
        let didCreateWorktree: (MissionID) -> Void
        let reportFailure: (MissionID?, String) -> Void

        init(
            persistence: MissionPersistence,
            now: @escaping () -> Date,
            makeID: @escaping () -> String,
            plannedWorktreeID: @escaping (MissionLeg) async -> Result<String, WorktreeCreationFailure> = { leg in
                .success(Worktree.makeId(path: URL(fileURLWithPath: leg.destinationPath)))
            },
            worktreeAtDestination: @escaping (String, String) -> Worktree?,
            createWorktree: @escaping (MissionLeg) async -> Result<Worktree, WorktreeCreationFailure>,
            startACP: @escaping (MissionLeg, Worktree) async -> Result<ACPSession.ID, MissionOperationFailure>,
            notifyChanged: @escaping (MissionAggregate) -> Void,
            didCreateWorktree: @escaping (MissionID) -> Void = { _ in },
            reportFailure: @escaping (MissionID?, String) -> Void = { _, _ in }
        ) {
            self.persistence = persistence
            self.now = now
            self.makeID = makeID
            self.plannedWorktreeID = plannedWorktreeID
            self.worktreeAtDestination = worktreeAtDestination
            self.createWorktree = createWorktree
            self.startACP = startACP
            self.notifyChanged = notifyChanged
            self.didCreateWorktree = didCreateWorktree
            self.reportFailure = reportFailure
        }
    }

    private let environment: Environment
    private let legCoordinator: MissionLegCoordinator
    private var addingLegs: Set<MissionID> = []
    private var addLegWaiters: [MissionID: [CheckedContinuation<Void, Never>]] = [:]

    init(environment: Environment) {
        self.environment = environment
        legCoordinator = MissionLegCoordinator(environment: environment)
    }

    func create(_ draft: MissionDraft, allowDuplicate: Bool = false) async throws -> MissionID {
        let missionID = MissionID(rawValue: environment.makeID())
        let legID = MissionLegID(rawValue: environment.makeID())
        let now = environment.now()
        let initialLeg = MissionLeg(
            id: legID,
            missionID: missionID,
            ordinal: 0,
            projectId: draft.projectId,
            baseRef: draft.baseRef,
            baseRemoteName: draft.baseRemoteName,
            branch: draft.branch,
            destinationPath: draft.destinationPath,
            worktreeId: nil,
            agentId: draft.agentId,
            acpSessionId: nil,
            initialPromptId: draft.initialPromptId,
            preparedInitialPrompt: draft.initialPrompt,
            pendingInitialPrompt: draft.initialPrompt,
            reviewIdentity: nil,
            createdAt: now,
            updatedAt: now
        )
        let aggregate = MissionAggregate(
            mission: MissionRecord(
                id: missionID,
                title: draft.source.title,
                state: .creating,
                setupCheckpoint: .creatingWorktree,
                primaryLegID: legID,
                attentionReason: nil,
                createdAt: now,
                updatedAt: now,
                completedAt: nil
            ),
            source: draft.source,
            legs: [initialLeg],
            events: [event(
                missionID: missionID,
                legID: legID,
                kind: .created,
                message: "Mission created from work item.",
                at: now
            )]
        )

        try await environment.persistence.insert(aggregate, allowDuplicate: allowDuplicate)
        environment.notifyChanged(aggregate)
        Task { @MainActor [weak self] in
            await self?.legCoordinator.advance(missionID: missionID, legID: legID)
        }
        return missionID
    }

    func addLeg(missionID: MissionID, draft: MissionLegDraft) async throws -> MissionLegID {
        guard addingLegs.insert(missionID).inserted else {
            await withCheckedContinuation { continuation in
                addLegWaiters[missionID, default: []].append(continuation)
            }
            return try await addLeg(missionID: missionID, draft: draft)
        }
        defer {
            addingLegs.remove(missionID)
            let waiters = addLegWaiters.removeValue(forKey: missionID) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }

        guard let aggregate = try await environment.persistence.aggregate(id: missionID),
              aggregate.mission.state == .running
        else {
            throw MissionStore.Error.invalidLegCollection
        }
        let now = environment.now()
        let legID = MissionLegID(rawValue: environment.makeID())
        let leg = MissionLeg(
            id: legID,
            missionID: missionID,
            ordinal: aggregate.legs.count,
            projectId: draft.projectId,
            baseRef: draft.baseRef,
            baseRemoteName: draft.baseRemoteName,
            branch: draft.branch,
            destinationPath: draft.destinationPath,
            worktreeId: nil,
            agentId: draft.agentId,
            acpSessionId: nil,
            initialPromptId: draft.initialPromptId,
            preparedInitialPrompt: draft.preparedPrompt,
            pendingInitialPrompt: draft.preparedPrompt,
            reviewIdentity: nil,
            createdAt: now,
            updatedAt: now
        )
        let addedEvent = event(
            missionID: missionID,
            legID: legID,
            kind: .legAdded,
            message: "Mission leg added for \(draft.branch).",
            at: now
        )
        try await environment.persistence.addLeg(leg, event: addedEvent)
        if let changed = try await environment.persistence.aggregate(id: missionID) {
            environment.notifyChanged(changed)
        }
        Task { @MainActor [weak self] in
            await self?.legCoordinator.advance(missionID: missionID, legID: legID)
        }
        return legID
    }

    func advance(id: MissionID) async {
        do {
            guard let aggregate = try await environment.persistence.aggregate(id: id) else { return }
            await legCoordinator.advance(missionID: id, legID: aggregate.mission.primaryLegID)
        } catch {
            reportPersistenceFailure(id: id, operation: "load Mission setup progress", error: error)
        }
    }

    func advance(id: MissionID, legID: MissionLegID) async {
        await legCoordinator.advance(missionID: id, legID: legID)
    }

    func retry(id: MissionID, recreateWorktree: Bool = false) async {
        do {
            guard let aggregate = try await environment.persistence.aggregate(id: id) else { return }
            await retry(id: id, legID: aggregate.mission.primaryLegID, recreateWorktree: recreateWorktree)
        } catch {
            reportPersistenceFailure(id: id, operation: "load Mission setup progress", error: error)
        }
    }

    func retry(id: MissionID, legID: MissionLegID, recreateWorktree: Bool = false) async {
        await legCoordinator.retry(
            missionID: id,
            legID: legID,
            recreateWorktree: recreateWorktree
        )
    }

    func reconcileInterrupted() async {
        await legCoordinator.reconcileInterrupted()
    }

    private func event(
        missionID: MissionID,
        legID: MissionLegID,
        kind: MissionEventKind,
        message: String,
        at: Date
    ) -> MissionEvent {
        MissionEvent(
            id: environment.makeID(),
            missionID: missionID,
            legID: legID,
            kind: kind,
            message: message,
            createdAt: at
        )
    }

    private func reportPersistenceFailure(id: MissionID?, operation: String, error: Error) {
        environment.reportFailure(id, "Could not \(operation): \(error.localizedDescription)")
    }
}
