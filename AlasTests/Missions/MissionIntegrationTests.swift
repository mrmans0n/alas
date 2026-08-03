import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct MissionIntegrationTests {
    @Test("Mission insertion is durable before worktree creation starts")
    func missionInsertionIsDurableBeforeWorktreeCreationStarts() async throws {
        let harness = try MissionIntegrationHarness()
        harness.verifyDurabilityWhenCreatingWorktree = true

        let id = try await harness.create()
        let aggregate = await harness.waitUntilSettled(id)

        #expect(harness.missionWasDurableWhenGitStarted)
        #expect(aggregate.mission.state == .running)
        #expect(harness.worktreeCreateCount == 1)
        #expect(harness.sessionIDs.count == 1)
        #expect(harness.promptIDs == [harness.draft.initialPromptId])
    }

    @Test("successful setup advances through worktree and agent checkpoints to running")
    func successfulSetupAdvancesToRunning() async throws {
        let harness = try MissionIntegrationHarness()

        let id = try await harness.create()
        let aggregate = await harness.waitUntilSettled(id)

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .running)
        #expect(aggregate.primaryLeg?.worktreeId == harness.worktree.id)
        #expect(aggregate.primaryLeg?.acpSessionId == harness.sessionIDs.first)
        #expect(aggregate.primaryLeg?.pendingInitialPrompt == nil)
        #expect(aggregate.events.map(\.kind) == [.created, .worktreeCreated, .agentStarted])
    }

    @Test("restart at every setup checkpoint creates no duplicate artifacts")
    func restartAtEveryCheckpointCreatesNoDuplicateArtifacts() async throws {
        for checkpoint in [MissionSetupCheckpoint.creatingWorktree, .startingAgent] {
            let harness = try MissionIntegrationHarness(interruptedAt: checkpoint)

            await harness.relaunchAndReconcile()
            let aggregate = try #require(await harness.aggregate)

            #expect(harness.worktreeCreateCount <= 1)
            #expect(harness.sessionIDs.count == 1)
            #expect(harness.promptIDs.count == 1)
            #expect(aggregate.mission.state == .running)
            #expect(aggregate.mission.setupCheckpoint == .running)
            #expect(aggregate.primaryLeg?.worktreeId == harness.worktree.id)
        }
    }

    @Test("worktree failure stops setup before ACP and preserves retry input")
    func worktreeFailureStopsBeforeACP() async throws {
        let harness = try MissionIntegrationHarness(worktreeFailure: "branch already exists\nretry later")

        let id = try await harness.create()
        let aggregate = await harness.waitUntilSettled(id)

        #expect(harness.worktreeCreateCount == 1)
        #expect(harness.sessionIDs.isEmpty)
        #expect(harness.promptIDs.isEmpty)
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .creatingWorktree)
        #expect(aggregate.mission.attentionReason == "branch already exists retry later")
        #expect(aggregate.primaryLeg?.worktreeId == harness.worktree.id)
        #expect(aggregate.primaryLeg?.acpSessionId == nil)
        #expect(aggregate.primaryLeg?.pendingInitialPrompt == harness.draft.initialPrompt)
    }

    @Test("ACP failure retries only agent startup with the durable session and prompt")
    func acpFailureRetriesOnlyAgentStartup() async throws {
        let harness = try MissionIntegrationHarness(acpFailuresBeforeSuccess: 1)

        let id = try await harness.create()
        let failed = await harness.waitUntilSettled(id)

        #expect(failed.mission.state == .running)
        #expect(failed.mission.setupCheckpoint == .startingAgent)
        #expect(failed.primaryLeg?.worktreeId == harness.worktree.id)
        #expect(failed.primaryLeg?.acpSessionId == harness.sessionIDs.first)
        #expect(failed.primaryLeg?.pendingInitialPrompt == harness.draft.initialPrompt)

        await harness.controller.retry(id)
        let recovered = await harness.waitUntilSettled(id)

        #expect(harness.worktreeCreateCount == 1)
        #expect(harness.sessionIDs.count == 2)
        #expect(Set(harness.sessionIDs).count == 1)
        #expect(harness.promptIDs == [harness.draft.initialPromptId, harness.draft.initialPromptId])
        #expect(recovered.mission.state == .running)
        #expect(recovered.mission.setupCheckpoint == .running)
        #expect(recovered.primaryLeg?.pendingInitialPrompt == nil)
    }

    @Test("merged review makes a running Mission ready to complete")
    func mergedReviewMakesMissionReady() async throws {
        let harness = try MissionIntegrationHarness()
        let id = try await harness.create()
        let running = await harness.waitUntilSettled(id)
        let worktreeID = try #require(running.primaryLeg?.worktreeId)

        await harness.controller.observeReview(
            worktreeId: worktreeID,
            baseRef: "origin/main",
            snapshot: MissionIntegrationHarness.reviewSnapshot(state: .merged)
        )
        let ready = try #require(try await harness.persistence.aggregate(id: id))

        #expect(ready.mission.state == .readyToComplete)
        #expect(ready.primaryLeg?.reviewIdentity == MissionIntegrationHarness.reviewIdentity)
        #expect(ready.events.last?.kind == .ready)
    }

    @Test("Mission becomes ready only after every leg is ready")
    func allLegsReady() async throws {
        let fake = try MissionControllerFake(existing: MissionFixtures.twoLegMission())
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "sdk-worktree",
            baseRef: "origin/main",
            snapshot: .mergedFixture
        )
        let afterReview = try #require(try await fake.persistence.aggregate(id: .fixture))
        #expect(afterReview.mission.state == .running)
        #expect(afterReview.legs.first(where: { $0.id == .sdk })?.readinessEvidence?.kind == .mergedReview)

        await fake.controller.recordArchive(worktreeId: "app-worktree")
        #expect(try await fake.persistence.aggregate(id: .fixture)?.mission.state == .readyToComplete)
    }

    @Test("review updates require the target leg repository to match")
    func reviewRequiresTargetLegRepository() async throws {
        let fake = try MissionControllerFake(
            existing: MissionFixtures.twoLegMission(),
            reviewRepositoryMatches: { projectID, _, _ in projectID == "app-project" }
        )
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "sdk-worktree",
            baseRef: "origin/main",
            snapshot: .mergedFixture
        )

        let aggregate = try #require(try await fake.persistence.aggregate(id: .fixture))
        #expect(aggregate.legs.first(where: { $0.id == .sdk })?.readinessEvidence == nil)
    }

    @Test("parallel leg setup recovers independently and becomes ready after review and archive")
    func multiLegLifecycleRecoversAcrossRestart() async throws {
        let harness = try MissionIntegrationHarness()
        let missionID = try await harness.create()
        _ = await harness.waitUntilSettled(missionID)

        harness.failNextACPStart(forProjectID: "sdk-project")
        let sdkLegID = try await harness.controller.addLeg(harness.sdkDraft, to: missionID)
        let failed = await harness.waitUntilLegSettled(missionID, legID: sdkLegID)
        #expect(failed.legs.first(where: { $0.id == sdkLegID })?.state == .needsAttention)

        await harness.relaunchAndReconcile()
        await harness.controller.retry(missionID, legID: sdkLegID)
        let recovered = await harness.waitUntilLegSettled(missionID, legID: sdkLegID)
        let appLeg = try #require(recovered.legs.first(where: { $0.id == .app }))
        let sdkLeg = try #require(recovered.legs.first(where: { $0.id == sdkLegID }))

        await harness.controller.observeReview(
            worktreeId: try #require(appLeg.worktreeId),
            baseRef: appLeg.baseRef,
            snapshot: MissionIntegrationHarness.reviewSnapshot(state: .merged)
        )
        harness.markArchived(sdkLeg)
        await harness.controller.recordArchive(worktreeId: try #require(sdkLeg.worktreeId))
        let aggregate = try #require(try await harness.persistence.aggregate(id: missionID))

        #expect(harness.worktreeCreationsByLeg[.app] == 1)
        #expect(harness.worktreeCreationsByLeg[sdkLegID] == 1)
        #expect(harness.promptDeliveriesByLeg[sdkLegID] == 1)
        #expect(aggregate.legs.first(where: { $0.id == .app })?.state == .ready)
        #expect(aggregate.legs.first(where: { $0.id == sdkLegID })?.state == .ready)
        #expect(aggregate.legs.allSatisfy { $0.state == .ready })
        #expect(aggregate.mission.state == .readyToComplete)
    }

    @Test("A missing worktree affects only its matching leg")
    func missingWorktreeAffectsOnlyMatchingLeg() async throws {
        let fake = try MissionControllerFake(existing: MissionFixtures.twoLegMission())
        await fake.controller.load()

        await fake.controller.recordMissingWorktree(projectId: "sdk-project", projectRemoved: false)
        let aggregate = try #require(try await fake.persistence.aggregate(id: .fixture))

        #expect(aggregate.legs.first(where: { $0.id == .sdk })?.state == .needsAttention)
        #expect(aggregate.legs.first(where: { $0.id == .app })?.state == .running)
    }

    @Test("Project removal affects only matching legs")
    func projectRemovalAffectsOnlyMatchingLegs() async throws {
        let fake = try MissionControllerFake(existing: MissionFixtures.twoLegMission())
        await fake.controller.load()

        await fake.controller.recordMissingWorktree(projectId: "app-project", projectRemoved: true)
        let aggregate = try #require(try await fake.persistence.aggregate(id: .fixture))

        #expect(aggregate.legs.first(where: { $0.id == .app })?.state == .needsAttention)
        #expect(aggregate.legs.first(where: { $0.id == .sdk })?.state == .running)
    }

    @Test("Provider refresh failure preserves prior leg readiness")
    func providerRefreshFailurePreservesPriorLegReadiness() async throws {
        let fake = try MissionControllerFake(
            existing: MissionFixtures.twoLegMission(),
            issueRefresh: { _, _ in throw CodeHostProviderError.unauthenticated("github.com") }
        )
        await fake.controller.load()
        await fake.controller.recordArchive(worktreeId: "app-worktree")
        let before = try #require(try await fake.persistence.aggregate(id: .fixture))

        await fake.controller.refreshIssue(.fixture)
        let after = try #require(try await fake.persistence.aggregate(id: .fixture))

        #expect(after.legs.first(where: { $0.id == .app })?.readinessEvidence == before.legs.first(where: { $0.id == .app })?.readinessEvidence)
        #expect(after.mission.state == .running)
    }

    @Test("complete persists completion and has no external side effects")
    func completeHasNoExternalSideEffects() async throws {
        let harness = try MissionIntegrationHarness(running: true)
        let id = MissionID(rawValue: "mission-1")

        await harness.controller.load()
        await harness.controller.complete(id)
        let aggregate = try #require(try await harness.persistence.aggregate(id: id))

        #expect(aggregate.mission.state == .completed)
        #expect(aggregate.events.last?.kind == .completed)
        #expect(harness.providerMutations.isEmpty)
        #expect(harness.worktreeMutations.isEmpty)
        #expect(harness.sessionStops.isEmpty)
        #expect(harness.sessionIDs.isEmpty)
        #expect(harness.promptIDs.isEmpty)
    }

    @Test("duplicate creation is blocked before external artifacts are created")
    func duplicateCreationIsBlockedBeforeExternalArtifacts() async throws {
        let harness = try MissionIntegrationHarness(existingActive: true)

        await #expect(throws: MissionStore.Error.duplicateActiveIssueIdentity) {
            try await harness.create()
        }
        #expect(try await harness.persistence.list(includeCompleted: false).count == 1)
        #expect(harness.worktreeCreateCount == 0)
        #expect(harness.sessionIDs.isEmpty)
        #expect(harness.promptIDs.isEmpty)
        #expect(harness.providerMutations.isEmpty)
        #expect(harness.worktreeMutations.isEmpty)
        #expect(harness.sessionStops.isEmpty)

        let duplicateID = try await harness.create(allowDuplicate: true)
        let duplicate = await harness.waitUntilSettled(duplicateID)

        #expect(try await harness.persistence.list(includeCompleted: false).count == 2)
        #expect(duplicate.mission.state == .running)
        #expect(harness.worktreeCreateCount == 1)
        #expect(harness.sessionIDs.count == 1)
    }
}

