import SwiftUI

enum AppKitDiffReviewScrollRequestResolver {
    enum Command: Equatable {
        case file(DiffReviewScrollCommand)
        case inlineFeedback(DiffReviewInlineFeedbackScrollCommand)
        case draftComment(DiffReviewDraftCommentScrollCommand)

        var fileID: DiffReviewFileID {
            switch self {
            case .file(let command): command.id
            case .inlineFeedback(let command): command.fileID
            case .draftComment(let command): command.fileID
            }
        }
    }

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
            generation: commandGeneration(fileCommand.generation, kind: .file),
            snapsWhenFar: true
        )
    }

    static func request(
        for command: Command,
        plan: AppKitDiffReviewRowPlan,
        generation: Int
    ) -> AppKitDiffScrollRequest {
        let request: AppKitDiffScrollRequest?
        switch command {
        case .file(let fileCommand):
            request = self.request(
                fileCommand: fileCommand, inlineFeedbackCommand: nil, draftCommentCommand: nil, plan: plan
            )
        case .inlineFeedback(let inlineFeedbackCommand):
            request = self.request(
                fileCommand: nil, inlineFeedbackCommand: inlineFeedbackCommand, draftCommentCommand: nil, plan: plan
            )
        case .draftComment(let draftCommentCommand):
            request = self.request(
                fileCommand: nil, inlineFeedbackCommand: nil, draftCommentCommand: draftCommentCommand, plan: plan
            )
        }
        precondition(request != nil, "A concrete review scroll command must resolve to a request")
        return .init(
            targetID: request!.targetID,
            fallbackID: request!.fallbackID,
            alignment: request!.alignment,
            animated: request!.animated,
            generation: generation,
            snapsWhenFar: request!.snapsWhenFar
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

struct AppKitDiffReviewScrollRequestCoordinator {
    private var generation = 0

    mutating func request(
        for command: AppKitDiffReviewScrollRequestResolver.Command,
        plan: AppKitDiffReviewRowPlan
    ) -> AppKitDiffScrollRequest {
        generation += 1
        return AppKitDiffReviewScrollRequestResolver.request(for: command, plan: plan, generation: generation)
    }
}

struct AppKitDiffReviewScrollCompletionGate: Equatable {
    private(set) var pendingRequestGeneration: Int?

    mutating func begin(requestGeneration: Int) {
        pendingRequestGeneration = requestGeneration
    }

    mutating func consumesCompletion(for requestGeneration: Int) -> Bool {
        guard pendingRequestGeneration == requestGeneration else { return false }
        pendingRequestGeneration = nil
        return true
    }
}

@MainActor
struct AppKitDiffReviewScroller: View {
    let inputs: [AppKitDiffReviewRowInput]
    let fileCommand: DiffReviewScrollCommand?
    let inlineFeedbackCommand: DiffReviewInlineFeedbackScrollCommand?
    let draftCommentCommand: DiffReviewDraftCommentScrollCommand?
    let onNavigationFile: (DiffReviewFileID, Int) -> Void
    let onActiveFileChange: (DiffReviewFileID) -> Void
    let onProgrammaticScrollCompletion: (Int) -> Void
    @State private var scrollRequest: AppKitDiffScrollRequest?
    @State private var requestCoordinator = AppKitDiffReviewScrollRequestCoordinator()

    var body: some View {
        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: inputs)
        let corePlan = plan.corePlan.withContentInsets(.init(top: 16, bottom: 16, left: 16, right: 16))
        AppKitDiffScroller(
            plan: corePlan,
            scrollRequest: scrollRequest,
            onActiveOwnerChange: { rawValue in
                guard let rawValue,
                      let fileID = inputs.first(where: { $0.file.id.rawValue == rawValue })?.file.id
                else { return }
                onActiveFileChange(fileID)
            },
            onScrollRequestCompletion: onProgrammaticScrollCompletion
        )
        .onAppear { submitInitialCommand(using: plan) }
        .onChange(of: fileCommand) { _, command in
            submit(command.map(AppKitDiffReviewScrollRequestResolver.Command.file), using: plan)
        }
        .onChange(of: inlineFeedbackCommand) { _, command in
            submit(command.map(AppKitDiffReviewScrollRequestResolver.Command.inlineFeedback), using: plan)
        }
        .onChange(of: draftCommentCommand) { _, command in
            submit(command.map(AppKitDiffReviewScrollRequestResolver.Command.draftComment), using: plan)
        }
        .copyFeedbackOverlay(message: inputs.lazy.compactMap { $0.state.copyFeedback.message }.first)
    }

    private func submitInitialCommand(using plan: AppKitDiffReviewRowPlan) {
        if let draftCommentCommand {
            submit(.draftComment(draftCommentCommand), using: plan)
        } else if let inlineFeedbackCommand {
            submit(.inlineFeedback(inlineFeedbackCommand), using: plan)
        } else if let fileCommand {
            submit(.file(fileCommand), using: plan)
        }
    }

    private func submit(
        _ command: AppKitDiffReviewScrollRequestResolver.Command?,
        using plan: AppKitDiffReviewRowPlan
    ) {
        guard let command else { return }
        let request = requestCoordinator.request(for: command, plan: plan)
        scrollRequest = request
        onNavigationFile(command.fileID, request.generation)
    }
}
