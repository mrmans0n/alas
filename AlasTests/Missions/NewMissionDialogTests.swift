import Foundation
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("New Mission dialog")
struct NewMissionDialogTests {
    @Test("resolution moves through resolving and seeds confirmation once")
    func resolvedIssueSeedsEditableConfirmationOnce() async {
        let fake = NewMissionDialogFake(suspendResolution: true)
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "https://github.com/mrmans0n/alas/issues/1842"

        let resolution = Task { await model.resolve() }
        await fake.waitUntilResolutionStarts()
        #expect(model.phase == .resolving)

        fake.finishResolution()
        await resolution.value

        #expect(model.phase == .confirmation)
        #expect(model.projectId == "alas")
        #expect(model.base == "origin/main")
        #expect(model.branch == "feature/1842-fix-offline-sync-conflicts")
        #expect(model.agentId == "codex")
        #expect(model.prompt.contains("## Issue context"))
        #expect(model.prompt.contains("https://github.com/mrmans0n/alas/issues/1842"))
    }

    @Test("cancel while resolving rejects the late result")
    func cancelWhileResolvingRejectsLateResult() async {
        let fake = NewMissionDialogFake(suspendResolution: true)
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"
        let resolution = Task { await model.resolve() }
        await fake.waitUntilResolutionStarts()

        model.cancelResolution()
        fake.finishResolution()
        await resolution.value

        #expect(model.phase == .entry)
        #expect(model.resolved == nil)
        #expect(model.projectId.isEmpty)
    }

    @Test("changing the reference rejects a late resolution")
    func lateResolutionCannotOverwriteNewReference() async {
        let fake = NewMissionDialogFake(suspendResolution: true)
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1"
        let first = Task { await model.resolve() }
        await fake.waitUntilResolutionStarts()

        model.reference = "#2"
        fake.finishResolution()
        await first.value

        #expect(model.reference == "#2")
        #expect(model.phase == .entry)
        #expect(model.resolved == nil)
    }