private extension ReviewLoopSnapshot {
    static let mergedFixture = MissionControllerFake.reviewSnapshot(
        branch: "sdk-fix",
        number: 92,
        state: .merged
    )
}

@MainActor
private final class MissionControllerFake {
    let persistence: MissionPersistence
    let controller: MissionController

    init(
        existing: MissionAggregate,
        reviewRepositoryMatches: @escaping MissionProjectReviewRepositoryMatcher = { _, _, _ in true },
        issueRefresh: @escaping MissionIssueRefresh = { _, _ in
            throw CodeHostProviderError.malformedOutput("No refresh configured.")
        }
    ) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-controller-fixture-\(UUID().uuidString).sqlite")
            .path
        let store = try MissionStore(path: path)
        var seed = existing
        let extraLegs = Array(seed.legs.dropFirst())
        seed.legs = Array(seed.legs.prefix(1))
        seed.events = seed.events.filter { event in
            event.legID == nil || seed.legs.contains { $0.id == event.legID }
        }
        try store.insert(seed)
        for leg in extraLegs {
            try store.addLeg(
                leg,
                event: MissionFixtures.event(
                    id: "fixture-add-\(leg.ordinal)",
                    missionID: leg.missionID,
                    legID: leg.id,
                    kind: .legAdded,
                    createdAt: 100 + Double(leg.ordinal)
                )
            )
        }
        persistence = MissionPersistence(path: path)
        var timestamp: TimeInterval = 200
        var eventID = 0
        controller = MissionController(
            environment: .init(
                persistence: persistence,
                now: {
                    timestamp += 1
                    return Date(timeIntervalSince1970: timestamp)
                },
                makeID: {
                    eventID += 1
                    return "fixture-event-\(eventID)"
                },
                worktreeAtDestination: { projectID, destinationPath in
                    existing.legs.first { $0.projectId == projectID && $0.destinationPath == destinationPath }.map {
                        Worktree(
                            id: $0.worktreeId!,
                            projectId: $0.projectId,
                            name: $0.branch,
                            branch: $0.branch,
                            path: URL(fileURLWithPath: $0.destinationPath),
                            status: .clean,
                            lastActivity: Date(timeIntervalSince1970: 100),
                            lineageID: $0.worktreeLineageID
                        )
                    }
                },
                createWorktree: { _ in .failure(.init(message: "Unexpected worktree creation.")) },
                startACP: { _, _ in .failure(.init(message: "Unexpected ACP startup.")) },
                notifyChanged: { _ in }
            ),
            issueRefresh: issueRefresh,
            reviewRepositoryMatches: reviewRepositoryMatches,
            branchTip: { _, _ in "abc123" },
            projectExists: { _ in true },
            worktreeArchived: { projectID, _ in projectID == "app-project" }
        )
    }

    static func reviewSnapshot(branch: String, number: Int, state: ReviewRequestState) -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "acme",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/acme/alas")!
        )
        let request = ReviewRequest(
            remote: remote,
            number: number,
            title: "Fixture review",
            url: remote.reviewRequestURL(number: number),
            state: state,
            isDraft: false,
            headRefName: branch,
            baseRefName: "main",
            headSHA: "abc123",
            reviewDecision: .approved,
            mergeState: .clean,
            checks: [],
            threads: []
        )
        return ReviewLoopSnapshot(
            local: .init(
                branchName: branch,
                headSHA: "abc123",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 1,
                hasUpstream: true,
                needsPush: false
            ),
            remote: remote,
            reviewRequest: request,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .readOnly,
            errorMessage: nil
        )
    }
}

