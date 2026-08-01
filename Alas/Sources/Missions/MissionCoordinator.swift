import Foundation

@MainActor
final class MissionCoordinator {
    struct MissionOperationFailure: Error, Equatable, Sendable {
        let message: String
    }

    struct Environment {
        let persistence: MissionPersistence
        let now: () -> Date
        let makeID: () -> String
        let worktreeAtDestination: (String, String) -> Worktree?
        let createWorktree: (MissionLeg) async -> Result<Worktree, WorktreeCreationFailure>
        let startACP: (MissionLeg, Worktree) async -> Result<ACPSession.ID, MissionOperationFailure>
        let notifyChanged: (MissionAggregate) -> Void
    }

    private let environment: Environment
    private var advancing: Set<MissionID> = []
    private var advanceWaiters: [MissionID: [CheckedContinuation<Void, Never>]] = [:]

    init(environment: Environment) {
        self.environment = environment
    }

    func create(_ draft: MissionDraft, allowDuplicate: Bool = false) async throws -> MissionID {
        let missionID = MissionID(rawValue: environment.makeID())
        let legID = MissionLegID(rawValue: environment.makeID())
        let now = environment.now()
        let aggregate = MissionAggregate(
            mission: MissionRecord(
                id: missionID,
                title: draft.issue.title,
                state: .creating,
                setupCheckpoint: .creatingWorktree,
                primaryLegID: legID,
                attentionReason: nil,
                createdAt: now,
                updatedAt: now,
                completedAt: nil
            ),
            issue: draft.issue,
            legs: [MissionLeg(
                id: legID,
                missionID: missionID,
                ordinal: 0,
                projectId: draft.projectId,
                baseRef: draft.baseRef,
                branch: draft.branch,
                destinationPath: draft.destinationPath,
                worktreeId: nil,
                agentId: draft.agentId,
                acpSessionId: nil,
                initialPromptId: draft.initialPromptId,
                pendingInitialPrompt: draft.initialPrompt,
                reviewIdentity: nil
            )],
            events: [event(
                missionID: missionID,
                legID: legID,
                kind: .created,
                message: "Mission created from issue #\(draft.issue.identity.number).",
                at: now
            )]
        )

        try await environment.persistence.insert(aggregate, allowDuplicate: allowDuplicate)
        environment.notifyChanged(aggregate)
        Task { @MainActor [weak self] in
            await self?.advance(id: missionID)
        }
        return missionID
    }

