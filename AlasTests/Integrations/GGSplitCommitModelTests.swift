import Foundation
import Testing
@testable import Alas

@MainActor
struct GGSplitCommitModelTests {
    @Test func remainderPreviewClassifiesOnlySupportedImagesForVisualPreview() {
        let paths = ["Assets/logo.png", "Archive/data.zip", "Scripts/run.sh"]

        let result = GGResultingImagePreview.partition(paths)

        #expect(result.imagePaths == ["Assets/logo.png"])
        #expect(result.otherPaths == ["Archive/data.zip", "Scripts/run.sh"])
    }

    @Test func loadGroupsTextHunksAndKeepsNonTextualFilesInRemainderOnly() async throws {
        let service = SplitServiceStub(description: .fixture)
        let model = GGSplitCommitModel(
            service: service,
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true
        )

        try await model.load()

        #expect(model.targetSHA == "abc123")
        #expect(model.targetTree == "tree123")
        #expect(model.targetGGID == "change-2")
        #expect(model.planToken == "split-v1-token")
        #expect(model.fileGroups.map(\.path) == ["Sources/A.swift", "Sources/B.swift", "Assets/logo.png"])
        #expect(model.fileGroups[0].hunks.map(\.id) == ["h-1", "h-2"])
        #expect(model.fileGroups[1].hunks.map(\.id) == ["h-3"])
        #expect(model.fileGroups[2].kind == .remainderOnly)
        #expect(model.fileGroups[2].hunks.isEmpty)
        #expect(model.selectedHunkIDs.isEmpty)
    }