@MainActor
private final class MissionIntegrationHarness {
    let draft = MissionDraft(
        issue: MissionFixtures.issue(),
        projectId: "project-1",
        baseRef: "origin/main",
        baseRemoteName: "origin",
        branch: "fix/parser-crash",
        destinationPath: "/tmp/alas-mission",
        agentId: "codex",
        initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        initialPrompt: "Fix issue #42."
    )
    let worktree = Worktree(
        id: "worktree-1",
        projectId: "project-1",
        name: "fix/parser-crash",
        branch: "fix/parser-crash",
        path: URL(fileURLWithPath: "/tmp/alas-mission"),
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 100),
        lineageID: "device:inode"
    )
    let sdkDraft = MissionLegDraft(
        projectId: "sdk-project",
        baseRef: "origin/main",
        baseRemoteName: "origin",
        branch: "fix/sdk-parser-crash",
        destinationPath: "/tmp/alas-sdk-mission",
        agentId: "codex",
        initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        preparedPrompt: "Fix the SDK parser crash."
    )

    private let path: String
    private let recorder: MissionIntegrationRecorder
    private(set) var persistence: MissionPersistence
    private(set) var controller: MissionController

    var aggregate: MissionAggregate? {
        get async {
            try? await persistence.aggregate(id: MissionID(rawValue: "mission-1"))
        }
    }

    var verifyDurabilityWhenCreatingWorktree: Bool {
        get { recorder.verifyDurabilityWhenCreatingWorktree }
        set { recorder.verifyDurabilityWhenCreatingWorktree = newValue }
    }

    var missionWasDurableWhenGitStarted: Bool { recorder.missionWasDurableWhenGitStarted }
    var worktreeCreateCount: Int { recorder.worktreeCreateCount }
    var worktreeCreationsByLeg: [MissionLegID: Int] { recorder.worktreeCreationsByLeg }
    var sessionIDs: [String] { recorder.sessionIDs }
    var promptIDs: [UUID] { recorder.promptIDs }
    var promptDeliveriesByLeg: [MissionLegID: Int] { recorder.promptDeliveriesByLeg }
    var providerMutations: [String] { recorder.providerMutations }
    var worktreeMutations: [String] { recorder.worktreeMutations }
    var sessionStops: [String] { recorder.sessionStops }

    init(
        worktreeFailure: String? = nil,
        acpFailuresBeforeSuccess: Int = 0,
        running: Bool = false,
        existingActive: Bool = false
    ) throws {
        path = Self.temporaryPath()
        recorder = MissionIntegrationRecorder(
            worktree: worktree,
            worktreeFailure: worktreeFailure,
            acpFailuresBeforeSuccess: acpFailuresBeforeSuccess
        )
        persistence = MissionPersistence(path: path)
        controller = Self.makeController(persistence: persistence, recorder: recorder)

        if running {
            var aggregate = Self.runningAggregate()
            aggregate.legs[0].worktreeId = worktree.id
            aggregate.legs[0].acpSessionId = "session-1"
            recorder.existingWorktree = worktree
            try Self.insert(aggregate, at: path)
        }
        if existingActive {
            try Self.insert(MissionFixtures.creatingMission(), at: path)
        }
    }

    init(interruptedAt checkpoint: MissionSetupCheckpoint) throws {
        path = Self.temporaryPath()
        recorder = MissionIntegrationRecorder(worktree: worktree)
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .creating
        aggregate.mission.setupCheckpoint = checkpoint
        recorder.existingWorktree = worktree
        switch checkpoint {
        case .creatingWorktree:
            aggregate.legs[0].worktreeId = worktree.id
            aggregate.legs[0].acpSessionId = nil
        case .startingAgent:
            aggregate.legs[0].worktreeId = worktree.id
            aggregate.legs[0].acpSessionId = nil
        case .running:
            aggregate = Self.runningAggregate()
        }
        try Self.insert(aggregate, at: path)
        persistence = MissionPersistence(path: path)
        controller = Self.makeController(persistence: persistence, recorder: recorder)
    }

    func create(allowDuplicate: Bool = false) async throws -> MissionID {
        try await controller.create(draft, allowDuplicate: allowDuplicate)
    }

    func failNextACPStart(forProjectID projectID: String) {
        recorder.failNextACPStart(forProjectID: projectID)
    }

    func markArchived(_ leg: MissionLeg) {
        recorder.markArchived(projectID: leg.projectId, destinationPath: leg.destinationPath)
    }

    func relaunchAndReconcile() async {
        persistence = MissionPersistence(path: path)
        controller = Self.makeController(persistence: persistence, recorder: recorder)
        await controller.load()
        await controller.reconcileInterrupted()
        _ = await waitUntilSettled(MissionID(rawValue: "mission-1"))
    }

    func waitUntilSettled(_ id: MissionID) async -> MissionAggregate {
        for _ in 0..<2_000 {
            if let aggregate = try? await persistence.aggregate(id: id),
               aggregate.mission.state != .creating,
               controller.aggregate(id: id)?.mission.state == aggregate.mission.state {
                return aggregate
            }
            await Task.yield()
        }
        return try! await persistence.aggregate(id: id)!
    }

    func waitUntilLegSettled(_ id: MissionID, legID: MissionLegID) async -> MissionAggregate {
        for _ in 0..<2_000 {
            if let aggregate = try? await persistence.aggregate(id: id),
               let leg = aggregate.legs.first(where: { $0.id == legID }),
               leg.state != .creating,
               controller.aggregate(id: id)?.legs.first(where: { $0.id == legID })?.state == leg.state {
                return aggregate
            }
            await Task.yield()
        }
        return try! await persistence.aggregate(id: id)!
    }

    static let reviewIdentity = MissionReviewIdentity(
        provider: .github,
        host: "github.com",
        repositorySlug: "acme/alas",
        number: 91,
        url: URL(string: "https://github.com/acme/alas/pull/91")!
    )

    static func reviewSnapshot(state: ReviewRequestState) -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "acme",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/acme/alas")!
        )
        let request = ReviewRequest(
            remote: remote,
            number: 91,
            title: "Mission review",
            url: remote.reviewRequestURL(number: 91),
            state: state,
            isDraft: false,
            headRefName: "fix/parser-crash",
            baseRefName: "main",
            headSHA: "abc123",
            reviewDecision: .approved,
            mergeState: .clean,
            checks: [],
            threads: []
        )
        return ReviewLoopSnapshot(
            local: .init(
                branchName: "fix/parser-crash",
                headSHA: "abc123",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 1,
                hasUpstream: true,
                needsPush: false
            ),
            remote: remote,
            reviewRequest: request,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .readOnly,
            errorMessage: nil
        )
    }

    private static func makeController(
        persistence: MissionPersistence,
        recorder: MissionIntegrationRecorder
    ) -> MissionController {
        MissionController(
            environment: .init(
                persistence: persistence,
                now: { recorder.now() },
                makeID: { recorder.makeID() },
                plannedWorktreeID: { leg in .success(recorder.worktree(for: leg).id) },
                worktreeAtDestination: { projectID, destinationPath in
                    recorder.worktreeAtDestination(projectID: projectID, destinationPath: destinationPath)
                },
                createWorktree: { leg in
                    await recorder.createWorktree(leg, persistence: persistence)
                },
                startACP: { leg, worktree in
                    await recorder.startACP(leg: leg, worktree: worktree)
                },
                notifyChanged: { aggregate in
                    recorder.notifications.append(aggregate)
                }
            ),
            issueRefresh: { identity, projectID in
                try await recorder.refreshIssue(identity: identity, projectID: projectID)
            },
            branchTip: { _, _ in "abc123" },
            projectExists: { $0 == "project-1" || $0 == "sdk-project" },
            worktreeArchived: { projectID, destinationPath in
                recorder.worktreeArchived(projectID: projectID, destinationPath: destinationPath)
            },
            reviewSnapshot: { _, _ in nil },
            startupReviewSnapshot: { _, _ in nil }
        )
    }

    private static func runningAggregate() -> MissionAggregate {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.mission.setupCheckpoint = .running
        aggregate.legs[0].worktreeId = "worktree-1"
        aggregate.legs[0].worktreeLineageID = "device:inode"
        aggregate.legs[0].acpSessionId = "session-1"
        aggregate.legs[0].pendingInitialPrompt = nil
        return aggregate
    }

    private static func insert(_ aggregate: MissionAggregate, at path: String) throws {
        let store = try MissionStore(path: path)
        try store.insert(aggregate)
    }

    private static func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-integration-\(UUID().uuidString).sqlite")
            .path
    }
}