    func advance(id: MissionID) async {
        guard advancing.insert(id).inserted else {
            await withCheckedContinuation { continuation in
                advanceWaiters[id, default: []].append(continuation)
            }
            if let aggregate = try? await environment.persistence.aggregate(id: id),
               aggregate.mission.state == .creating {
                await advance(id: id)
            }
            return
        }
        await performAdvance(id: id)
        advancing.remove(id)
        let waiters = advanceWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func retry(id: MissionID) async {
        guard let aggregate = try? await environment.persistence.aggregate(id: id),
              aggregate.mission.state == .needsAttention
        else { return }
        let now = environment.now()
        let retryEvent = event(
            missionID: id,
            legID: aggregate.primaryLeg?.id,
            kind: .retryStarted,
            message: retryMessage(for: aggregate.mission.setupCheckpoint),
            at: now
        )
        do {
            try await environment.persistence.updateSetup(
                id: id,
                state: .creating,
                checkpoint: aggregate.mission.setupCheckpoint,
                attentionReason: nil,
                event: retryEvent
            )
            if let changed = try await environment.persistence.aggregate(id: id) {
                environment.notifyChanged(changed)
            }
        } catch {
            return
        }
        await advance(id: id)
    }

    func reconcileInterrupted() async {
        guard let unsettled = try? await environment.persistence.list(states: [.creating, .needsAttention]) else {
            return
        }

        for aggregate in unsettled where aggregate.mission.state == .needsAttention {
            await reconcileArtifacts(in: aggregate)
        }
        guard let creating = try? await environment.persistence.list(states: [.creating]) else { return }
        for aggregate in creating {
            await advance(id: aggregate.mission.id)
        }
    }

    private func performAdvance(id: MissionID) async {
        while let aggregate = try? await environment.persistence.aggregate(id: id),
              aggregate.mission.state == .creating {
            let didAdvance: Bool
            switch aggregate.mission.setupCheckpoint {
            case .creatingWorktree:
                didAdvance = await advanceWorktree(aggregate)
            case .startingAgent:
                didAdvance = await advanceAgent(aggregate)
            case .running:
                didAdvance = await settleRunning(aggregate)
            }
            if !didAdvance { return }
        }
    }

    private func advanceWorktree(_ aggregate: MissionAggregate) async -> Bool {
        guard var leg = aggregate.primaryLeg else { return false }
        let worktree: Worktree
        if let existing = environment.worktreeAtDestination(leg.projectId, leg.destinationPath) {
            worktree = existing
        } else {
            switch await environment.createWorktree(leg) {
            case .success(let created):
                worktree = created
            case .failure(let failure):
                await persistFailure(
                    aggregate: aggregate,
                    checkpoint: .creatingWorktree,
                    message: failure.message
                )
                return false
            }
        }

        leg.worktreeId = worktree.id
        let now = environment.now()
        let checkpointEvent = event(
            missionID: aggregate.mission.id,
            legID: leg.id,
            kind: .worktreeCreated,
            message: "Worktree created for \(leg.branch).",
            at: now
        )
        do {
            try await environment.persistence.updateSetup(
                id: aggregate.mission.id,
                leg: leg,
                state: .creating,
                checkpoint: .startingAgent,
                attentionReason: nil,
                event: checkpointEvent
            )
            await notify(id: aggregate.mission.id)
            return true
        } catch {
            return false
        }
    }

    private func advanceAgent(_ aggregate: MissionAggregate) async -> Bool {
        guard var leg = aggregate.primaryLeg else { return false }
        guard let worktree = environment.worktreeAtDestination(leg.projectId, leg.destinationPath) else {
            await persistFailure(
                aggregate: aggregate,
                checkpoint: .startingAgent,
                message: "The Mission worktree is no longer available."
            )
            return false
        }

        if leg.worktreeId != worktree.id {
            leg.worktreeId = worktree.id
            do {
                try await environment.persistence.updateLeg(leg, event: nil)
                await notify(id: aggregate.mission.id)
            } catch {
                return false
            }
        }
        if leg.acpSessionId == nil {
            leg.acpSessionId = environment.makeID()
            do {
                try await environment.persistence.updateLeg(leg, event: nil)
                await notify(id: aggregate.mission.id)
            } catch {
                return false
            }
        }

        switch await environment.startACP(leg, worktree) {
        case .success:
            leg.pendingInitialPrompt = nil
            let now = environment.now()
            let checkpointEvent = event(
                missionID: aggregate.mission.id,
                legID: leg.id,
                kind: .agentStarted,
                message: "Agent started in the Mission worktree.",
                at: now
            )
            do {
                try await environment.persistence.updateSetup(
                    id: aggregate.mission.id,
                    leg: leg,
                    state: .running,
                    checkpoint: .running,
                    attentionReason: nil,
                    event: checkpointEvent
                )
                await notify(id: aggregate.mission.id)
                return true
            } catch {
                return false
            }
        case .failure(let failure):
            await persistFailure(
                aggregate: aggregate,
                checkpoint: .startingAgent,
                message: failure.message
            )
            return false
        }
    }

    private func settleRunning(_ aggregate: MissionAggregate) async -> Bool {
        let now = environment.now()
        let checkpointEvent = event(
            missionID: aggregate.mission.id,
            legID: aggregate.primaryLeg?.id,
            kind: .agentStarted,
            message: "Mission setup completed.",
            at: now
        )
        do {
            try await environment.persistence.updateSetup(
                id: aggregate.mission.id,
                state: .running,
                checkpoint: .running,
                attentionReason: nil,
                event: checkpointEvent
            )
            await notify(id: aggregate.mission.id)
            return true
        } catch {
            return false
        }
    }

    private func reconcileArtifacts(in aggregate: MissionAggregate) async {
        guard aggregate.mission.setupCheckpoint == .creatingWorktree,
              var leg = aggregate.primaryLeg,
              leg.worktreeId == nil,
              let worktree = environment.worktreeAtDestination(leg.projectId, leg.destinationPath)
        else { return }

        leg.worktreeId = worktree.id
        let now = environment.now()
        let checkpointEvent = event(
            missionID: aggregate.mission.id,
            legID: leg.id,
            kind: .worktreeCreated,
            message: "Recovered the Mission worktree after restart.",
            at: now
        )
        do {
            try await environment.persistence.updateSetup(
                id: aggregate.mission.id,
                leg: leg,
                state: .needsAttention,
                checkpoint: .startingAgent,
                attentionReason: aggregate.mission.attentionReason,
                event: checkpointEvent
            )
            await notify(id: aggregate.mission.id)
        } catch {
            return
        }
    }

    private func persistFailure(
        aggregate: MissionAggregate,
        checkpoint: MissionSetupCheckpoint,
        message: String
    ) async {
        let sanitized = Self.sanitized(message)
        let failureEvent = event(
            missionID: aggregate.mission.id,
            legID: aggregate.primaryLeg?.id,
            kind: .attentionRequired,
            message: sanitized,
            at: environment.now()
        )
        do {
            try await environment.persistence.updateSetup(
                id: aggregate.mission.id,
                state: .needsAttention,
                checkpoint: checkpoint,
                attentionReason: sanitized,
                event: failureEvent
            )
            await notify(id: aggregate.mission.id)
        } catch {
            return
        }
    }

    private func notify(id: MissionID) async {
        if let aggregate = try? await environment.persistence.aggregate(id: id) {
            environment.notifyChanged(aggregate)
        }
    }

    private func event(
        missionID: MissionID,
        legID: MissionLegID?,
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

    private func retryMessage(for checkpoint: MissionSetupCheckpoint) -> String {
        switch checkpoint {
        case .creatingWorktree:
            "Retrying Mission worktree creation."
        case .startingAgent:
            "Retrying Mission agent startup."
        case .running:
            "Retrying Mission setup."
        }
    }

    private static func sanitized(_ message: String) -> String {
        let collapsed = message
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let fallback = collapsed.isEmpty ? "Mission setup failed." : collapsed
        return String(fallback.prefix(500))
    }
}
