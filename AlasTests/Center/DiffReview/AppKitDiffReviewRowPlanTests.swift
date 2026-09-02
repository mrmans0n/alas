import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppKitDiffReviewRowPlanTests {
    @Test func textRowsHaveStableUniqueIDsAndTheirOwningFile() {
        let input = AppKitDiffReviewRowInput(file: textFile(), state: AppKitDiffReviewFileState(), theme: theme)

        let first = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let second = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])

        #expect(first.corePlan.rows.map(\.id) == second.corePlan.rows.map(\.id))
        #expect(Set(first.corePlan.rows.map(\.id)).count == first.corePlan.rows.count)
        #expect(first.corePlan.rows.allSatisfy { $0.ownerID == input.file.id.rawValue })
        #expect(first.corePlan.rows.contains { $0.id.hasSuffix(":header") })
        #expect(first.corePlan.rows.contains { $0.id.contains(":group:") })
        #expect(!first.corePlan.rows.contains { $0.id.hasSuffix(":spacing") })
    }

    @Test func deferredFilesMapReviewTargetsToTheirPlaceholder() {
        let feedback = feedback(line: nil)
        let input = AppKitDiffReviewRowInput(
            file: textFile(), inlineFeedback: [feedback], state: AppKitDiffReviewFileState(), theme: theme,
            automaticallyRendersDiff: false
        )

        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let placeholderID = "file:\(input.file.id.rawValue):placeholder"

        #expect(plan.corePlan.rows.map { $0.id } == ["file:\(input.file.id.rawValue):header", placeholderID])
        #expect(plan.placeholderByFileID[input.file.id] == placeholderID)
        #expect(plan.fallbackByTargetID[AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: feedback.id, fileID: input.file.id))] == placeholderID)
    }

    @Test func imageFilesEmitAllLegacyAccessoriesAndImageWithoutTextHunksOrSpacing() {
        let file = imageFile()
        let feedback = feedback(path: file.summary.path, line: nil)
        let thread = DiffInlineCommentThread(
            id: "thread", filePath: file.summary.path, newLine: 1, isOldSide: false,
            isResolved: false, isOutdated: false, comments: []
        )
        let annotation = DiffInlineAnnotation(
            id: "annotation", checkName: "Check", newLine: 1, level: .warning,
            message: "Warning", rawDetails: nil
        )
        let input = AppKitDiffReviewRowInput(
            file: file, inlineFeedback: [feedback], threads: [thread], annotations: [annotation],
            state: AppKitDiffReviewFileState(), theme: theme
        )

        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let ids = plan.corePlan.rows.map { $0.id }

        #expect(ids == [
            AppKitDiffReviewRowID.header(fileID: file.id),
            AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: feedback.id, fileID: file.id)),
            AppKitDiffReviewRowID.thread(fileID: file.id, threadID: thread.id),
            AppKitDiffReviewRowID.annotation(fileID: file.id, annotationID: annotation.id),
            AppKitDiffReviewRowID.image(fileID: file.id),
        ])
        #expect(!ids.contains { $0.contains(":group:") || $0.contains(":segment:") })
    }

    @Test func wholeFileComposerIsImmediatelyBelowHeader() {
        let file = textFile()
        let state = AppKitDiffReviewFileState()
        state.pendingNonLineDraftAnchor = .file

        let ids = AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: file, state: state, theme: theme),
        ]).corePlan.rows.map(\.id)

        #expect(ids.prefix(2) == [
            AppKitDiffReviewRowID.header(fileID: file.id),
            AppKitDiffReviewRowID.composer(fileID: file.id, segmentID: "file"),
        ])
    }

    @Test func imageComposerAndCoordinateCardsAreBelowImage() throws {
        let file = imageFile()
        let state = AppKitDiffReviewFileState()
        state.pendingNonLineDraftAnchor = .image(side: .new, normalizedX: 0.25, normalizedY: 0.75)
        let comment = draftComment(
            fileID: file.id,
            anchor: .image(side: .new, normalizedX: 0.5, normalizedY: 0.5)
        )

        let ids = AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: file, draftComments: [comment], state: state, theme: theme),
        ]).corePlan.rows.map(\.id)
        let imageIndex = try #require(ids.firstIndex(of: AppKitDiffReviewRowID.image(fileID: file.id)))

        #expect(Array(ids.dropFirst(imageIndex + 1).prefix(2)) == [
            AppKitDiffReviewRowID.composer(fileID: file.id, segmentID: "image"),
            AppKitDiffReviewRowID.draftComment(.targetID(commentID: comment.id, fileID: file.id)),
        ])
    }

    @Test func unavailableFilesEmitHeaderAndPlaceholder() {
        let file = placeholderFile()
        let input = AppKitDiffReviewRowInput(file: file, state: AppKitDiffReviewFileState(), theme: theme)

        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])

        #expect(plan.corePlan.rows.map { $0.id } == [
            AppKitDiffReviewRowID.header(fileID: file.id),
            AppKitDiffReviewRowID.placeholder(fileID: file.id),
        ])
    }

    @Test func bottomSpacingFollowsEligibilityForImagePlaceholderAndTextFiles() {
        let image = imageFile()
        let placeholder = placeholderFile()
        let text = textFile()
        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: image, state: AppKitDiffReviewFileState(), theme: theme),
            .init(file: placeholder, state: AppKitDiffReviewFileState(), theme: theme),
            .init(file: text, state: AppKitDiffReviewFileState(), theme: theme),
        ])
        let ids = plan.corePlan.rows.map(\.id)

        #expect(ids.contains(AppKitDiffReviewRowID.spacing(fileID: image.id)))
        #expect(ids.contains(AppKitDiffReviewRowID.spacing(fileID: placeholder.id)))
        #expect(!ids.contains(AppKitDiffReviewRowID.spacing(fileID: text.id)))
    }

    @Test func headerRowCarriesLegacyFileSectionAccessibilityMarker() throws {
        let file = textFile()
        let input = AppKitDiffReviewRowInput(file: file, state: AppKitDiffReviewFileState(), theme: theme)
        let controller = NSHostingController(rootView: AppKitDiffReviewHeaderRowBody(input: input))
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 64)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutSubtreeIfNeeded()

        let marker = try #require(allSubviews(of: controller.view).first {
            $0.accessibilityIdentifier() == "diff-review-file-section-\(file.id.rawValue)"
        })
        #expect(marker.accessibilityLabel() == file.summary.path)
    }

    @Test func aggregateBudgetDefersLaterFilesBeforeBuildingTheirContext() {
        let first = textFile(path: "Sources/First.swift")
        let second = textFile(path: "Sources/Second.swift")
        let firstState = AppKitDiffReviewFileState()
        let secondState = AppKitDiffReviewFileState()

        let plan = AppKitDiffReviewRowPlanBuilder.build(
            inputs: [
                .init(file: first, state: firstState, theme: theme),
                .init(file: second, state: secondState, theme: theme),
            ],
            maxAutomaticallyRenderedRows: DiffReviewRenderBudget.renderedRowCount(of: first.displayModel!)
        )

        #expect(plan.placeholderByFileID[first.id] == nil)
        #expect(plan.placeholderByFileID[second.id] == AppKitDiffReviewRowID.placeholder(fileID: second.id))
        #expect(secondState.renderContextCache.missCountForTests == 0)
    }

    @Test func aggregateBudgetUsesReviewDeferredPlaceholderTitle() {
        let first = textFile(path: "Sources/First.swift")
        let second = textFile(path: "Sources/Second.swift")
        let input = AppKitDiffReviewRowInput(file: second, state: AppKitDiffReviewFileState(), theme: theme)

        let plan = AppKitDiffReviewRowPlanBuilder.build(
            inputs: [
                .init(file: first, state: AppKitDiffReviewFileState(), theme: theme),
                input,
            ],
            maxAutomaticallyRenderedRows: DiffReviewRenderBudget.renderedRowCount(of: first.displayModel!)
        )
        let placeholder = AppKitDiffReviewPlaceholderRowBody(
            input: input,
            isDeferred: true,
            isAggregateDeferred: plan.placeholderByFileID[second.id] != nil
        )

        #expect(placeholder.title == "Large review diff deferred for performance")
    }

    @Test func renderedTargetsAreDirectRowsAndComposerIsPinnedOnlyWhileFocused() throws {
        let file = textFile()
        let feedback = feedback(line: 1)
        let draft = draftComment(fileID: file.id)
        let state = AppKitDiffReviewFileState()
        state.pendingDraftAnchor = DiffReviewLineAnchor(
            path: file.summary.path, side: .new, line: 1, rowIndex: 1, selectedText: "let new = 1"
        )
        let input = AppKitDiffReviewRowInput(
            file: file, inlineFeedback: [feedback], draftComments: [draft], state: state, theme: theme
        )

        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let feedbackID = AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: feedback.id, fileID: file.id))
        let draftID = AppKitDiffReviewRowID.draftComment(.targetID(commentID: draft.id, fileID: file.id))
        let composer = try #require(plan.corePlan.rows.first { $0.id.contains(":composer:") })

        #expect(plan.fallbackByTargetID[feedbackID] == feedbackID)
        #expect(plan.fallbackByTargetID[draftID] == draftID)
        #expect(plan.corePlan.rows.first { $0.id == draftID }?.retention == .recyclable)
        #expect(composer.retention == .recyclable)
        #expect(plan.corePlan.rows.contains { $0.id.contains(":segment:") })

        state.pendingDraftBody = "survives recycling"
        state.isDraftComposerFocused = true
        let focused = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first {
            $0.id == composer.id
        })
        #expect(focused.retention == .pinned)
        state.isDraftComposerFocused = false
        let blurred = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first {
            $0.id == composer.id
        })
        #expect(blurred.retention == .recyclable)
        #expect(state.pendingDraftBody == "survives recycling")
    }

    @Test func activeFeedbackAndDraftEditorsArePinnedWhileTheirBodiesAreUnsaved() throws {
        let file = textFile()
        let item = feedback(line: 1)
        let draft = draftComment(fileID: file.id)
        let thread = DiffInlineCommentThread(
            id: "thread", filePath: file.summary.path, newLine: 1, isOldSide: false,
            isResolved: false, isOutdated: false, comments: []
        )
        let state = AppKitDiffReviewFileState()
        let input = AppKitDiffReviewRowInput(
            file: file, inlineFeedback: [item], draftComments: [draft], threads: [thread], state: state, theme: theme
        )
        let feedbackID = AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: item.id, fileID: file.id))
        let draftID = AppKitDiffReviewRowID.draftComment(.targetID(commentID: draft.id, fileID: file.id))
        let threadID = AppKitDiffReviewRowID.thread(fileID: file.id, threadID: thread.id)

        state.activeInlineFeedbackEditorID = item.id
        state.activeDraftCommentEditorID = draft.id
        state.activeThreadID = thread.id
        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])

        #expect(plan.corePlan.rows.first { $0.id == feedbackID }?.retention == .pinned)
        #expect(plan.corePlan.rows.first { $0.id == draftID }?.retention == .pinned)
        #expect(plan.corePlan.rows.first { $0.id == threadID }?.retention == .pinned)
    }

    @Test func editorModeChangesInvalidateTheirHostedRows() throws {
        let file = textFile()
        let feedback = feedback(line: 1)
        let draft = draftComment(fileID: file.id)
        let thread = DiffInlineCommentThread(
            id: "thread", filePath: file.summary.path, newLine: 1, isOldSide: false,
            isResolved: false, isOutdated: false, comments: []
        )
        let state = AppKitDiffReviewFileState()
        let input = AppKitDiffReviewRowInput(
            file: file, inlineFeedback: [feedback], draftComments: [draft], threads: [thread],
            state: state, theme: theme
        )
        let feedbackID = AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: feedback.id, fileID: file.id))
        let draftID = AppKitDiffReviewRowID.draftComment(.targetID(commentID: draft.id, fileID: file.id))
        let threadID = AppKitDiffReviewRowID.thread(fileID: file.id, threadID: thread.id)
        let resting = AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan

        state.bindingForInlineFeedbackReplyEditor(feedback.id).wrappedValue.isReplying = true
        state.bindingForDraftCommentEditor(draft.id).wrappedValue.isEditing = true
        state.bindingForThreadCommentEditor(thread.id).wrappedValue.editingCommentID = "comment"
        let editing = AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan

        for rowID in [feedbackID, draftID, threadID] {
            let restingRow = try #require(resting.rows.first { $0.id == rowID })
            let editingRow = try #require(editing.rows.first { $0.id == rowID })
            #expect(!restingRow.equalityToken.isEqual(to: editingRow.equalityToken))
        }
    }

    @Test func consolidatedHunkRowsArePinnedWhileContainedThreadEditorIsActive() throws {
        let file = textFile()
        let thread = DiffInlineCommentThread(
            id: "thread", filePath: file.summary.path, newLine: 1, isOldSide: false,
            isResolved: false, isOutdated: false, comments: []
        )
        let state = AppKitDiffReviewFileState()
        let input = AppKitDiffReviewRowInput(file: file, threads: [thread], state: state, theme: theme)
        let rowID = AppKitDiffReviewRowID.groupHeader(fileID: file.id, groupID: file.displayModel!.groups[0].id)
        let resting = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first { $0.id == rowID })

        state.hunkPresentationState.setThreadActive(thread.id, active: true)
        let active = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first { $0.id == rowID })

        #expect(resting.retention == .recyclable)
        #expect(active.retention == .pinned)
    }

    @Test func nestedHunkActiveThreadChangesNotifyReviewStateStructure() {
        let state = AppKitDiffReviewFileState()
        var eventCount = 0
        let cancellable = state.structuralDidChange.sink { eventCount += 1 }

        state.hunkPresentationState.setThreadActive("thread", active: true)

        #expect(eventCount > 0)
        cancellable.cancel()
    }

    @Test func draftRowRebuildsWhenItsReviewTargetChanges() throws {
        let file = textFile()
        let draft = draftComment(fileID: file.id)
        let state = AppKitDiffReviewFileState()
        let local = AppKitDiffReviewRowInput(
            file: file, draftComments: [draft], state: state, theme: theme,
            reviewFeedbackTarget: .init(title: "Local changes", repositoryPath: nil, providerDescription: nil, sourceDescription: "Local")
        )
        let provider = AppKitDiffReviewRowInput(
            file: file, draftComments: [draft], state: state, theme: theme,
            reviewFeedbackTarget: .init(title: "Pull request", repositoryPath: "/repo", providerDescription: "GitHub #980", sourceDescription: "Provider")
        )
        let draftID = AppKitDiffReviewRowID.draftComment(.targetID(commentID: draft.id, fileID: file.id))
        let localRow = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [local]).corePlan.rows.first { $0.id == draftID })
        let providerRow = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [provider]).corePlan.rows.first { $0.id == draftID })

        #expect(!localRow.equalityToken.isEqual(to: providerRow.equalityToken))
    }

    @Test func headerRowRebuildsWhenSourceBadgeVisibilityChanges() throws {
        let file = textFile(groupTitle: "Pull request")
        let state = AppKitDiffReviewFileState()
        let hidden = AppKitDiffReviewRowInput(file: file, state: state, theme: theme, showsSourceBadge: false)
        let shown = AppKitDiffReviewRowInput(file: file, state: state, theme: theme, showsSourceBadge: true)
        let hiddenHeader = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [hidden]).corePlan.rows.first {
            $0.id == AppKitDiffReviewRowID.header(fileID: file.id)
        })
        let shownHeader = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [shown]).corePlan.rows.first {
            $0.id == AppKitDiffReviewRowID.header(fileID: file.id)
        })

        #expect(!hiddenHeader.equalityToken.isEqual(to: shownHeader.equalityToken))
    }

    @Test func headerRowRebuildsWhenSourceBadgeTitleChanges() throws {
        let base = textFile(groupTitle: "Pull request")
        let changed = textFile(groupTitle: "Working tree")
        let state = AppKitDiffReviewFileState()
        let first = AppKitDiffReviewRowInput(file: base, state: state, theme: theme, showsSourceBadge: true)
        let second = AppKitDiffReviewRowInput(file: changed, state: state, theme: theme, showsSourceBadge: true)
        let firstHeader = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [first]).corePlan.rows.first {
            $0.id == AppKitDiffReviewRowID.header(fileID: base.id)
        })
        let secondHeader = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [second]).corePlan.rows.first {
            $0.id == AppKitDiffReviewRowID.header(fileID: changed.id)
        })

        #expect(base.id == changed.id)
        #expect(!firstHeader.equalityToken.isEqual(to: secondHeader.equalityToken))
    }

    @Test func draftRowRebuildsWhenItsAgentTargetsChange() throws {
        let file = textFile()
        let draft = draftComment(fileID: file.id)
        let state = AppKitDiffReviewFileState()
        let withoutTargets = AppKitDiffReviewRowInput(
            file: file, draftComments: [draft], state: state, theme: theme,
            draftCommentActions: .init(agentTargets: { [] })
        )
        let withTargets = AppKitDiffReviewRowInput(
            file: file, draftComments: [draft], state: state, theme: theme,
            draftCommentActions: .init(agentTargets: {
                [
                    .existingSession(worktreeID: "wt", sessionID: "session", title: "Review chat"),
                    .newChat(agentID: "codex", title: "New chat"),
                ]
            })
        )
        let draftID = AppKitDiffReviewRowID.draftComment(.targetID(commentID: draft.id, fileID: file.id))
        let withoutRow = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [withoutTargets]).corePlan.rows.first { $0.id == draftID })
        let withRow = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [withTargets]).corePlan.rows.first { $0.id == draftID })

        #expect(!withoutRow.equalityToken.isEqual(to: withRow.equalityToken))
    }

    @Test func hunkInlineFeedbackRowsReceiveRowContext() throws {
        let file = textFile()
        let item = feedback(line: 1)
        let input = AppKitDiffReviewRowInput(file: file, inlineFeedback: [item], state: AppKitDiffReviewFileState(), theme: theme)
        let feedbackID = AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: item.id, fileID: file.id))
        let row = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first { $0.id == feedbackID })

        #expect(row.contextRowCount == file.displayModel!.groups[0].rows.count)
    }

    @Test func lineDraftRowsReceiveRowContext() throws {
        let file = textFile()
        let draft = draftComment(fileID: file.id)
        let input = AppKitDiffReviewRowInput(file: file, draftComments: [draft], state: AppKitDiffReviewFileState(), theme: theme)
        let draftID = AppKitDiffReviewRowID.draftComment(.targetID(commentID: draft.id, fileID: file.id))
        let row = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first { $0.id == draftID })

        #expect(row.contextRowCount != nil)
    }

    @Test func commandedInlineFeedbackIsIncludedBeyondVisibleCap() {
        let file = textFile()
        let items = (1...4).map { feedback(id: "feedback-\($0)", line: nil) }
        let target = items[3]
        let input = AppKitDiffReviewRowInput(
            file: file,
            inlineFeedback: items,
            state: AppKitDiffReviewFileState(),
            theme: theme,
            inlineFeedbackScrollTargetID: target.id
        )

        let ids = AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.map(\.id)

        #expect(ids.contains(AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: target.id, fileID: file.id))))
    }

    @Test func nonImagePlanClearsStaleImageState() async {
        let state = AppKitDiffReviewFileState()
        let provider = imageProvider {
            ImageDiffPair(before: .missing, after: .missing, oldPath: nil, kind: .modified)
        }
        await state.imageState.load(provider: provider)
        #expect(state.imageState.pair != nil)

        let input = AppKitDiffReviewRowInput(
            file: textFile(),
            state: state,
            theme: theme
        )

        _ = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])

        #expect(state.imageState.pair == nil)
        #expect(state.imageState.providerID == nil)
    }

    @Test func contextFailureRowDisappearsAfterSuccessfulRetry() async throws {
        let attempts = ContextAttempts()
        let provider = DiffReviewContextProvider {
            try await attempts.snapshot()
        }
        let file = textFile(contextProvider: provider)
        let state = AppKitDiffReviewFileState()
        let input = AppKitDiffReviewRowInput(file: file, state: state, theme: theme)
        let key = DiffContextExpansionKey(groupID: file.displayModel!.groups[0].id, boundary: .below)

        input.loadContextAndExpand(key, mode: .chunk(size: 1), edge: nil)
        await state.contextLoadTask?.value
        #expect(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.contains {
            $0.id == AppKitDiffReviewRowID.contextError(fileID: file.id)
        })

        input.loadContextAndExpand(key, mode: .chunk(size: 1), edge: nil)
        await state.contextLoadTask?.value
        #expect(state.contextLoadError == nil)
        #expect(!AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.contains {
            $0.id == AppKitDiffReviewRowID.contextError(fileID: file.id)
        })
    }

    @Test func hunkBusyStateChangesTheOuterRowToken() throws {
        var available = textFile()
        available.stagedMutationActions = .init(
            unstageHunk: { _ in }, isHunkUnstageEnabled: { _ in true }, unstageEnabledBase: true
        )
        var busy = textFile()
        busy.stagedMutationActions = .init(
            unstageHunk: { _ in }, isHunkUnstageEnabled: { _ in false }, unstageEnabledBase: false
        )
        let state = AppKitDiffReviewFileState()
        let availableRow = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: available, state: state, theme: theme, actionPresence: .init(
                canUnstageHunk: true, hunkUnstageEnabled: true
            )),
        ]).corePlan.rows.first { $0.id.contains(":group:") })
        let busyRow = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: busy, state: state, theme: theme, actionPresence: .init(
                canUnstageHunk: true, hunkUnstageEnabled: false
            )),
        ]).corePlan.rows.first { $0.id == availableRow.id })

        #expect(!availableRow.equalityToken.isEqual(to: busyRow.equalityToken))
    }

    @Test func hoverStateChangesRenderedHunkRowToken() throws {
        let file = textFile()
        let item = feedback(line: 1)
        let state = AppKitDiffReviewFileState()
        let input = AppKitDiffReviewRowInput(file: file, inlineFeedback: [item], state: state, theme: theme)
        let first = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first {
            $0.id.contains(":group:")
        })

        state.hoveredInlineFeedbackID = item.id
        let hovered = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first {
            $0.id == first.id
        })

        #expect(!first.equalityToken.isEqual(to: hovered.equalityToken))
    }

    @Test func hoverChangesOnlyRowsThatRenderTheActiveHighlight() throws {
        let file = textFile()
        let item = feedback(line: 1)
        let state = AppKitDiffReviewFileState()
        let input = AppKitDiffReviewRowInput(file: file, inlineFeedback: [item], state: state, theme: theme)
        let initial = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let initialHeader = try #require(initial.corePlan.rows.first { $0.id == AppKitDiffReviewRowID.header(fileID: file.id) })
        let initialHunk = try #require(initial.corePlan.rows.first { $0.id.contains(":group:") })

        state.hoveredInlineFeedbackID = item.id
        let hovered = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let hoveredHeader = try #require(hovered.corePlan.rows.first { $0.id == initialHeader.id })
        let hoveredHunk = try #require(hovered.corePlan.rows.first { $0.id == initialHunk.id })

        #expect(initialHeader.equalityToken.isEqual(to: hoveredHeader.equalityToken))
        #expect(!initialHunk.equalityToken.isEqual(to: hoveredHunk.equalityToken))
    }

    @Test func themeAndFocusedFeedbackChangeRenderedRowTokens() throws {
        let file = textFile()
        let item = feedback(line: 1)
        let state = AppKitDiffReviewFileState()
        let base = AppKitDiffReviewRowInput(file: file, inlineFeedback: [item], state: state, theme: theme)
        var accentedTheme = theme
        accentedTheme.accentOverrideHex = "#ff00ff"
        let themed = AppKitDiffReviewRowInput(file: file, inlineFeedback: [item], state: state, theme: accentedTheme)
        let focused = AppKitDiffReviewRowInput(
            file: file, inlineFeedback: [item], state: state, theme: theme,
            focusedFeedbackID: item.id, focusedDraftCommentID: "draft"
        )
        let baseRow = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [base]).corePlan.rows.first {
            $0.id.contains(":group:")
        })
        let themedRow = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [themed]).corePlan.rows.first {
            $0.id == baseRow.id
        })
        let focusedRow = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [focused]).corePlan.rows.first {
            $0.id == baseRow.id
        })

        #expect(!baseRow.equalityToken.isEqual(to: themedRow.equalityToken))
        #expect(!baseRow.equalityToken.isEqual(to: focusedRow.equalityToken))
    }

    @Test func providerThreadChangesInvalidateFlattenedHunkRow() throws {
        let file = textFile()
        let state = AppKitDiffReviewFileState()
        let initialThread = DiffInlineCommentThread(
            id: "thread", filePath: file.summary.path, newLine: 1, isOldSide: false,
            isResolved: false, isOutdated: false, comments: []
        )
        let resolvedThread = DiffInlineCommentThread(
            id: "thread", filePath: file.summary.path, newLine: 1, isOldSide: false,
            isResolved: true, isOutdated: false, comments: []
        )
        let initial = AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: file, threads: [initialThread], state: state, theme: theme),
        ])
        let resolved = AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: file, threads: [resolvedThread], state: state, theme: theme),
        ])
        let initialRow = try #require(initial.corePlan.rows.first { $0.id.contains(":group:") })
        let resolvedRow = try #require(resolved.corePlan.rows.first { $0.id == initialRow.id })

        #expect(!initialRow.equalityToken.isEqual(to: resolvedRow.equalityToken))
    }

    @Test func accessorySegmentRowsTrackLSPContextInTheirEqualityToken() throws {
        let file = textFile()
        let state = AppKitDiffReviewFileState()
        state.pendingDraftAnchor = DiffReviewLineAnchor(
            path: file.summary.path, side: .new, line: 1, rowIndex: 1, selectedText: "let new = 1"
        )
        let lsp = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        let withLSP = AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: file, state: state, theme: theme, lspContext: lspContext(lsp: lsp, relativePath: file.summary.path)),
        ])
        let withoutLSP = AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: file, state: state, theme: theme),
        ])
        let withSegment = try #require(withLSP.corePlan.rows.first { $0.id.contains(":segment:") })
        let withoutSegment = try #require(withoutLSP.corePlan.rows.first { $0.id == withSegment.id })

        #expect(!withSegment.equalityToken.isEqual(to: withoutSegment.equalityToken))
    }

    @Test func groupHeaderTokenChangesWhenCollapsedContextExpansionChanges() throws {
        let file = collapsibleTextFile()
        let state = AppKitDiffReviewFileState()
        state.pendingDraftAnchor = DiffReviewLineAnchor(
            path: file.summary.path, side: .new, line: 1, rowIndex: 1, selectedText: "let value1 = 1"
        )
        let input = AppKitDiffReviewRowInput(file: file, state: state, theme: theme)
        let group = try #require(file.displayModel?.groups.first)
        let groupID = AppKitDiffReviewRowID.groupHeader(fileID: file.id, groupID: group.id)
        let collapsed = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first { $0.id == groupID })

        state.expandedCollapsedRowIDs = DiffCollapsedContextController.toggled(group, expandedIDs: state.expandedCollapsedRowIDs)
        let expanded = try #require(AppKitDiffReviewRowPlanBuilder.build(inputs: [input]).corePlan.rows.first { $0.id == groupID })

        #expect(!collapsed.equalityToken.isEqual(to: expanded.equalityToken))
    }

    @Test func rowInputContextExpansionAppliesStateAndNotifies() {
        let snapshot = DiffReviewFileContextSnapshot(
            old: .available(["let a = 0", "let old = 1", "let c = 2"]),
            new: .available(["let a = 0", "let new = 1", "let c = 2"])
        )
        let file = textFile(contextProvider: DiffReviewContextProvider { snapshot })
        let state = AppKitDiffReviewFileState()
        state.contextSnapshot = snapshot
        var activationCount = 0
        let input = AppKitDiffReviewRowInput(
            file: file,
            state: state,
            theme: theme,
            onContextExpansionActivated: { activationCount += 1 }
        )
        let key = DiffContextExpansionKey(groupID: file.displayModel!.groups[0].id, boundary: .below)

        input.loadContextAndExpand(key, mode: .chunk(size: 1), edge: nil)

        #expect(activationCount == 1)
        #expect(state.contextExpansion.expandedLineCount(for: key) == 1)
    }

    private var theme: Theme { try! ThemeStore().current }

    private func allSubviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    private func textFile(
        path: String = "Sources/Example.swift",
        contextProvider: DiffReviewContextProvider? = nil,
        groupTitle: String? = nil
    ) -> DiffReviewFileSectionModel {
        let diff = ParsedDiff(hunks: [
            .init(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [
                .init(kind: .delete, text: "let old = 1", oldNumber: 1, newNumber: nil),
                .init(kind: .add, text: "let new = 1", oldNumber: nil, newNumber: 1),
            ]),
        ])
        let summary = DiffReviewFileSummary(
            path: path, namespace: "review", groupID: nil, groupTitle: groupTitle,
            status: .modified, additions: 1, deletions: 1, isRenderable: true
        )
        return DiffReviewFileSectionModel(
            summary: summary, parsedDiff: diff,
            displayModel: DiffDisplayModelBuilder.build(diff: diff, filePath: summary.path),
            placeholderMessage: nil, openFile: nil, contextProvider: contextProvider
        )
    }

    private func lspContext(lsp: WorkspaceLSPManager, relativePath: String) -> DiffPaneLSPContext {
        DiffPaneLSPContext(
            worktreeId: "wt",
            worktreeRoot: URL(fileURLWithPath: "/tmp/repo"),
            relativePath: relativePath,
            language: "swift",
            lsp: lsp,
            openTarget: { _, _, _ in }
        )
    }

    private func collapsibleTextFile() -> DiffReviewFileSectionModel {
        let diff = ParsedDiff(hunks: [
            .init(
                header: "@@ -1,15 +1,15 @@",
                oldStart: 1,
                newStart: 1,
                lines: (1...15).map {
                    .init(kind: .context, text: "let value\($0) = \($0)", oldNumber: $0, newNumber: $0)
                }
            ),
        ])
        let summary = DiffReviewFileSummary(
            path: "Sources/Example.swift", namespace: "review", groupID: nil, groupTitle: nil,
            status: .modified, additions: 0, deletions: 0, isRenderable: true
        )
        return DiffReviewFileSectionModel(
            summary: summary, parsedDiff: diff,
            displayModel: DiffDisplayModelBuilder.build(diff: diff, filePath: summary.path),
            placeholderMessage: nil, openFile: nil, contextProvider: nil
        )
    }

    private func imageFile() -> DiffReviewFileSectionModel {
        let summary = DiffReviewFileSummary(
            path: "Assets/logo.png", namespace: "review", groupID: nil, groupTitle: nil,
            status: .modified, additions: 1, deletions: 1, isRenderable: true
        )
        return DiffReviewFileSectionModel(
            summary: summary, parsedDiff: nil, displayModel: nil, placeholderMessage: nil,
            openFile: nil, contextProvider: nil,
            imageProvider: .init(
                id: .init(
                    source: .commit, repository: "/repo", beforeRevision: "old", afterRevision: "new",
                    beforePath: summary.path, afterPath: summary.path
                ),
                load: { fatalError("The row-plan builder must not load image data") }
            )
        )
    }

    private func imageProvider(load: @escaping @MainActor () async -> ImageDiffPair) -> DiffReviewImageProvider {
        DiffReviewImageProvider(
            id: .init(
                source: .commit, repository: "/repo", beforeRevision: "old", afterRevision: "new",
                beforePath: "Assets/logo.png", afterPath: "Assets/logo.png"
            ),
            load: load
        )
    }

    private func placeholderFile() -> DiffReviewFileSectionModel {
        let summary = DiffReviewFileSummary(
            path: "Assets/data.bin", namespace: "review", groupID: nil, groupTitle: nil,
            status: .modified, additions: 0, deletions: 0, isRenderable: false
        )
        return .init(
            summary: summary, parsedDiff: nil, displayModel: nil,
            placeholderMessage: "Binary file", openFile: nil, contextProvider: nil
        )
    }

    private func feedback(
        id: String = "feedback",
        path: String = "Sources/Example.swift",
        line: Int?
    ) -> DiffReviewInlineFeedback {
        .init(
            id: id, providerName: "Provider", author: nil, bodyPreview: "Needs work",
            status: .actionable, providerURL: nil,
            anchor: .init(path: path, line: line, side: line == nil ? .unknown : .new),
            evidenceItemID: "evidence"
        )
    }

    private func draftComment(
        fileID: DiffReviewFileID,
        anchor: ReviewDraftCommentAnchor = .line(
            side: .new, startLine: 1, endLine: nil, selectedText: "let new = 1"
        )
    ) -> ReviewDraftComment {
        .init(
            id: "draft", sessionID: .commit(worktreeID: "wt", repositoryPath: URL(fileURLWithPath: "/repo"), sha: "abc"),
            fileID: fileID, path: fileID.path, originalPath: nil, anchor: anchor, bodyMarkdown: "Please revisit.",
            state: .active, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private actor ContextAttempts {
        private var count = 0

        func snapshot() throws -> DiffReviewFileContextSnapshot {
            count += 1
            if count == 1 { throw ContextError.failed }
            return .init(old: .available(["old"]), new: .available(["new"]))
        }
    }

    private enum ContextError: Error { case failed }
}
