import SwiftUI
import Testing
@testable import Alas

@MainActor
struct DiffReviewFileSectionEqualityTests {
    @Test func sameInputsWithDifferentClosuresAreEqual() {
        let file = fileModel(path: "a.swift")
        let lhs = section(file: file, onSelectInlineFeedback: { _ in })
        let rhs = section(file: file, onSelectInlineFeedback: { _ in })

        #expect(lhs == rhs)
    }

    @Test func equivalentlyRebuiltFileModelsAreEqual() {
        let lhs = section(file: fileModel(path: "a.swift"))
        let rhs = section(file: fileModel(path: "a.swift"))

        #expect(lhs == rhs)
    }

    @Test func differentFileContentIsNotEqual() {
        let lhs = section(file: fileModel(path: "a.swift", lineText: "old"))
        let rhs = section(file: fileModel(path: "a.swift", lineText: "new"))

        #expect(lhs != rhs)
    }

    @Test func renderRelevantScalarInputsParticipateInEquality() {
        let file = fileModel(path: "a.swift")
        let base = section(file: file)

        #expect(base != section(file: file, focusedFeedbackID: "f1"))
        #expect(base != section(file: file, inlineFeedbackScrollTargetID: "t1"))
        #expect(base != section(file: file, focusedDraftCommentID: "d1"))
        #expect(base != section(file: file, layoutMode: .stacked))
        #expect(base != section(file: file, wrapLines: true))
        #expect(base != section(file: file, showWhitespace: true))
        #expect(base != section(file: file, codeFontFamily: "Menlo"))
        #expect(base != section(file: file, codeFontSize: 14))
        #expect(base != section(file: file, showsSourceBadge: true))
        #expect(base != section(file: file, automaticallyRendersDiff: false))
        #expect(base != section(file: file, allowsDraftCommentCreation: true))
        #expect(base != section(file: file, canReply: true))
        #expect(base != section(file: file, canResolve: true))
        #expect(base != section(file: file, canAddToReview: true))
    }

    @Test func sharedPresentationStateParticipatesInEquality() {
        let file = fileModel(path: "a.swift")
        let state = AppKitDiffReviewFileState()
        let base = section(file: file, presentationStateSignature: DiffReviewFilePresentationSignature(state))

        state.showFullDiffOverride = true
        let updated = section(file: file, presentationStateSignature: DiffReviewFilePresentationSignature(state))

        #expect(base != updated)
    }

    @Test func collectionsParticipateInEquality() {
        let file = fileModel(path: "a.swift")
        let base = section(file: file)

        let feedback = DiffReviewInlineFeedback(
            id: "fb1",
            providerName: "provider",
            author: nil,
            bodyPreview: "body",
            status: .pending,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "a.swift", line: 1, side: .new),
            evidenceItemID: "e1"
        )
        #expect(base != section(file: file, inlineFeedback: [feedback]))

        let thread = DiffInlineCommentThread(
            id: "t1",
            filePath: "a.swift",
            newLine: 1,
            isOldSide: false,
            isResolved: false,
            isOutdated: false,
            comments: [],
            viewerCanReply: false,
            viewerCanResolve: false,
            viewerCanUnresolve: false
        )
        #expect(base != section(file: file, threads: [thread]))

        let annotation = DiffInlineAnnotation(
            id: "a1",
            checkName: "check",
            newLine: 1,
            level: .warning,
            message: "message",
            rawDetails: nil
        )
        #expect(base != section(file: file, annotations: [annotation]))