@MainActor
private final class MissionIntegrationRecorder {
    let worktree: Worktree
    var existingWorktree: Worktree?
    var verifyDurabilityWhenCreatingWorktree = false
    private(set) var missionWasDurableWhenGitStarted = false
    private(set) var worktreeCreateCount = 0
    private(set) var worktreeCreationsByLeg: [MissionLegID: Int] = [:]
    private(set) var sessionIDs: [String] = []
    private(set) var promptIDs: [UUID] = []
    private(set) var promptDeliveriesByLeg: [MissionLegID: Int] = [:]
    private(set) var providerMutations: [String] = []
    private(set) var worktreeMutations: [String] = []
    private(set) var sessionStops: [String] = []
    var notifications: [MissionAggregate] = []

    private let worktreeFailure: String?
    private var acpFailuresRemaining: Int
    private var acpFailuresByProject: Set<String> = []
    private var existingWorktrees: [String: Worktree] = [:]
    private var archivedDestinations: Set<String> = []
    private var clock: TimeInterval = 1_000
    private var idCounter = 0

    init(
        worktree: Worktree,
        worktreeFailure: String? = nil,
        acpFailuresBeforeSuccess: Int = 0
    ) {
        self.worktree = worktree
        self.worktreeFailure = worktreeFailure
        acpFailuresRemaining = acpFailuresBeforeSuccess
    }

