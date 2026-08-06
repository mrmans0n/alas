import SwiftUI

enum AppKitDiffReviewScrollRequestResolver {
    static func request(
        fileCommand: DiffReviewScrollCommand?,
        inlineFeedbackCommand: DiffReviewInlineFeedbackScrollCommand?,
        draftCommentCommand: DiffReviewDraftCommentScrollCommand?,
        plan: AppKitDiffReviewRowPlan
    ) -> AppKitDiffScrollRequest? {
        if let draftCommentCommand {
            return reviewItemRequest(
                targetID: AppKitDiffReviewRowID.draftComment(draftCommentCommand.targetID),
                fileID: draftCommentCommand.fileID,
                generation: commandGeneration(draftCommentCommand.generation, kind: .draftComment),
                plan: plan
            )
        }
        if let inlineFeedbackCommand {
            return reviewItemRequest(
                targetID: AppKitDiffReviewRowID.inlineFeedback(inlineFeedbackCommand.targetID),
                fileID: inlineFeedbackCommand.fileID,
                generation: commandGeneration(inlineFeedbackCommand.generation, kind: .inlineFeedback),
                plan: plan
            )
        }
        guard let fileCommand else { return nil }
        let headerID = plan.headerByFileID[fileCommand.id]
        return .init(
            targetID: headerID ?? AppKitDiffReviewRowID.header(fileID: fileCommand.id),
            fallbackID: headerID,
            alignment: .top,
            animated: true,
            generation: commandGeneration(fileCommand.generation, kind: .file)
        )
    }

    private enum Kind: Int { case file, inlineFeedback, draftComment }

    private static func commandGeneration(_ generation: Int, kind: Kind) -> Int {
        generation * 3 + kind.rawValue
    }

    private static func reviewItemRequest(
        targetID: String,
        fileID: DiffReviewFileID,
        generation: Int,
        plan: AppKitDiffReviewRowPlan
    ) -> AppKitDiffScrollRequest {
        let headerID = plan.headerByFileID[fileID]
        let resolvedTargetID = plan.fallbackByTargetID[targetID] ?? targetID
        return .init(
            targetID: resolvedTargetID,
            fallbackID: headerID,
            alignment: .center,
            animated: true,
            generation: generation
        )
    }
}

@MainActor
struct AppKitDiffReviewScroller: View {
    let inputs: [AppKitDiffReviewRowInput]
    let fileCommand: DiffReviewScrollCommand?
    let inlineFeedbackCommand: DiffReviewInlineFeedbackScrollCommand?
    let draftCommentCommand: DiffReviewDraftCommentScrollCommand?
    let onNavigationFile: (DiffReviewFileID) -> Void
    let onActiveFileChange: (DiffReviewFileID) -> Void

    var body: some View {
        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: inputs)
        let request = AppKitDiffReviewScrollRequestResolver.request(
            fileCommand: fileCommand,
            inlineFeedbackCommand: inlineFeedbackCommand,
            draftCommentCommand: draftCommentCommand,
            plan: plan
        )
        AppKitDiffScroller(
            plan: plan.corePlan,
            scrollRequest: request,
            onActiveOwnerChange: { rawValue in
                guard let rawValue,
                      let fileID = inputs.first(where: { $0.file.id.rawValue == rawValue })?.file.id
                else { return }
                onActiveFileChange(fileID)
            }
        )
        .onAppear { notifyNavigationFile() }
        .onChange(of: fileCommand) { _, _ in notifyNavigationFile() }
        .onChange(of: inlineFeedbackCommand) { _, _ in notifyNavigationFile() }
        .onChange(of: draftCommentCommand) { _, _ in notifyNavigationFile() }
    }

    private func notifyNavigationFile() {
        if let draftCommentCommand {
            onNavigationFile(draftCommentCommand.fileID)
        } else if let inlineFeedbackCommand {
            onNavigationFile(inlineFeedbackCommand.fileID)
        } else if let fileCommand {
            onNavigationFile(fileCommand.id)
        }
    }
}