        #expect(base != section(
            file: file,
            reviewFeedbackTarget: ReviewFeedbackTarget(
                title: "t",
                repositoryPath: nil,
                providerDescription: nil,
                sourceDescription: "s"
            )
        ))
    }

    @Test func layoutModeChangeThroughASharedBindingIsDetected() {
        // Regression coverage for a live-binding comparison bug: comparing
        // `section.layoutMode` directly (a `@Binding`) can't distinguish
        // "before" from "after" when both sides are bound to the SAME
        // external storage, because a Binding's `wrappedValue` always reads
        // the CURRENT value regardless of which struct instance reads it.
        // `.constant(_:)` bindings (used by the `section` helper above)
        // don't reproduce this — each `.constant` is its own frozen storage
        // — so this test uses a real shared, mutable source instead.
        final class Box { var layoutMode: DiffLayoutMode = .split }
        let box = Box()
        let sharedBinding = Binding<DiffLayoutMode>(
            get: { box.layoutMode },
            set: { box.layoutMode = $0 }
        )
        let file = fileModel(path: "a.swift")

        func snapshot() -> EquatableDiffReviewFileSection {
            EquatableDiffReviewFileSection(
                section: DiffReviewFileSection(
                    file: file,
                    layoutMode: sharedBinding,
                    wrapLines: .constant(false),
                    showWhitespace: .constant(false),
                    codeFontFamily: "SF Mono",
                    codeFontSize: 12,
                    showsSourceBadge: false
                ),
                layoutMode: box.layoutMode,
                wrapLines: false,
                showWhitespace: false,
                draftCommentAvailability: [],
                inlineFeedbackAvailability: [],
                draftCommentAgentTargets: []
            )
        }

        let before = snapshot()
        box.layoutMode = .stacked
        let after = snapshot()

        #expect(before != after)
    }

    @Test func draftCommentAvailabilityChangeIsDetectedEvenWhenCommentsAreUnchanged() {
        // The comment list itself can stay identical while what's available
        // for it changes (e.g. an agent send-target becomes available).
        // ReviewDraftCommentCard renders its action row from that
        // availability, so a change there must not compare equal.
        let file = fileModel(path: "a.swift")
        let base = section(file: file, draftCommentAvailability: [.none])
        let changed = section(
            file: file,
            draftCommentAvailability: [ReviewDraftCommentActionAvailability(
                canEdit: true,
                canDelete: false,
                canResolve: false,
                canDismiss: false,
                canCopyPrompt: false,
                canShowSendToAgent: false,
                canSendToAgent: false
            )]
        )

        #expect(base != changed)
    }

    @Test func inlineFeedbackAvailabilityChangeIsDetectedEvenWhenFeedbackIsUnchanged() {
        let file = fileModel(path: "a.swift")
        let base = section(file: file, inlineFeedbackAvailability: [.none])
        let changed = section(
            file: file,
            inlineFeedbackAvailability: [DiffReviewInlineFeedbackActionAvailability(
                canOpenProvider: true,
                canCopyContext: false,
                canSendToAgent: false
            )]
        )

        #expect(base != changed)
    }

    @Test func draftCommentAgentTargetsChangeIsDetectedEvenWhenAvailabilityIsUnchanged() {
        // agentTargets() can change shape (one target becomes two, or a
        // session title changes) while canSendToAgent/canShowSendToAgent
        // stay true — sendToAgentControl renders the target list itself
        // (single button vs. menu, per-target titles), so that must
        // participate in equality too.
        let file = fileModel(path: "a.swift")
        let availability = [ReviewDraftCommentActionAvailability(
            canEdit: false,
            canDelete: false,
            canResolve: false,
            canDismiss: false,
            canCopyPrompt: false,
            canShowSendToAgent: true,
            canSendToAgent: true
        )]
        let base = section(
            file: file,
            draftCommentAvailability: availability,
            draftCommentAgentTargets: [.newChat(agentID: "claude", title: "Claude")]
        )
        let changed = section(
            file: file,
            draftCommentAvailability: availability,
            draftCommentAgentTargets: [
                .newChat(agentID: "claude", title: "Claude"),
                .existingSession(worktreeID: "wt", sessionID: "s1", title: "Session 1"),
            ]
        )

        #expect(base != changed)
    }

    @Test func lspContextRendersEqualIgnoresOpenTargetClosure() {
        #expect(DiffPaneLSPContext.rendersEqual(nil, nil))

        let lsp = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        let lhs = lspContext(lsp: lsp, relativePath: "a.swift")
        let rhs = lspContext(lsp: lsp, relativePath: "a.swift")
        #expect(DiffPaneLSPContext.rendersEqual(lhs, rhs))

        #expect(!DiffPaneLSPContext.rendersEqual(lhs, nil))
        #expect(!DiffPaneLSPContext.rendersEqual(
            lhs,
            lspContext(lsp: lsp, relativePath: "b.swift")
        ))

        let otherLSP = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        #expect(!DiffPaneLSPContext.rendersEqual(lhs, lspContext(lsp: otherLSP, relativePath: "a.swift")))
    }
}

