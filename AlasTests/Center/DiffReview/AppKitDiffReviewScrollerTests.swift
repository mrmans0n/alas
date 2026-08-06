import Testing
@testable import Alas

@Suite("AppKitDiffReviewScroller")
struct AppKitDiffReviewScrollerTests {
    @Test func switchFollowsRuntimeFlag() {
        #expect(DiffReviewSurface.usesAppKitScroller(flagEnabled: true))
        #expect(!DiffReviewSurface.usesAppKitScroller(flagEnabled: false))
    }

    @Test func fileCommandsTargetHeadersAtTop() {
        let fileID = fileID()
        let headerID = AppKitDiffReviewRowID.header(fileID: fileID)
        let request = AppKitDiffReviewScrollRequestResolver.request(
            fileCommand: .init(id: fileID, generation: 1),
            inlineFeedbackCommand: nil,
            draftCommentCommand: nil,
            plan: plan(fileID: fileID, headerID: headerID)
        )

        #expect(request?.targetID == headerID)
        #expect(request?.alignment == .top)
    }

    @Test func deferredFeedbackTargetsPlaceholderAtCenter() {
        let fileID = fileID()
        let placeholderID = AppKitDiffReviewRowID.placeholder(fileID: fileID)
        let command = DiffReviewInlineFeedbackScrollCommand(feedbackID: "feedback", fileID: fileID, generation: 1)
        let requestedID = AppKitDiffReviewRowID.inlineFeedback(command.targetID)
        let deferredPlan = plan(
            fileID: fileID,
            fallbackByTargetID: [requestedID: placeholderID],
            placeholderByFileID: [fileID: placeholderID]
        )
        let request = AppKitDiffReviewScrollRequestResolver.request(
            fileCommand: nil,
            inlineFeedbackCommand: command,
            draftCommentCommand: nil,
            plan: deferredPlan
        )

        #expect(request?.targetID == deferredPlan.placeholderByFileID[fileID])
        #expect(request?.alignment == .center)
    }

    @Test func reviewCommandKindsUseDistinctGenerationsAndDoNotNeedRealizationDelay() {
        let fileID = fileID()
        let file = DiffReviewScrollCommand(id: fileID, generation: 1)
        let feedback = DiffReviewInlineFeedbackScrollCommand(feedbackID: "feedback", fileID: fileID, generation: 1)
        let draft = DiffReviewDraftCommentScrollCommand(commentID: "draft", fileID: fileID, generation: 1)
        let plan = plan(fileID: fileID)
        let fileRequest = AppKitDiffReviewScrollRequestResolver.request(
            fileCommand: file, inlineFeedbackCommand: nil, draftCommentCommand: nil, plan: plan
        )
        let feedbackRequest = AppKitDiffReviewScrollRequestResolver.request(
            fileCommand: nil, inlineFeedbackCommand: feedback, draftCommentCommand: nil, plan: plan
        )
        let draftRequest = AppKitDiffReviewScrollRequestResolver.request(
            fileCommand: nil, inlineFeedbackCommand: nil, draftCommentCommand: draft, plan: plan
        )

        #expect(fileRequest?.generation != feedbackRequest?.generation)
        #expect(feedbackRequest?.generation != draftRequest?.generation)
        #expect(fileRequest?.generation != draftRequest?.generation)
        #expect(feedbackRequest?.alignment == .center)
        #expect(draftRequest?.alignment == .center)
    }

    @Test func missingReviewItemsFallBackToTheFileHeader() {
        let fileID = fileID()
        let feedback = DiffReviewInlineFeedbackScrollCommand(feedbackID: "missing", fileID: fileID, generation: 1)
        let request = AppKitDiffReviewScrollRequestResolver.request(
            fileCommand: nil, inlineFeedbackCommand: feedback, draftCommentCommand: nil, plan: plan(fileID: fileID)
        )

        #expect(request?.fallbackID == AppKitDiffReviewRowID.header(fileID: fileID))
    }

    @Test func newestCommandWinsAcrossKinds() {
        let firstFileID = fileID()
        let secondFileID = DiffReviewFileID(namespace: "review", path: "Sources/Second.swift")
        let plan = plan(fileID: firstFileID, headerID: "first-header")
        var coordinator = AppKitDiffReviewScrollRequestCoordinator()

        let feedbackRequest = coordinator.request(
            for: .inlineFeedback(.init(feedbackID: "feedback", fileID: firstFileID, generation: 1)),
            plan: plan
        )
        let fileRequest = coordinator.request(
            for: .file(.init(id: secondFileID, generation: 1)),
            plan: plan
        )

        #expect(feedbackRequest.targetID == AppKitDiffReviewRowID.inlineFeedback(
            .targetID(feedbackID: "feedback", fileID: firstFileID)
        ))
        #expect(fileRequest.targetID == AppKitDiffReviewRowID.header(fileID: secondFileID))
        #expect(fileRequest.generation > feedbackRequest.generation)
    }

    @Test func completionOnlyReleasesTheNewestAppKitNavigationRequest() {
        var gate = AppKitDiffReviewScrollCompletionGate()

        gate.begin(requestGeneration: 1)
        gate.begin(requestGeneration: 2)

        let consumedStaleCompletion = gate.consumesCompletion(for: 1)
        #expect(gate.pendingRequestGeneration == 2)
        let consumedCurrentCompletion = gate.consumesCompletion(for: 2)

        #expect(!consumedStaleCompletion)
        #expect(consumedCurrentCompletion)
        #expect(gate.pendingRequestGeneration == nil)
    }

    private func fileID() -> DiffReviewFileID {
        DiffReviewFileID(namespace: "review", path: "Sources/Example.swift")
    }

    private func plan(
        fileID: DiffReviewFileID,
        headerID: String? = nil,
        fallbackByTargetID: [String: String] = [:],
        placeholderByFileID: [DiffReviewFileID: String] = [:]
    ) -> AppKitDiffReviewRowPlan {
        .init(
            corePlan: .init(rows: []),
            fallbackByTargetID: fallbackByTargetID,
            headerByFileID: [fileID: headerID ?? AppKitDiffReviewRowID.header(fileID: fileID)],
            placeholderByFileID: placeholderByFileID
        )
    }
}
