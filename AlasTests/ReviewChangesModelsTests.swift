import Foundation
import Testing
@testable import Alas

struct ReviewChangesModelsTests {
    @Test func triggerSummaryIsNilWhenThereAreNoNonConflictChanges() {
        let changes = [
            changedFile("conflicted.swift", add: 10, del: 2, conflict: .bothModified),
        ]

        #expect(ReviewChangesTriggerSummary.summary(for: changes) == nil)
    }

    @Test func triggerSummaryCountsOnlyNonConflictStagedAndUnstagedChanges() throws {
        let changes = [
            changedFile("staged.swift", stage: .staged, add: 12, del: 3),
            changedFile("unstaged.swift", stage: .unstaged, add: 4, del: 7),
            changedFile("conflicted.swift", stage: .unstaged, add: 20, del: 30, conflict: .bothModified),
        ]

        let summary = try #require(ReviewChangesTriggerSummary.summary(for: changes))

        #expect(summary.fileCount == 2)
        #expect(summary.additions == 16)
        #expect(summary.deletions == 10)
    }

    @Test func triggerSummaryHidesLineCountsForDuplicatePaths() throws {
        let changes = [
            changedFile("same.swift", stage: .staged, add: 99, del: 88),
            changedFile("same.swift", stage: .unstaged, add: 99, del: 88),
        ]

        let summary = try #require(ReviewChangesTriggerSummary.summary(for: changes))

        #expect(summary.fileCount == 2)
        #expect(summary.additions == nil)
        #expect(summary.deletions == nil)
    }

    @Test func fileIdentityIncludesSourceAndPath() {
        let unstaged = ReviewChangesFileID(namespace: "unstaged", path: "Sources/App.swift")
        let staged = ReviewChangesFileID(namespace: "staged", path: "Sources/App.swift")

        #expect(unstaged.rawValue == "unstaged:Sources/App.swift")
        #expect(staged.rawValue == "staged:Sources/App.swift")
        #expect(unstaged != staged)
    }

    @Test func buildsFlattenedDirectoryTreeWithDirectoriesBeforeFiles() {
        let files = [
            reviewSummary(
                path: "Sources/Center/DiffPaneView.swift",
                source: .unstaged,
                status: .modified,
                additions: 12,
                deletions: 3,
                isRenderable: true
            ),
            reviewSummary(
                path: "README.md",
                source: .unstaged,
                status: .added,
                additions: 4,
                deletions: 0,
                isRenderable: true
            ),
        ]

        let tree = ReviewChangesFileTreeBuilder.build(files: files)

        #expect(tree.map(\.name) == ["Sources/Center", "README.md"])
        #expect(tree[0].kind == .directory)
        #expect(tree[0].path == "Sources/Center")
        #expect(tree[0].children?.map(\.name) == ["DiffPaneView.swift"])
        #expect(tree[0].children?.first?.file?.path == "Sources/Center/DiffPaneView.swift")
    }

    @Test func sessionTotalsIncludeAllFiles() {
        let files = [
            reviewSummary(
                path: "a.swift",
                source: .unstaged,
                status: .modified,
                additions: 3,
                deletions: 1,
                isRenderable: true
            ),
            reviewSummary(
                path: "b.swift",
                source: .staged,
                status: .deleted,
                additions: 0,
                deletions: 5,
                isRenderable: false
            ),
        ]

        let session = ReviewChangesSessionModel(files: files, groupsEnabled: true)

        #expect(session.fileCount == 2)
        #expect(session.totalAdditions == 3)
        #expect(session.totalDeletions == 6)
        #expect(session.groups.map(\.id) == ["unstaged", "staged"])
        #expect(session.groups.map(\.title) == ["Unstaged", "Staged"])
        #expect(session.sections.map(\.source) == [.unstaged, .staged])
    }

    @Test func fileSummarySourceCompatibilityUsesReviewChangesSource() {
        let summary = reviewSummary(
            path: "a.swift",
            source: .unstaged,
            status: .modified,
            additions: 1,
            deletions: 0,
            isRenderable: true
        )

        #expect(summary.source == .unstaged)
    }