    @Test func fileGroupIDsStayUniqueWhenPathHasTextAndRemainder() async throws {
        let service = SplitServiceStub(description: .collidingPathFixture)
        let model = GGSplitCommitModel(
            service: service,
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true
        )

        try await model.load()

        let sameA = model.fileGroups.filter { $0.path == "Sources/A.swift" }
        #expect(sameA.map(\.kind) == [.selectable, .remainderOnly])
        let ids = model.fileGroups.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func toggleSelectionAcceptsOnlyDescribedTextHunks() async throws {
        let model = makeModel()
        try await model.load()

        model.toggleHunk("h-2")
        #expect(model.selectedHunkIDs == ["h-2"])
        model.toggleHunk("h-2")
        #expect(model.selectedHunkIDs.isEmpty)
        model.toggleHunk("Assets/logo.png")
        model.toggleHunk("unknown")
        #expect(model.selectedHunkIDs.isEmpty)
    }

    @Test func applyRequiresNonEmptyProperSubset() async throws {
        let model = GGSplitCommitModel(
            service: SplitServiceStub(description: .textualOnlyFixture),
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true
        )
        try await model.load()

        #expect(throws: GGSplitCommitValidationError.emptySelection) {
            _ = try model.validatedPlan()
        }

        model.selectedHunkIDs = Set(model.description.hunks.map(\.id))
        #expect(throws: GGSplitCommitValidationError.allHunksSelected) {
            _ = try model.validatedPlan()
        }
    }

    @Test func applyAllowsAllTextualHunksWhenNonTextualFilesRemain() async throws {
        let model = makeModel()
        try await model.load()
        model.selectedHunkIDs = Set(model.description.hunks.map(\.id))

        let plan = try model.validatedPlan()

        #expect(plan.selectedHunkIDs == ["h-1", "h-2", "h-3"])
        #expect(model.remainderPreview.files.isEmpty)
        #expect(model.remainderPreview.nonTextualFiles == ["Assets/logo.png"])
    }

    @Test func applyAllowsAllTextualHunksWhenModeOnlyChangeRemains() async throws {
        let description = GGSplitDescription(
            version: GGSplitDescription.fixture.version,
            planToken: GGSplitDescription.fixture.planToken,
            target: GGSplitDescription.fixture.target,
            hunks: GGSplitDescription.fixture.hunks,
            nonTextualFiles: ["Scripts/run.sh"],
            firstMessage: GGSplitDescription.fixture.firstMessage,
            remainderMessage: GGSplitDescription.fixture.remainderMessage
        )
        let model = GGSplitCommitModel(
            service: SplitServiceStub(description: description),
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true
        )
        try await model.load()
        model.selectedHunkIDs = Set(model.description.hunks.map(\.id))

        let plan = try model.validatedPlan()

        #expect(plan.selectedHunkIDs == ["h-1", "h-2", "h-3"])
        #expect(model.remainderPreview.nonTextualFiles == ["Scripts/run.sh"])
    }

    @Test func loadRestoresSavedSplitDraftForLiveHunks() async throws {
        let model = GGSplitCommitModel(
            service: SplitServiceStub(description: .fixture),
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true,
            initialDraft: GGSplitCommitDraft(
                selectedHunkIDs: ["h-2", "removed-hunk"],
                firstMessage: "Extract parser",
                remainderMessage: "Keep renderer"
            )
        )

        try await model.load()

        #expect(model.draft == GGSplitCommitDraft(
            selectedHunkIDs: ["h-2"],
            firstMessage: "Extract parser",
            remainderMessage: "Keep renderer"
        ))
    }

    @Test func applyValidatesMessagesIndependentlyAndTrimsThem() async throws {
        let model = makeModel()
        try await model.load()
        model.selectedHunkIDs = ["h-1"]

        model.firstMessage = " \n "
        model.remainderMessage = "Remainder"
        #expect(throws: GGSplitCommitValidationError.emptyFirstMessage) {
            _ = try model.validatedPlan()
        }

        model.firstMessage = "  First commit  "
        model.remainderMessage = "\t"
        #expect(throws: GGSplitCommitValidationError.emptyRemainderMessage) {
            _ = try model.validatedPlan()
        }

        model.remainderMessage = "  Remainder commit  "
        let plan = try model.validatedPlan()
        #expect(plan.firstMessage == "First commit")
        #expect(plan.remainderMessage == "Remainder commit")
    }

    @Test func previewsPartitionTextHunksAndKeepNonTextualFilesInRemainder() async throws {
        let model = makeModel()
        try await model.load()
        model.selectedHunkIDs = ["h-2", "h-3"]

        #expect(model.firstPreview.files.map(\.path) == ["Sources/A.swift", "Sources/B.swift"])
        #expect(model.firstPreview.files.flatMap(\.hunkIDs) == ["h-2", "h-3"])
        #expect(model.firstPreview.nonTextualFiles.isEmpty)
        #expect(model.remainderPreview.files.map(\.path) == ["Sources/A.swift"])
        #expect(model.remainderPreview.files.flatMap(\.hunkIDs) == ["h-1"])
        #expect(model.remainderPreview.nonTextualFiles == ["Assets/logo.png"])
        #expect(model.firstPreview.files[0].diff.hunks.first?.header == "@@ -10 +10 @@")
    }

    @Test func capabilityDisabledPresentationExplainsRequiredUpdate() {
        let model = GGSplitCommitModel(
            service: SplitServiceStub(description: .fixture),
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: false, keepCurrentUnstack: true),
            workflowAvailable: true
        )

        #expect(!model.isAvailable)
        #expect(model.unavailableReason == "Update GG to use native Split Commit")
        #expect(!model.canApply)
    }

    @Test func workflowDisabledPreventsLoadDespiteStructuredSplitCapability() async {
        let service = SplitServiceStub(description: .fixture)
        let model = GGSplitCommitModel(
            service: service,
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: false
        )

        #expect(!model.isAvailable)
        #expect(model.unavailableReason == "Native Split Commit is unavailable.")
        await #expect(throws: GGSplitCommitValidationError.unavailable) {
            try await model.load()
        }
        #expect(service.loadCallCount == 0)
        #expect(throws: GGSplitCommitValidationError.unavailable) {
            _ = try model.validatedPlan()
        }
    }

    @Test func loadAndApplyErrorPresentationUsesGGServiceUserMessage() {
        #expect(
            GGErrorPresentation.message(for: GGServiceError.cliMissing)
                == "gg is not installed."
        )
        #expect(
            GGErrorPresentation.message(
                for: GGServiceError.undoRefused(message: "Cannot undo.", hint: "Run gg sync first.")
            ) == "Cannot undo.\nRun gg sync first."
        )

        let unrelatedError = CocoaError(.fileReadNoSuchFile)
        #expect(
            GGErrorPresentation.message(for: unrelatedError)
                == unrelatedError.localizedDescription
        )
    }

    @Test func applyWritesPrivateAtomicPlanAndDeletesItAfterSuccess() async throws {
        let service = SplitServiceStub(description: .fixture)
        let model = GGSplitCommitModel(
            service: service,
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true
        )
        try await model.load()
        model.selectedHunkIDs = ["h-1"]

        try await model.apply()

        let appliedPlan = try #require(service.appliedPlan)
        #expect(appliedPlan.selectedHunkIDs == ["h-1"])
        #expect(service.planExistsDuringApply)
        #expect(service.planPermissionsDuringApply == 0o600)
        #expect(service.confirmedIdentity == .fixture)
        let planURL = try #require(service.planURL)
        #expect(!FileManager.default.fileExists(atPath: planURL.path))
        #expect(!FileManager.default.fileExists(atPath: planURL.deletingLastPathComponent().path))
    }

    @Test func staleApplyPreservesEditablePlanAndDeletesPrivateFile() async throws {
        let service = SplitServiceStub(
            description: .fixture,
            applyError: GGServiceError.staleSplitPlan(message: "stale split plan")
        )
        let model = GGSplitCommitModel(
            service: service,
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true
        )
        try await model.load()
        model.selectedHunkIDs = ["h-1"]
        model.firstMessage = "Extract parser"
        model.remainderMessage = "Keep renderer"

        await #expect(throws: GGServiceError.staleSplitPlan(message: "stale split plan")) {
            try await model.apply()
        }

        #expect(model.selectedHunkIDs == ["h-1"])
        #expect(model.firstMessage == "Extract parser")
        #expect(model.remainderMessage == "Keep renderer")
        let planURL = try #require(service.planURL)
        #expect(!FileManager.default.fileExists(atPath: planURL.path))
        #expect(!FileManager.default.fileExists(atPath: planURL.deletingLastPathComponent().path))
    }

    private func makeModel() -> GGSplitCommitModel {
        GGSplitCommitModel(
            service: SplitServiceStub(description: .fixture),
            target: .fixture,
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true
        )
    }
}