@MainActor
private func section(
    file: DiffReviewFileSectionModel,
    inlineFeedback: [DiffReviewInlineFeedback] = [],
    focusedFeedbackID: String? = nil,
    inlineFeedbackScrollTargetID: String? = nil,
    draftComments: [ReviewDraftComment] = [],
    focusedDraftCommentID: String? = nil,
    layoutMode: DiffLayoutMode = .split,
    wrapLines: Bool = false,
    showWhitespace: Bool = false,
    codeFontFamily: String = "SF Mono",
    codeFontSize: CGFloat = 12,
    showsSourceBadge: Bool = false,
    automaticallyRendersDiff: Bool = true,
    onSelectInlineFeedback: @escaping (DiffReviewInlineFeedback) -> Void = { _ in },
    allowsDraftCommentCreation: Bool = false,
    reviewFeedbackTarget: ReviewFeedbackTarget? = nil,
    threads: [DiffInlineCommentThread] = [],
    annotations: [DiffInlineAnnotation] = [],
    canReply: Bool = false,
    canResolve: Bool = false,
    canAddToReview: Bool = false,
    draftCommentAvailability: [ReviewDraftCommentActionAvailability] = [],
    inlineFeedbackAvailability: [DiffReviewInlineFeedbackActionAvailability] = [],
    draftCommentAgentTargets: [ReviewFeedbackAgentTarget] = [],
    presentationStateSignature: DiffReviewFilePresentationSignature? = nil
) -> EquatableDiffReviewFileSection {
    EquatableDiffReviewFileSection(
        section: DiffReviewFileSection(
            file: file,
            inlineFeedback: inlineFeedback,
            focusedFeedbackID: focusedFeedbackID,
            inlineFeedbackScrollTargetID: inlineFeedbackScrollTargetID,
            draftComments: draftComments,
            focusedDraftCommentID: focusedDraftCommentID,
            layoutMode: .constant(layoutMode),
            wrapLines: .constant(wrapLines),
            showWhitespace: .constant(showWhitespace),
            codeFontFamily: codeFontFamily,
            codeFontSize: codeFontSize,
            showsSourceBadge: showsSourceBadge,
            automaticallyRendersDiff: automaticallyRendersDiff,
            onSelectInlineFeedback: onSelectInlineFeedback,
            allowsDraftCommentCreation: allowsDraftCommentCreation,
            reviewFeedbackTarget: reviewFeedbackTarget,
            threads: threads,
            annotations: annotations,
            canReply: canReply,
            canResolve: canResolve,
            canAddToReview: canAddToReview
        ),
        layoutMode: layoutMode,
        wrapLines: wrapLines,
        showWhitespace: showWhitespace,
        draftCommentAvailability: draftCommentAvailability,
        inlineFeedbackAvailability: inlineFeedbackAvailability,
        draftCommentAgentTargets: draftCommentAgentTargets,
        presentationStateSignature: presentationStateSignature
    )
}

private func lspContext(lsp: WorkspaceLSPManager, relativePath: String) -> DiffPaneLSPContext {
    DiffPaneLSPContext(
        worktreeId: "wt",
        worktreeRoot: URL(fileURLWithPath: "/tmp"),
        relativePath: relativePath,
        language: "swift",
        lsp: lsp,
        openTarget: { _, _, _ in }
    )
}

private func fileModel(path: String, lineText: String = "let a = 1") -> DiffReviewFileSectionModel {
    let line = DiffDisplayLine(
        id: "\(path):new:1",
        anchor: DiffLineAnchor(filePath: path, hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 1),
        text: lineText,
        lineNumber: 1,
        kind: .add,
        inlineSpans: [],
        noTrailingNewline: false
    )
    let hunk = ParsedDiff.Hunk(
        header: "@@ -0,0 +1 @@",
        oldStart: 0,
        newStart: 1,
        lines: [ParsedDiff.Hunk.Line(kind: .add, text: lineText, oldNumber: nil, newNumber: 1)]
    )
    let row = DiffDisplayRow(
        id: "\(path):row:0",
        kind: .add,
        old: nil,
        new: line,
        collapsedLineCount: 0
    )
    return DiffReviewFileSectionModel(
        summary: DiffReviewFileSummary(
            path: path,
            namespace: "staged",
            groupID: "staged",
            groupTitle: "Staged",
            status: .modified,
            additions: 1,
            deletions: 0,
            isRenderable: true,
            originalPath: nil
        ),
        parsedDiff: ParsedDiff(hunks: [hunk]),
        displayModel: DiffDisplayModel(
            filePath: path,
            groups: [DiffDisplayGroup(id: "\(path):hunk:0", header: hunk.header, sourceHunk: hunk, rows: [row])]
        ),
        placeholderMessage: nil,
        openFile: nil,
        contextProvider: nil
    )
}