    @Test func sourceSectionsPrebuildTreeShape() throws {
        let files = [
            reviewSummary(
                path: "Sources/App/Alpha.swift",
                source: .unstaged,
                status: .modified,
                additions: 1,
                deletions: 0,
                isRenderable: true
            ),
            reviewSummary(
                path: "Sources/App/Beta.swift",
                source: .unstaged,
                status: .added,
                additions: 2,
                deletions: 0,
                isRenderable: true
            ),
            reviewSummary(
                path: "README.md",
                source: .staged,
                status: .modified,
                additions: 1,
                deletions: 1,
                isRenderable: true
            ),
        ]

        let session = ReviewChangesSessionModel(files: files, groupsEnabled: true)
        let unstaged = try #require(session.groups.first { $0.id == "unstaged" })
        let staged = try #require(session.groups.first { $0.id == "staged" })

        #expect(unstaged.tree.map(\.name) == ["Sources/App"])
        #expect(unstaged.tree.first?.children?.map(\.name) == ["Alpha.swift", "Beta.swift"])
        #expect(staged.tree.map(\.name) == ["README.md"])
    }

    @Test func fileSummaryDecodingDerivesIdentityFromNamespaceAndPath() throws {
        let data = Data("""
        {
          "id": {
            "namespace": "staged",
            "path": "Other.swift"
          },
          "path": "Sources/App.swift",
          "namespace": "unstaged",
          "groupID": "unstaged",
          "groupTitle": "Unstaged",
          "status": "modified",
          "additions": 8,
          "deletions": 2,
          "isRenderable": true
        }
        """.utf8)

        let summary = try JSONDecoder().decode(ReviewChangesFileSummary.self, from: data)

        #expect(summary.id == ReviewChangesFileID(namespace: "unstaged", path: "Sources/App.swift"))
        #expect(summary.path == "Sources/App.swift")
        #expect(summary.reviewChangesSource == .unstaged)
        #expect(summary.groupID == "unstaged")
    }

