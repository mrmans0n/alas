import Foundation

struct MissionLegDraft: Equatable, Sendable {
    let projectId: String
    let baseRef: String
    let baseRemoteName: String?
    let branch: String
    let destinationPath: String
    let agentId: String
    let initialPromptId: UUID
    let initialPrompt: String

    init(
        projectId: String,
        baseRef: String,
        baseRemoteName: String? = nil,
        branch: String,
        destinationPath: String,
        agentId: String,
        initialPromptId: UUID,
        initialPrompt: String
    ) {
        self.projectId = projectId
        self.baseRef = baseRef
        self.baseRemoteName = baseRemoteName
        self.branch = branch
        self.destinationPath = destinationPath
        self.agentId = agentId
        self.initialPromptId = initialPromptId
        self.initialPrompt = initialPrompt
    }
}

@MainActor
final class MissionLegCoordinator {
    private let environment: MissionCoordinator.Environment
    private var advancing: Set<MissionLegID> = []
    private var advanceWaiters: [MissionLegID: [CheckedContinuation<Void, Never>]] = [:]

    init(environment: MissionCoordinator.Environment) {
        self.environment = environment
    }

    func advance(missionID: MissionID, legID: MissionLegID) async {
        guard advancing.insert(legID).inserted else {
            await withCheckedContinuation { continuation in
                advanceWaiters[legID, default: []].append(continuation)
            }
            return
        }

        await performAdvance(missionID: missionID, legID: legID)
        advancing.remove(legID)
        let waiters = advanceWaiters.removeValue(forKey: legID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func retry(missionID: MissionID, legID: MissionLegID, recreateWorktree: Bool = false) async {
        let aggregate: MissionAggregate
        let leg: MissionLeg
        do {
            guard let loaded = try await environment.persistence.aggregate(id: missionID),
                  loaded.mission.state != .completed,
                  let loadedLeg = setupLeg(in: loaded, legID: legID),
                  loadedLeg.state == .needsAttention
            else { return }
            aggregate = loaded
            leg = loadedLeg
        } catch {
            reportPersistenceFailure(id: missionID, operation: "load Mission leg setup progress", error: error)
            return
        }

        var retryLeg = leg
        var shouldRecreateWorktree = recreateWorktree
        if recreateWorktree,
           let existing = environment.worktreeAtDestination(leg.projectId, leg.destinationPath),
           canReuseExistingWorktree(existing, for: leg) {
            shouldRecreateWorktree = false
        }
        if shouldRecreateWorktree {
            retryLeg.worktreeId = nil
            retryLeg.worktreeLineageID = nil
            retryLeg.acpSessionId = nil
        }
        retryLeg.state = .creating
        retryLeg.setupCheckpoint = shouldRecreateWorktree ? .creatingWorktree : leg.setupCheckpoint
        retryLeg.attentionReason = nil
        let now = environment.now()
        retryLeg.updatedAt = now
        let retryEvent = event(
            missionID: missionID,
            legID: legID,
            kind: .retryStarted,
            message: retryMessage(for: retryLeg.setupCheckpoint),
            at: now
        )
        guard await persist(
            leg: retryLeg,
            missionID: missionID,
            event: retryEvent,
            failureCheckpoint: leg.setupCheckpoint
        ) else { return }
        _ = aggregate
        await advance(missionID: missionID, legID: legID)
    }

    func reconcileInterrupted() async {
        let aggregates: [MissionAggregate]
        do {
            aggregates = try await environment.persistence.list(includeCompleted: false)
        } catch {
            reportPersistenceFailure(id: nil, operation: "load interrupted Mission legs", error: error)
            return
        }

        for aggregate in aggregates {
            for leg in aggregate.legs where setupLeg(in: aggregate, legID: leg.id)?.state == .needsAttention {
                await reconcileArtifacts(missionID: aggregate.mission.id, legID: leg.id)
            }
        }
        let creatingLegs: [(missionID: MissionID, legID: MissionLegID)] = aggregates.flatMap { aggregate -> [(missionID: MissionID, legID: MissionLegID)] in
            guard aggregate.mission.state != .needsAttention else { return [] }
            return aggregate.legs.compactMap { leg -> (missionID: MissionID, legID: MissionLegID)? in
                guard setupLeg(in: aggregate, legID: leg.id)?.state == .creating else { return nil }
                return (missionID: aggregate.mission.id, legID: leg.id)
            }
        }
        let advances: [Task<Void, Never>] = creatingLegs.map { candidate in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.advance(missionID: candidate.missionID, legID: candidate.legID)
            }
        }
        for advance in advances {
            await advance.value
        }
    }

    private func performAdvance(missionID: MissionID, legID: MissionLegID) async {
        while true {
            let aggregate: MissionAggregate
            let leg: MissionLeg
            do {
                guard let loaded = try await environment.persistence.aggregate(id: missionID),
                      loaded.mission.state != .completed,
                      let loadedLeg = setupLeg(in: loaded, legID: legID),
                      loadedLeg.state == .creating
                else { return }
                aggregate = loaded
                leg = loadedLeg
            } catch {
                reportPersistenceFailure(id: missionID, operation: "load Mission leg setup progress", error: error)
                return
            }

            let didAdvance: Bool
            switch leg.setupCheckpoint {
            case .creatingWorktree:
                didAdvance = await advanceWorktree(aggregate: aggregate, leg: leg)
            case .startingAgent:
                didAdvance = await advanceAgent(aggregate: aggregate, leg: leg)
            case .running:
                didAdvance = await settleRunning(aggregate: aggregate, leg: leg)
            }
            if !didAdvance { return }
        }
    }

    private func advanceWorktree(aggregate: MissionAggregate, leg: MissionLeg) async -> Bool {
        var leg = leg
        let worktree: Worktree
        if let existing = environment.worktreeAtDestination(leg.projectId, leg.destinationPath) {
            guard canReuseExistingWorktree(existing, for: leg) else {
                await persistFailure(
                    missionID: aggregate.mission.id,
                    leg: leg,
                    checkpoint: .creatingWorktree,
                    message: "A worktree already exists at the Mission destination. Choose a different branch or remove the existing worktree."
                )
                return false
            }
            worktree = existing
        } else {
            if leg.worktreeId == nil {
                switch await environment.plannedWorktreeID(leg) {
                case .success(let worktreeID):
                    leg.worktreeId = worktreeID
                    leg.updatedAt = environment.now()
                    guard await persist(
                        leg: leg,
                        missionID: aggregate.mission.id,
                        event: nil,
                        failureCheckpoint: .creatingWorktree
                    ),
                          !(await missionIsCompleted(aggregate.mission.id))
                    else { return false }
                case .failure(let failure):
                    await persistFailure(
                        missionID: aggregate.mission.id,
                        leg: leg,
                        checkpoint: .creatingWorktree,
                        message: failure.message
                    )
                    return false
                }
            }
            switch await environment.createWorktree(leg) {
            case .success(let created):
                worktree = created
            case .failure(let failure):
                await persistFailure(
                    missionID: aggregate.mission.id,
                    leg: leg,
                    checkpoint: .creatingWorktree,
                    message: failure.message
                )
                return false
            }
        }

        guard let worktreeLineageID = worktree.lineageID else {
            await persistFailure(
                missionID: aggregate.mission.id,
                leg: leg,
                checkpoint: .creatingWorktree,
                message: Self.worktreeIdentityFailureMessage
            )
            return false
        }
        leg.worktreeId = worktree.id
        leg.worktreeLineageID = worktreeLineageID
        leg.state = .creating
        leg.setupCheckpoint = .startingAgent
        leg.attentionReason = nil
        let now = environment.now()
        leg.updatedAt = now
        let checkpointEvent = event(
            missionID: aggregate.mission.id,
            legID: leg.id,
            kind: .worktreeCreated,
            message: "Worktree created for \(leg.branch).",
            at: now
        )
        guard await persist(
            leg: leg,
            missionID: aggregate.mission.id,
            event: checkpointEvent,
            failureCheckpoint: .creatingWorktree
        ) else {
            return false
        }
        environment.didCreateWorktree(aggregate.mission.id)
        return !(await missionIsCompleted(aggregate.mission.id))
    }

    private func advanceAgent(aggregate: MissionAggregate, leg: MissionLeg) async -> Bool {
        var leg = leg
        guard let worktree = environment.worktreeAtDestination(leg.projectId, leg.destinationPath),
              canReuseExistingWorktree(worktree, for: leg)
        else {
            await persistFailure(
                missionID: aggregate.mission.id,
                leg: leg,
                checkpoint: .startingAgent,
                message: "The Mission worktree is no longer available."
            )
            return false
        }
        guard let worktreeLineageID = worktree.lineageID else {
            await persistFailure(
                missionID: aggregate.mission.id,
                leg: leg,
                checkpoint: .startingAgent,
                message: Self.worktreeIdentityFailureMessage
            )
            return false
        }

        if leg.worktreeLineageID == nil {
            leg.worktreeLineageID = worktreeLineageID
            leg.updatedAt = environment.now()
            guard await persist(
                leg: leg,
                missionID: aggregate.mission.id,
                event: nil,
                failureCheckpoint: .startingAgent
            ) else { return false }
        }
        if leg.acpSessionId == nil {
            leg.acpSessionId = environment.makeID()
            leg.updatedAt = environment.now()
            guard await persist(
                leg: leg,
                missionID: aggregate.mission.id,
                event: nil,
                failureCheckpoint: .startingAgent
            ) else { return false }
        }

        switch await environment.startACP(leg, worktree) {
        case .success:
            leg.pendingInitialPrompt = nil
            leg.state = .running
            leg.setupCheckpoint = .running
            leg.attentionReason = nil
            let now = environment.now()
            leg.updatedAt = now
            let checkpointEvent = event(
                missionID: aggregate.mission.id,
                legID: leg.id,
                kind: .agentStarted,
                message: "Agent started in the Mission worktree.",
                at: now
            )
            guard await persist(
                leg: leg,
                missionID: aggregate.mission.id,
                event: checkpointEvent,
                failureCheckpoint: .startingAgent
            ) else {
                return false
            }
            return false
        case .failure(let failure):
            if failure.consumedInitialPrompt {
                leg.pendingInitialPrompt = nil
            }
            await persistFailure(
                missionID: aggregate.mission.id,
                leg: leg,
                checkpoint: .startingAgent,
                message: failure.message
            )
            return false
        }
    }

    private func settleRunning(aggregate: MissionAggregate, leg: MissionLeg) async -> Bool {
        var settledLeg = leg
        let now = environment.now()
        settledLeg.state = .running
        settledLeg.attentionReason = nil
        settledLeg.updatedAt = now
        let settledEvent = event(
            missionID: aggregate.mission.id,
            legID: settledLeg.id,
            kind: .agentStarted,
            message: "Mission setup completed.",
            at: now
        )
        return await persist(
            leg: settledLeg,
            missionID: aggregate.mission.id,
            event: settledEvent,
            failureCheckpoint: .running
        )
    }

    private func reconcileArtifacts(missionID: MissionID, legID: MissionLegID) async {
        let aggregate: MissionAggregate
        let leg: MissionLeg
        do {
            guard let loaded = try await environment.persistence.aggregate(id: missionID),
                  loaded.mission.state != .completed,
                  let loadedLeg = setupLeg(in: loaded, legID: legID),
                  loadedLeg.state == .needsAttention,
                  loadedLeg.setupCheckpoint == .creatingWorktree,
                  let worktree = environment.worktreeAtDestination(loadedLeg.projectId, loadedLeg.destinationPath),
                  canReuseExistingWorktree(worktree, for: loadedLeg),
                  let worktreeLineageID = worktree.lineageID
            else { return }
            aggregate = loaded
            leg = loadedLeg
            var recovered = leg
            recovered.worktreeId = worktree.id
            recovered.worktreeLineageID = worktreeLineageID
            recovered.setupCheckpoint = .startingAgent
            recovered.updatedAt = environment.now()
            let event = event(
                missionID: missionID,
                legID: legID,
                kind: .worktreeCreated,
                message: "Recovered the Mission worktree after restart.",
                at: recovered.updatedAt
            )
            guard await persist(leg: recovered, missionID: missionID, event: event) else { return }
        } catch {
            reportPersistenceFailure(id: missionID, operation: "recover Mission leg artifacts", error: error)
            return
        }
        _ = aggregate
        _ = leg
    }

    private func persist(
        leg: MissionLeg,
        missionID: MissionID,
        event: MissionEvent?,
        failureCheckpoint: MissionSetupCheckpoint? = nil
    ) async -> Bool {
        do {
            try await environment.persistence.updateLegSetup(missionID: missionID, leg: leg, event: event)
            await notify(id: missionID)
            return true
        } catch {
            if let failureCheckpoint {
                await persistFailure(
                    missionID: missionID,
                    leg: leg,
                    checkpoint: failureCheckpoint,
                    message: Self.persistenceFailureMessage
                )
            } else {
                reportPersistenceFailure(id: missionID, operation: "persist Mission leg setup progress", error: error)
            }
            return false
        }
    }

    private func persistFailure(
        missionID: MissionID,
        leg: MissionLeg,
        checkpoint: MissionSetupCheckpoint,
        message: String
    ) async {
        var failedLeg = leg
        let now = environment.now()
        failedLeg.state = .needsAttention
        failedLeg.setupCheckpoint = checkpoint
        failedLeg.attentionReason = Self.sanitized(message)
        failedLeg.updatedAt = now
        let failureEvent = event(
            missionID: missionID,
            legID: leg.id,
            kind: .attentionRequired,
            message: failedLeg.attentionReason ?? "Mission setup failed.",
            at: now
        )
        _ = await persist(leg: failedLeg, missionID: missionID, event: failureEvent)
    }

    private func missionIsCompleted(_ missionID: MissionID) async -> Bool {
        do {
            return try await environment.persistence.aggregate(id: missionID)?.mission.state == .completed
        } catch {
            reportPersistenceFailure(id: missionID, operation: "confirm Mission completion", error: error)
            return true
        }
    }

    private func setupLeg(in aggregate: MissionAggregate, legID: MissionLegID) -> MissionLeg? {
        guard var leg = aggregate.legs.first(where: { $0.id == legID }) else { return nil }
        if aggregate.legs.count == 1,
           aggregate.mission.state == .needsAttention,
           leg.state != .needsAttention {
            leg.state = .needsAttention
            leg.setupCheckpoint = aggregate.mission.setupCheckpoint
            leg.attentionReason = aggregate.mission.attentionReason
        }
        return leg
    }

    private func canReuseExistingWorktree(_ worktree: Worktree, for leg: MissionLeg) -> Bool {
        leg.worktreeId == worktree.id
            && leg.branch == worktree.branch
            && URL(fileURLWithPath: leg.destinationPath).standardizedFileURL.path
                == worktree.path.standardizedFileURL.path
            && (leg.worktreeLineageID == nil || leg.worktreeLineageID == worktree.lineageID)
    }

    private func notify(id: MissionID) async {
        do {
            if let aggregate = try await environment.persistence.aggregate(id: id) {
                environment.notifyChanged(aggregate)
            }
        } catch {
            reportPersistenceFailure(id: id, operation: "publish Mission leg setup progress", error: error)
        }
    }

    private func reportPersistenceFailure(id: MissionID?, operation: String, error: Error) {
        let detail = Self.sanitized(error.localizedDescription)
        environment.reportFailure(id, "Could not \(operation): \(detail)")
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

    private static let worktreeIdentityFailureMessage = "Could not establish a durable identity for the Mission worktree. Retry this Mission."
    private static let persistenceFailureMessage = "Could not persist Mission setup progress. Retry this Mission."
}
