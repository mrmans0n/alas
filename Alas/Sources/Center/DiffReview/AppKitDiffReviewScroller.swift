import SwiftUI

/// Scrolls to the diff row containing a specific line, independent of any
/// rendered comment marker. Used to jump to a staged PR comment's anchor,
/// which — unlike agent draft comments — never renders as an inline row.
/// `line` is `nil` for file-level comments, which have no line to resolve
/// and simply target the file header.
struct DiffReviewLineScrollCommand: Equatable {
    let fileID: DiffReviewFileID
    let side: DiffReviewInlineFeedbackSide
    let line: Int?
    let generation: Int
}

struct DiffReviewLineScrollController: Equatable {
    private(set) var generation = 0

    mutating func command(fileID: DiffReviewFileID, side: DiffReviewInlineFeedbackSide, line: Int?) -> DiffReviewLineScrollCommand {
        generation += 1
        return DiffReviewLineScrollCommand(fileID: fileID, side: side, line: line, generation: generation)
    }
}

enum AppKitDiffReviewScrollRequestResolver {
    static func hasExactDraftCommentTarget(_ command: DiffReviewDraftCommentScrollCommand, in plan: AppKitDiffReviewRowPlan) -> Bool {
        plan.corePlan.rows.contains { $0.id == AppKitDiffReviewRowID.draftComment(command.targetID) }
    }

    enum Command: Equatable {
        case file(DiffReviewScrollCommand)
        case inlineFeedback(DiffReviewInlineFeedbackScrollCommand)
        case draftComment(DiffReviewDraftCommentScrollCommand)
        case line(DiffReviewLineScrollCommand)

        var fileID: DiffReviewFileID {
            switch self {
            case .file(let command): command.id
            case .inlineFeedback(let command): command.fileID
            case .draftComment(let command): command.fileID
            case .line(let command): command.fileID
            }
        }
    }

    static func request(
        fileCommand: DiffReviewScrollCommand?,
        inlineFeedbackCommand: DiffReviewInlineFeedbackScrollCommand?,
        draftCommentCommand: DiffReviewDraftCommentScrollCommand?,
        lineCommand: DiffReviewLineScrollCommand? = nil,
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
        if let lineCommand {
            return lineRequest(lineCommand, plan: plan)
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
        case .line(let lineCommand):
            request = self.request(
                fileCommand: nil, inlineFeedbackCommand: nil, draftCommentCommand: nil, lineCommand: lineCommand, plan: plan
            )
        }
        precondition(request != nil, "A concrete review scroll command must resolve to a request")
        return .init(
            targetID: request!.targetID,
            fallbackID: request!.fallbackID,
            alignment: request!.alignment,
            animated: request!.animated,
            generation: generation,
            snapsWhenFar: request!.snapsWhenFar,
            lineTarget: request!.lineTarget
        )
    }

    private enum Kind: Int { case file, inlineFeedback, draftComment, line }

    private static func commandGeneration(_ generation: Int, kind: Kind) -> Int {
        generation * 4 + kind.rawValue
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

    /// Falls back to the file header when there's no line to target (a
    /// file-level comment), or the line isn't in a rendered row — e.g. the
    /// file is deferred/collapsed, or the line sits in a collapsed context
    /// block that hasn't been expanded.
    private static func lineRequest(
        _ command: DiffReviewLineScrollCommand,
        plan: AppKitDiffReviewRowPlan
    ) -> AppKitDiffScrollRequest {
        let headerID = plan.headerByFileID[command.fileID]
        let exactTarget = command.line.flatMap { line -> (rowID: String, side: DiffReviewInlineFeedbackSide, line: Int)? in
            let sides: [DiffReviewInlineFeedbackSide] = command.side == .unknown ? [.new, .old] : [command.side]
            for side in sides {
                let key = AppKitDiffReviewRowID.lineKey(fileID: command.fileID, side: side, line: line)
                if let rowID = plan.lineTargetByKey[key] {
                    return (rowID, side, line)
                }
            }
            return nil
        }
        return .init(
            targetID: exactTarget?.rowID ?? headerID ?? AppKitDiffReviewRowID.header(fileID: command.fileID),
            fallbackID: headerID,
            alignment: .center,
            animated: true,
            generation: commandGeneration(command.generation, kind: .line),
            lineTarget: exactTarget.map { AppKitDiffScrollLineTarget(side: $0.side, line: $0.line) }
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
    var lineCommand: DiffReviewLineScrollCommand? = nil
    let onNavigationFile: (DiffReviewFileID, Int) -> Void
    let onActiveFileChange: (DiffReviewFileID) -> Void
    let onProgrammaticScrollCompletion: (Int) -> Void
    var onDraftCommentReveal: (DiffReviewDraftCommentScrollCommand, Bool) -> Void = { _, _ in }
    /// Rows appended after the last file section, e.g. the inline draft
    /// review summary on narrow surfaces.
    var trailingRows: [AppKitDiffRowSpec] = []
    @State private var scrollRequest: AppKitDiffScrollRequest?
    @State private var requestCoordinator = AppKitDiffReviewScrollRequestCoordinator()
    @State private var pendingCommentReveal: (command: DiffReviewDraftCommentScrollCommand, generation: Int)?

    var body: some View {
        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: inputs, trailingRows: trailingRows)
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
            onScrollRequestCompletion: { generation in
                onProgrammaticScrollCompletion(generation)
                guard let pending = pendingCommentReveal, pending.generation == generation else { return }
                pendingCommentReveal = nil
                onDraftCommentReveal(pending.command, AppKitDiffReviewScrollRequestResolver.hasExactDraftCommentTarget(pending.command, in: plan))
            }
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
        .onChange(of: lineCommand) { _, command in
            submit(command.map(AppKitDiffReviewScrollRequestResolver.Command.line), using: plan)
        }
        .copyFeedbackOverlay(message: inputs.lazy.compactMap { $0.state.copyFeedback.message }.first)
    }

    private func submitInitialCommand(using plan: AppKitDiffReviewRowPlan) {
        if let draftCommentCommand {
            submit(.draftComment(draftCommentCommand), using: plan)
        } else if let lineCommand {
            submit(.line(lineCommand), using: plan)
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
        pendingCommentReveal = nil
        if case .draftComment(let comment) = command {
            if AppKitDiffReviewScrollRequestResolver.hasExactDraftCommentTarget(comment, in: plan) {
                pendingCommentReveal = (comment, request.generation)
            } else {
                onDraftCommentReveal(comment, false)
            }
        }
        scrollRequest = request
        onNavigationFile(command.fileID, request.generation)
    }
}