@MainActor
private final class SplitServiceStub: GGSplitCommitServicing {
    let description: GGSplitDescription
    let applyError: Error?
    private(set) var planURL: URL?
    private(set) var appliedPlan: GGSplitPlan?
    private(set) var planExistsDuringApply = false
    private(set) var planPermissionsDuringApply: Int?
    private(set) var confirmedIdentity: GGStackIdentity?
    private(set) var loadCallCount = 0

    init(description: GGSplitDescription, applyError: Error? = nil) {
        self.description = description
        self.applyError = applyError
    }

    func loadDescription(target: GGSplitCommitTarget) async throws -> GGSplitLoadedDescription {
        loadCallCount += 1
        #expect(target == .fixture)
        return GGSplitLoadedDescription(description: description, stackIdentity: .fixture)
    }

    func applySplit(
        planURL: URL,
        target: GGSplitTargetIdentity,
        planToken: String,
        confirmedAgainst identity: GGStackIdentity
    ) async throws {
        self.planURL = planURL
        confirmedIdentity = identity
        planExistsDuringApply = FileManager.default.fileExists(atPath: planURL.path)
        planPermissionsDuringApply = (try? FileManager.default.attributesOfItem(atPath: planURL.path)[.posixPermissions]) as? Int
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        appliedPlan = try decoder.decode(GGSplitPlan.self, from: Data(contentsOf: planURL))
        #expect(target == description.target)
        #expect(planToken == description.planToken)
        if let applyError { throw applyError }
    }
}

private extension GGSplitCommitTarget {
    static let fixture = GGSplitCommitTarget(
        worktreeId: "wt",
        targetGGID: "change-2",
        targetSHA: "abc123"
    )
}

private extension GGStackIdentity {
    static let fixture = GGStackIdentity(
        stackName: "stack",
        base: "main",
        headSHA: "head",
        operationID: nil
    )
}

private extension GGSplitDescription {
    static let fixture = GGSplitDescription(
        version: 1,
        planToken: "split-v1-token",
        target: GGSplitTargetIdentity(ggID: "change-2", sha: "abc123", tree: "tree123"),
        hunks: [
            GGSplitHunk(id: "h-1", path: "Sources/A.swift", header: "@@ -1 +1 @@", patch: "-old one\n+new one\n"),
            GGSplitHunk(id: "h-2", path: "Sources/A.swift", header: "@@ -10 +10 @@", patch: "-old two\n+new two\n"),
            GGSplitHunk(id: "h-3", path: "Sources/B.swift", header: "@@ -2 +2 @@", patch: "-before\n+after\n"),
        ],
        nonTextualFiles: ["Assets/logo.png"],
        firstMessage: "First commit",
        remainderMessage: "Remainder commit"
    )

    static let collidingPathFixture = GGSplitDescription(
        version: 1,
        planToken: fixture.planToken,
        target: fixture.target,
        hunks: [
            GGSplitHunk(id: "h-1", path: "Sources/A.swift", header: "@@ -1 +1 @@", patch: "-old\n+new\n"),
        ],
        nonTextualFiles: ["Sources/A.swift"],
        firstMessage: fixture.firstMessage,
        remainderMessage: fixture.remainderMessage
    )

    static let textualOnlyFixture = GGSplitDescription(
        version: fixture.version,
        planToken: fixture.planToken,
        target: fixture.target,
        hunks: fixture.hunks,
        nonTextualFiles: [],
        firstMessage: fixture.firstMessage,
        remainderMessage: fixture.remainderMessage
    )
}