    @Test func groupedSessionOrdersDuplicatePathsUnstagedBeforeStaged() {
        let files = [
            reviewSummary(
                path: "Sources/App.swift",
                source: .staged,
                status: .modified,
                additions: 1,
                deletions: 0,
                isRenderable: true
            ),
            reviewSummary(
                path: "Sources/App.swift",
                source: .unstaged,
                status: .modified,
                additions: 2,
                deletions: 1,
                isRenderable: true
            ),
        ]

        let session = ReviewChangesSessionModel(files: files, groupsEnabled: true)

        #expect(session.groups.flatMap(\.files).map(\.id.rawValue) == [
            "unstaged:Sources/App.swift",
            "staged:Sources/App.swift",
        ])
    }

    @Test func preparationStatsFormatFileAndLineCounts() {
        let single = ChangesPreparationCardText.reviewStats(
            fileCount: 1,
            additions: 3,
            deletions: 1
        )
        #expect(single == "1 file · +3 −1")

        let duplicatePath = ChangesPreparationCardText.reviewStats(
            fileCount: 2,
            additions: nil,
            deletions: nil
        )
        #expect(duplicatePath == "2 files")
    }

    @Test func preparationStatsFormatDraftCounts() {
        let staged = ChangesPreparationCardText.draftStats(
            stagedCount: 2,
            additions: 9,
            deletions: 4
        )
        #expect(staged == "2 staged · +9 −4")

        let empty = ChangesPreparationCardText.draftStats(
            stagedCount: 0,
            additions: 0,
            deletions: 0
        )
        #expect(empty == "0 staged")
    }

    @Test func preparationModelShowsReviewActionForNonConflictChangesOnly() throws {
        let changes = [
            changedFile("conflicted.swift", stage: .unstaged, add: 40, del: 5, conflict: .bothModified),
            changedFile("Sources/App.swift", stage: .unstaged, add: 8, del: 2),
        ]

        let model = ChangesPreparationModel(
            changes: changes,
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: []
        )

        #expect(model.isVisible)
        let review = try #require(model.reviewAction)
        #expect(review.fileCount == 1)
        #expect(review.additions == 8)
        #expect(review.deletions == 2)
        #expect(review.title == "Review current changes")
    }

    @Test func preparationModelHidesReviewActionWhenOnlyConflictsExist() {
        let changes = [
            changedFile("conflicted.swift", stage: .unstaged, add: 40, del: 5, conflict: .bothModified),
        ]

        let model = ChangesPreparationModel(
            changes: changes,
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: []
        )

        #expect(model.reviewAction == nil)
        #expect(!model.isVisible)
    }

    @Test func preparationModelShowsDraftActionForStagedChanges() throws {
        let model = ChangesPreparationModel(
            changes: [
                changedFile("Sources/App.swift", stage: .staged, add: 3, del: 1),
                changedFile("Sources/View.swift", stage: .unstaged, add: 9, del: 0),
            ],
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: []
        )

        let draft = try #require(model.draftAction)
        #expect(draft.title == "Draft commit")
        #expect(draft.stagedCount == 1)
        #expect(draft.additions == 3)
        #expect(draft.deletions == 1)
        #expect(!draft.hasNonEmptyDraft)
    }

    @Test func preparationModelShowsExistingDraftWithoutStagedChanges() throws {
        let model = ChangesPreparationModel(
            changes: [],
            hasDraft: true,
            draftNonEmpty: true,
            readinessActions: []
        )

        #expect(model.isVisible)
        let draft = try #require(model.draftAction)
        #expect(draft.title == "Open draft")
        #expect(draft.stagedCount == 0)
        #expect(draft.additions == 0)
        #expect(draft.deletions == 0)
        #expect(draft.hasNonEmptyDraft)
    }

    @Test func preparationModelSelectsSingleReadinessActionByPriority() throws {
        let actions = [
            ReviewReadinessModel.Action(kind: .refresh, title: "Refresh", isEnabled: true),
            ReviewReadinessModel.Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true),
            ReviewReadinessModel.Action(kind: .openReviewRequest, title: "Open PR", isEnabled: true),
            ReviewReadinessModel.Action(kind: .createReviewRequest, title: "Create PR", isEnabled: true),
        ]

        let model = ChangesPreparationModel(
            changes: [],
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: actions
        )

        let reviewRequest = try #require(model.reviewRequestAction)
        #expect(reviewRequest.kind == .createReviewRequest)
        #expect(reviewRequest.title == "Create PR")
    }

    @Test func preparationModelFallsBackToPushBeforeOpenRequest() throws {
        let actions = [
            ReviewReadinessModel.Action(kind: .openReviewRequest, title: "Open PR", isEnabled: true),
            ReviewReadinessModel.Action(kind: .pushBranch, title: "Push", isEnabled: true),
        ]

        let model = ChangesPreparationModel(
            changes: [],
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: actions
        )

        let reviewRequest = try #require(model.reviewRequestAction)
        #expect(reviewRequest.kind == .pushBranch)
        #expect(reviewRequest.title == "Push")
    }

    @Test func preparationModelCanBeBuiltFromReadinessModelActions() throws {
        let readiness = ReviewReadinessModel(
            snapshot: ReviewChangesReadinessFixtures.makeSnapshot(reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        let model = ChangesPreparationModel(
            changes: [changedFile("Sources/App.swift", stage: .unstaged, add: 2, del: 1)],
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: readiness.actions
        )

        #expect(model.reviewAction?.title == "Review current changes")
        #expect(model.reviewRequestAction?.kind == .createReviewRequest)
        #expect(model.reviewRequestAction?.title == "Create PR")
    }
}

private func changedFile(
    _ path: String,
    stage: ChangeStage = .unstaged,
    add: Int,
    del: Int,
    conflict: ConflictKind? = nil
) -> ChangedFile {
    ChangedFile(
        path: path,
        status: "M",
        stage: stage,
        add: add,
        del: del,
        renameFrom: nil,
        conflict: conflict
    )
}

private func reviewSummary(
    path: String,
    source: ReviewChangesSource,
    status: ReviewChangesFileStatus,
    additions: Int,
    deletions: Int,
    isRenderable: Bool,
    originalPath: String? = nil
) -> ReviewChangesFileSummary {
    ReviewChangesFileSummary(
        path: path,
        namespace: source.rawValue,
        groupID: source.rawValue,
        groupTitle: source.title,
        status: status,
        additions: additions,
        deletions: deletions,
        isRenderable: isRenderable,
        originalPath: originalPath
    )
}

private enum ReviewChangesReadinessFixtures {
    static func makeSnapshot(reviewRequest: ReviewRequest?) -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
        return ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: "feature/entrypoint",
                headSHA: "abc123",
                baseBranch: "main",
                hasWorkingTreeChanges: true,
                hasStagedChanges: true,
                aheadCommitCount: 1,
                hasUpstream: true,
                upstreamAheadCommitCount: 0,
                needsPush: false
            ),
            remote: remote,
            reviewRequest: reviewRequest,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }
}