    @Test("a stale branch failure cannot mutate a newer issue entry")
    func staleBranchFailureCannotSetError() async {
        let fake = NewMissionDialogFake(
            suspendBranches: true,
            branchError: NewMissionDialogFake.TestError.branchFailed
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1"
        let first = Task { await model.resolve() }
        await fake.waitUntilBranchLoadStarts()

        model.reference = "#2"
        fake.finishBranchLoad()
        await first.value

        #expect(model.reference == "#2")
        #expect(model.phase == .entry)
        #expect(model.errorMessage == nil)
        #expect(model.branchErrorMessage == nil)
    }

    @Test("branch inventory failure blocks Mission creation")
    func branchInventoryFailureBlocksCreation() async {
        let fake = NewMissionDialogFake(branchError: NewMissionDialogFake.TestError.branchFailed)
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"

        await model.resolve()

        #expect(model.phase == .confirmation)
        #expect(model.branchErrorMessage == "Branch loading failed.")
        #expect(model.validationMessage == "Reload repository branches before creating a Mission.")
        #expect(!model.canCreate)
        #expect(await model.create(allowDuplicate: false) == nil)
        #expect(fake.createdDrafts.isEmpty)
    }

    @Test("a manually entered active Mission branch blocks creation")
    func reservedManualBranchBlocksCreation() async {
        let fake = NewMissionDialogFake(
            reservedBranchesByProject: ["alas": ["feature/reserved"]]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        let actions = NewMissionDialogActions(model: model, dismiss: {})
        model.reference = "#1842"
        await model.resolve()

        actions.branch.wrappedValue = "feature/reserved"

        #expect(model.validationMessage == "Another active Mission already reserves this branch.")
        #expect(!model.canCreate)
        #expect(await model.create(allowDuplicate: false) == nil)
        #expect(fake.createdDrafts.isEmpty)
    }

    @Test("project switch blocks creation while branch inventory loads")
    func projectSwitchBlocksCreationWhileBranchesLoad() async {
        let fake = NewMissionDialogFake(
            suspendBranches: true,
            candidateProjectIds: ["alas", "alas-clone"],
            configuredBases: ["alas": "main", "alas-clone": "trunk"],
            branchesByProject: ["alas": ["main"], "alas-clone": ["trunk"]]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"
        let resolution = Task { await model.resolve() }
        await fake.waitUntilBranchLoadStarts()
        fake.finishBranchLoad()
        await resolution.value

        let selection = Task { await model.selectProject("alas-clone") }
        await fake.waitUntilBranchLoadStarts()

        #expect(model.isLoadingBranches)
        #expect(model.validationMessage == "Wait for repository branches to finish loading.")
        #expect(!model.canCreate)
        #expect(await model.create(allowDuplicate: false) == nil)
        #expect(fake.createdDrafts.isEmpty)

        fake.finishBranchLoad()
        await selection.value
        #expect(model.canCreate)
    }

    @Test("only matching projects can be selected")
    func projectSelectionIsLimitedToResolverMatches() async {
        let fake = NewMissionDialogFake(
            candidateProjectIds: ["alas", "alas-clone"],
            configuredBases: ["alas": "origin/main", "alas-clone": "trunk"],
            configuredPrefixes: ["alas": "feature/", "alas-clone": "mission/"],
            branchesByProject: [
                "alas": ["origin/main"],
                "alas-clone": ["release", "trunk"],
            ]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "https://github.com/mrmans0n/alas/issues/1842"
        await model.resolve()

        await model.selectProject("alas-clone")
        #expect(model.projectId == "alas-clone")
        #expect(model.base == "trunk")
        #expect(model.branch == "mission/1842-fix-offline-sync-conflicts")

        await model.selectProject("unrelated")
        #expect(model.projectId == "alas-clone")
        #expect(model.errorMessage == "Choose a repository matched to this issue.")
    }

    @Test("project changes refresh only untouched base and branch drafts")
    func projectChangePreservesIndependentlyEditedDrafts() async {
        let fake = NewMissionDialogFake(
            candidateProjectIds: ["alas", "alas-clone"],
            configuredBases: ["alas": "origin/main", "alas-clone": "trunk"],
            configuredPrefixes: ["alas": "feature/", "alas-clone": "mission/"],
            branchesByProject: [
                "alas": ["origin/main"],
                "alas-clone": ["release", "trunk"],
            ]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        let actions = NewMissionDialogActions(model: model, dismiss: {})
        model.reference = "#1842"
        await model.resolve()

        actions.branch.wrappedValue = "nacho/keep-this-branch"
        model.prompt = "Keep this independently edited prompt."
        await model.selectProject("alas-clone")

        #expect(model.base == "trunk")
        #expect(model.branch == "nacho/keep-this-branch")
        #expect(model.prompt == "Keep this independently edited prompt.")
    }

    @Test("an edited base survives a project branch refresh")
    func projectChangePreservesEditedBase() async {
        let fake = NewMissionDialogFake(
            candidateProjectIds: ["alas", "alas-clone"],
            configuredBases: ["alas": "origin/main", "alas-clone": "trunk"],
            configuredPrefixes: ["alas": "feature/", "alas-clone": "mission/"],
            branchesByProject: [
                "alas": ["origin/main"],
                "alas-clone": ["release", "trunk"],
            ]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        let actions = NewMissionDialogActions(model: model, dismiss: {})
        model.reference = "#1842"
        await model.resolve()

        actions.base.wrappedValue = "release/next"
        await model.selectProject("alas-clone")

        #expect(model.base == "release/next")
        #expect(model.branch == "mission/1842-fix-offline-sync-conflicts")
    }

    @Test("a base edited away and back remains user-owned across project changes")
    func projectChangePreservesBaseEditedBackToSeed() async {
        let fake = NewMissionDialogFake(
            candidateProjectIds: ["alas", "alas-clone"],
            configuredBases: ["alas": "origin/main", "alas-clone": "trunk"],
            configuredPrefixes: ["alas": "feature/", "alas-clone": "mission/"],
            branchesByProject: [
                "alas": ["origin/main"],
                "alas-clone": ["release", "trunk"],
            ]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        let actions = NewMissionDialogActions(model: model, dismiss: {})
        model.reference = "#1842"
        await model.resolve()

        actions.base.wrappedValue = "release/next"
        actions.base.wrappedValue = "origin/main"
        await model.selectProject("alas-clone")

        #expect(model.base == "origin/main")
        #expect(model.branch == "mission/1842-fix-offline-sync-conflicts")
    }

    @Test("a branch edited away and back remains user-owned across project changes")
    func projectChangePreservesBranchEditedBackToSeed() async {
        let fake = NewMissionDialogFake(
            candidateProjectIds: ["alas", "alas-clone"],
            configuredBases: ["alas": "origin/main", "alas-clone": "trunk"],
            configuredPrefixes: ["alas": "feature/", "alas-clone": "mission/"],
            branchesByProject: [
                "alas": ["origin/main"],
                "alas-clone": ["release", "trunk"],
            ]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        let actions = NewMissionDialogActions(model: model, dismiss: {})
        model.reference = "#1842"
        await model.resolve()

        actions.branch.wrappedValue = "nacho/custom"
        actions.branch.wrappedValue = "feature/1842-fix-offline-sync-conflicts"
        await model.selectProject("alas-clone")

        #expect(model.base == "trunk")
        #expect(model.branch == "feature/1842-fix-offline-sync-conflicts")
    }

    @Test("the first enabled ACP-capable agent is the default")
    func defaultAgentSkipsNonACPAgents() async {
        let fake = NewMissionDialogFake(agents: [
            Self.agent(id: "terminal-only"),
            Self.agent(id: "codex"),
            Self.agent(id: "claude"),
        ])
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"

        await model.resolve()

        #expect(model.agentOptions.map(\.id) == ["codex", "claude"])
        #expect(model.agentId == "codex")
        #expect(model.validationMessage == nil)
        #expect(model.canCreate)
    }

    @Test("confirmation rejects creation without an enabled ACP agent")
    func noCapableAgentProducesValidation() async {
        let fake = NewMissionDialogFake(agents: [Self.agent(id: "terminal-only")])
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"
        await model.resolve()

        #expect(model.agentOptions.isEmpty)
        #expect(model.agentId.isEmpty)
        #expect(model.validationMessage == "Enable an ACP-capable agent in Settings before creating a Mission.")
        #expect(!model.canCreate)
        #expect(await model.create(allowDuplicate: false) == nil)
        #expect(fake.createdDrafts.isEmpty)
    }

    @Test("duplicate offers opening the existing Mission")
    func duplicateCanOpenExistingMission() async {
        let existing = MissionID(rawValue: "existing-mission")
        let fake = NewMissionDialogFake(duplicateMissionID: existing)
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"
        await model.resolve()

        #expect(await model.create(allowDuplicate: false) == nil)
        #expect(model.phase == .confirmation)
        #expect(model.existingMissionID == existing)

        #expect(model.openExistingMission() == existing)
        #expect(fake.openedMissionIDs == [existing])
    }

    @Test("duplicate identity comparison ignores host and repository casing")
    func duplicateIdentityComparisonIgnoresRepositoryCase() {
        let stored = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 1842
        )
        let resolved = MissionIssueIdentity(
            provider: .github,
            host: "GitHub.com",
            repositorySlug: "Acme/Alas",
            number: 1842
        )

        #expect(stored == resolved)
    }

    @Test("generated branch skips branches retained by an earlier Mission")
    func generatedBranchSkipsExistingMissionArtifacts() async {
        let seed = MissionBranchName.make(
            issueNumber: 1842,
            title: "Fix offline sync conflicts",
            prefix: "feature/"
        )
        let fake = NewMissionDialogFake(
            branchesByProject: ["alas": ["origin/main", "main", seed, "\(seed)-2"]]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"

        await model.resolve()

        #expect(model.branch == "\(seed)-3")
    }

    @Test("generated branch skips matching remote-tracking branches")
    func generatedBranchSkipsRemoteTrackingBranches() async {
        let seed = MissionBranchName.make(
            issueNumber: 1842,
            title: "Fix offline sync conflicts",
            prefix: "feature/"
        )
        let fake = NewMissionDialogFake(branchesByProject: [
            "alas": ["origin/main", "main", "origin/\(seed)", "origin/\(seed)-2"],
        ])
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"

        await model.resolve()

        #expect(model.branch == "\(seed)-3")
    }

    @Test("generated branch checks every configured remote")
    func generatedBranchSkipsCustomRemoteTrackingBranches() async {
        let seed = MissionBranchName.make(
            issueNumber: 1842,
            title: "Fix offline sync conflicts",
            prefix: "feature/"
        )
        let fake = NewMissionDialogFake(
            configuredBases: ["alas": "main"],
            branchesByProject: ["alas": ["fork/\(seed)", "fork/\(seed)-2"]],
            remoteNamesByProject: ["alas": ["fork"]]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"

        await model.resolve()

        #expect(model.branch == "\(seed)-3")
    }

    @Test("duplicate can be created only with an explicit override")
    func duplicateCanCreateAnotherMission() async {
        let fake = NewMissionDialogFake(duplicateMissionID: .init(rawValue: "existing-mission"))
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"
        await model.resolve()

        #expect(await model.create(allowDuplicate: false) == nil)
        let originalBranch = model.branch
        #expect(await model.create(allowDuplicate: true) == nil)
        #expect(model.errorMessage == "Choose a different branch for the additional Mission.")
        #expect(model.prepareDuplicateCreation())
        let created = await model.create(allowDuplicate: true)

        #expect(created == MissionID(rawValue: "new-mission"))
        #expect(fake.createAllowDuplicateValues == [false, true])
        #expect(fake.createdDrafts.last?.branch == "\(originalBranch)-2")
        #expect(fake.createdDrafts.last?.destinationPath != fake.createdDrafts.first?.destinationPath)
    }

    @Test("create skips occupied destinations when the template ignores the branch")
    func createSkipsOccupiedDestinationFromBranchlessTemplate() async {
        let fixed = URL(fileURLWithPath: "/tmp/worktrees/alas/fixed")
        let fake = NewMissionDialogFake(
            destination: { _, _ in fixed },
            occupiedDestinationPaths: [fixed.path, "\(fixed.path)-2"]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"
        await model.resolve()

        let created = await model.create(allowDuplicate: false)

        #expect(created == MissionID(rawValue: "new-mission"))
        #expect(fake.createdDrafts.last?.destinationPath == "\(fixed.path)-3")
    }

    @Test("duplicate suffix skips active Mission reservations")
    func duplicateSuffixSkipsActiveMissionReservations() async {
        let seed = MissionBranchName.make(
            issueNumber: 1842,
            title: "Fix offline sync conflicts",
            prefix: "feature/"
        )
        let fake = NewMissionDialogFake(
            duplicateMissionID: .init(rawValue: "existing-mission"),
            reservedBranchesByProject: ["alas": ["\(seed)-2"]]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"
        await model.resolve()
        #expect(await model.create(allowDuplicate: false) == nil)

        #expect(model.prepareDuplicateCreation())

        #expect(model.branch == "\(seed)-3")
    }

    @Test("create failure keeps the editable confirmation visible")
    func createFailureKeepsConfirmationVisible() async {
        let fake = NewMissionDialogFake(createError: NewMissionDialogFake.TestError.createFailed)
        let model = NewMissionDialogModel(environment: fake.environment)
        model.reference = "#1842"
        await model.resolve()

        let result = await model.create(allowDuplicate: false)

        #expect(result == nil)
        #expect(model.phase == .confirmation)
        #expect(model.errorMessage == "Mission insertion failed.")
        #expect(model.resolved != nil)
    }

    @Test("create returns only after the durable Mission insertion succeeds")
    func successfulCreateBuildsDraftAndReturnsDurableID() async throws {
        let fake = NewMissionDialogFake(
            configuredBases: ["alas": "upstream/main"],
            branchesByProject: ["alas": ["upstream/main", "main"]],
            remoteNamesByProject: ["alas": ["upstream"]]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        let actions = NewMissionDialogActions(model: model, dismiss: {})
        model.reference = "#1842"
        await model.resolve()
        actions.base.wrappedValue = "  upstream/main  "
        actions.branch.wrappedValue = "  feature/1842-custom  "
        model.prompt = "Custom prompt"

        let result = await model.create(allowDuplicate: false)
        let draft = try #require(fake.createdDrafts.first)

        #expect(result == MissionID(rawValue: "new-mission"))
        #expect(fake.missionWasDurableBeforeCreateReturned)
        #expect(draft.issue.identity.number == 1842)
        #expect(draft.projectId == "alas")
        #expect(draft.baseRef == "upstream/main")
        #expect(draft.baseRemoteName == "upstream")
        #expect(draft.branch == "feature/1842-custom")
        #expect(draft.destinationPath == "/tmp/worktrees/alas/feature-1842-custom")
        #expect(draft.agentId == "codex")
        #expect(draft.initialPrompt == "Custom prompt")
    }

    @Test("create records an unqualified slash base explicitly")
    func createRecordsUnqualifiedSlashBaseExplicitly() async throws {
        let fake = NewMissionDialogFake(
            branchesByProject: ["alas": ["release/1.0", "release/main"]],
            remoteNamesByProject: ["alas": ["origin", "release"]],
            localBranchNamesByProject: ["alas": ["release/1.0"]]
        )
        let model = NewMissionDialogModel(environment: fake.environment)
        let actions = NewMissionDialogActions(model: model, dismiss: {})
        model.reference = "#1842"
        await model.resolve()
        actions.base.wrappedValue = "release/1.0"

        _ = await model.create(allowDuplicate: false)
        let draft = try #require(fake.createdDrafts.first)

        #expect(draft.baseRef == "release/1.0")
        #expect(draft.baseRemoteName == "")
    }

    @Test("the sheet dismisses only after durable Mission insertion succeeds")
    func successfulCreateActionDismissesAfterDurableInsertion() async {
        let fake = NewMissionDialogFake(suspendCreation: true)
        let model = NewMissionDialogModel(environment: fake.environment)
        var didDismiss = false
        let actions = NewMissionDialogActions(model: model) {
            didDismiss = true
        }
        model.reference = "#1842"
        await model.resolve()

        let creation = Task { await actions.create(allowDuplicate: false) }
        await fake.waitUntilCreateStarts()

        #expect(model.phase == .creating)
        #expect(!fake.missionWasDurableBeforeCreateReturned)
        #expect(!didDismiss)

        fake.finishCreation()
        await creation.value

        #expect(fake.missionWasDurableBeforeCreateReturned)
        #expect(didDismiss)
    }

    fileprivate static func agent(id: String) -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: id.capitalized,
            binary: id,
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }
}

@MainActor
private final class NewMissionDialogFake {
    enum TestError: LocalizedError {
        case branchFailed
        case createFailed

        var errorDescription: String? {
            switch self {
            case .branchFailed: "Branch loading failed."
            case .createFailed: "Mission insertion failed."
            }
        }
    }

    let resolvedIssue: ResolvedMissionIssue
    let configuredBases: [String: String]
    let configuredPrefixes: [String: String]
    let branchesByProject: [String: [String]]
    let remoteNamesByProject: [String: Set<String>]
    let localBranchNamesByProject: [String: Set<String>]
    let agents: [AgentDefinition]
    let suspendResolution: Bool
    let suspendBranches: Bool
    let suspendCreation: Bool
    let branchError: (any Error)?
    let duplicateMissionID: MissionID?
    let createError: (any Error)?
    let destination: (String, String) -> URL
    let occupiedDestinationPaths: Set<String>
    let reservedBranchesByProject: [String: [String]]

    private var resolutionContinuation: CheckedContinuation<Void, Never>?
    private var branchContinuation: CheckedContinuation<Void, Never>?
    private var creationContinuation: CheckedContinuation<Void, Never>?
    private(set) var createdDrafts: [MissionDraft] = []
    private(set) var createAllowDuplicateValues: [Bool] = []
    private(set) var openedMissionIDs: [MissionID] = []
    private(set) var missionWasDurableBeforeCreateReturned = false

    init(
        suspendResolution: Bool = false,
        suspendBranches: Bool = false,
        suspendCreation: Bool = false,
        branchError: (any Error)? = nil,
        candidateProjectIds: [String] = ["alas"],
        configuredBases: [String: String] = ["alas": "origin/main"],
        configuredPrefixes: [String: String] = ["alas": "feature/"],
        branchesByProject: [String: [String]] = ["alas": ["origin/main", "main"]],
        remoteNamesByProject: [String: Set<String>] = ["alas": ["origin"]],
        localBranchNamesByProject: [String: Set<String>] = ["alas": ["main"]],
        agents: [AgentDefinition] = [NewMissionDialogTests.agent(id: "codex")],
        duplicateMissionID: MissionID? = nil,
        createError: (any Error)? = nil,
        destination: @escaping (String, String) -> URL = { projectID, branch in
            URL(fileURLWithPath: "/tmp/worktrees/\(projectID)/\(branch.replacingOccurrences(of: "/", with: "-"))")
        },
        occupiedDestinationPaths: Set<String> = [],
        reservedBranchesByProject: [String: [String]] = [:]
    ) {
        self.suspendResolution = suspendResolution
        self.suspendBranches = suspendBranches
        self.suspendCreation = suspendCreation
        self.branchError = branchError
        self.configuredBases = configuredBases
        self.configuredPrefixes = configuredPrefixes
        self.branchesByProject = branchesByProject
        self.remoteNamesByProject = remoteNamesByProject
        self.localBranchNamesByProject = localBranchNamesByProject
        self.agents = agents
        self.duplicateMissionID = duplicateMissionID
        self.createError = createError
        self.destination = destination
        self.occupiedDestinationPaths = occupiedDestinationPaths
        self.reservedBranchesByProject = reservedBranchesByProject
        let snapshot = MissionIssueSnapshot(
            identity: .init(
                provider: .github,
                host: "github.com",
                repositorySlug: "mrmans0n/alas",
                number: 1842
            ),
            canonicalURL: URL(string: "https://github.com/mrmans0n/alas/issues/1842")!,
            title: "Fix offline sync conflicts",
            body: "Offline changes can overwrite newer server changes.",
            state: .open,
            labels: ["bug", "sync"],
            assignees: ["nacho"],
            providerUpdatedAt: Date(timeIntervalSince1970: 100),
            capturedAt: Date(timeIntervalSince1970: 101),
            refreshError: nil
        )
        self.resolvedIssue = ResolvedMissionIssue(
            snapshot: snapshot,
            remote: .init(
                kind: .github,
                host: "github.com",
                owner: "mrmans0n",
                repository: "alas",
                remoteName: "origin",
                webURL: URL(string: "https://github.com/mrmans0n/alas")!
            ),
            candidateProjectIds: candidateProjectIds,
            selectedProjectId: candidateProjectIds[0]
        )
    }

    var environment: NewMissionDialogModel.Environment {
        .init(
            resolveIssue: { [self] _ in
                if suspendResolution {
                    await withCheckedContinuation { continuation in
                        resolutionContinuation = continuation
                    }
                }
                return resolvedIssue
            },
            branches: { [self] projectID in
                if suspendBranches {
                    await withCheckedContinuation { continuation in
                        branchContinuation = continuation
                    }
                }
                if let branchError { throw branchError }
                return NewMissionDialogModel.BranchInventory(
                    names: branchesByProject[projectID] ?? [],
                    remoteNames: remoteNamesByProject[projectID] ?? [],
                    localBranchNames: localBranchNamesByProject[projectID] ?? []
                )
            },
            configuredBase: { [self] projectID in
                configuredBases[projectID] ?? "main"
            },
            configuredBranchPrefix: { [self] projectID in
                configuredPrefixes[projectID] ?? "feature/"
            },
            reservedBranches: { [self] projectID in
                reservedBranchesByProject[projectID] ?? []
            },
            enabledACPAgents: { [self] in agents },
            destination: { [self] projectID, branch in
                destination(projectID, branch)
            },
            destinationAvailable: { [self] _, destination in
                !occupiedDestinationPaths.contains(destination.standardizedFileURL.path)
            },
            createMission: { [self] draft, allowDuplicate in
                createdDrafts.append(draft)
                createAllowDuplicateValues.append(allowDuplicate)
                if suspendCreation {
                    await withCheckedContinuation { continuation in
                        creationContinuation = continuation
                    }
                }
                if let duplicateMissionID, !allowDuplicate {
                    throw NewMissionDialogModel.CreationError.duplicate(existing: duplicateMissionID)
                }
                if let createError { throw createError }
                missionWasDurableBeforeCreateReturned = true
                return MissionID(rawValue: "new-mission")
            },
            openMission: { [self] missionID in
                openedMissionIDs.append(missionID)
            }
        )
    }

    func waitUntilResolutionStarts() async {
        while resolutionContinuation == nil {
            await Task.yield()
        }
    }

    func finishResolution() {
        resolutionContinuation?.resume()
        resolutionContinuation = nil
    }

    func waitUntilBranchLoadStarts() async {
        while branchContinuation == nil {
            await Task.yield()
        }
    }

    func finishBranchLoad() {
        branchContinuation?.resume()
        branchContinuation = nil
    }

    func waitUntilCreateStarts() async {
        while creationContinuation == nil {
            await Task.yield()
        }
    }

    func finishCreation() {
        creationContinuation?.resume()
        creationContinuation = nil
    }
}