    func now() -> Date {
        clock += 1
        return Date(timeIntervalSince1970: clock)
    }

    func makeID() -> String {
        idCounter += 1
        switch idCounter {
        case 1: return "mission-1"
        case 2: return MissionLegID.app.rawValue
        case 4: return MissionLegID.sdk.rawValue
        default: break
        }
        return "integration-id-\(idCounter)"
    }

    func failNextACPStart(forProjectID projectID: String) {
        acpFailuresByProject.insert(projectID)
    }

    func markArchived(projectID: String, destinationPath: String) {
        archivedDestinations.insert("\(projectID):\(URL(fileURLWithPath: destinationPath).standardizedFileURL.path)")
    }

    func worktreeArchived(projectID: String, destinationPath: String) -> Bool {
        archivedDestinations.contains(
            "\(projectID):\(URL(fileURLWithPath: destinationPath).standardizedFileURL.path)"
        )
    }

    func worktree(for leg: MissionLeg) -> Worktree {
        guard leg.projectId != worktree.projectId else { return worktree }
        return Worktree(
            id: "worktree-\(leg.id.rawValue)",
            projectId: leg.projectId,
            name: leg.branch,
            branch: leg.branch,
            path: URL(fileURLWithPath: leg.destinationPath),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 100),
            lineageID: "device:inode-\(leg.id.rawValue)"
        )
    }

    func worktreeAtDestination(projectID: String, destinationPath: String) -> Worktree? {
        guard let worktree = existingWorktrees[projectID] ?? (projectID == worktree.projectId ? existingWorktree : nil),
              URL(fileURLWithPath: destinationPath).standardizedFileURL.path == worktree.path.standardizedFileURL.path
        else { return nil }
        return worktree
    }

    func createWorktree(
        _ leg: MissionLeg,
        persistence: MissionPersistence
    ) async -> Result<Worktree, WorktreeCreationFailure> {
        worktreeCreateCount += 1
        worktreeCreationsByLeg[leg.id, default: 0] += 1
        worktreeMutations.append("create:\(leg.destinationPath)")
        if verifyDurabilityWhenCreatingWorktree {
            missionWasDurableWhenGitStarted = (try? await persistence.aggregate(id: leg.missionID)) != nil
        }
        if let worktreeFailure {
            return .failure(.init(message: worktreeFailure))
        }
        let created = worktree(for: leg)
        existingWorktree = created
        existingWorktrees[leg.projectId] = created
        return .success(created)
    }

    func startACP(
        leg: MissionLeg,
        worktree _: Worktree
    ) async -> Result<ACPSession.ID, MissionCoordinator.MissionOperationFailure> {
        let sessionID = leg.acpSessionId ?? "missing-session"
        sessionIDs.append(sessionID)
        if let promptID = leg.pendingInitialPrompt.map({ _ in leg.initialPromptId }) {
            promptIDs.append(promptID)
            promptDeliveriesByLeg[leg.id, default: 0] += 1
        }
        if acpFailuresByProject.remove(leg.projectId) != nil {
            return .failure(.init(message: "Install Codex", consumedInitialPrompt: true))
        }
        if acpFailuresRemaining > 0 {
            acpFailuresRemaining -= 1
            return .failure(.init(message: "Install Codex"))
        }
        return .success(sessionID)
    }

    func refreshIssue(
        identity _: MissionIssueIdentity,
        projectID _: String
    ) async throws -> MissionIssueSnapshot {
        throw CodeHostProviderError.malformedOutput("No issue refresh configured.")
    }
}
