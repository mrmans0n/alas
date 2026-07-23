import Foundation
import Testing
@testable import Alas

struct DiffReviewRenderableContentEqualityTests {
    @Test func identicalContentWithDifferentClosuresIsEqual() {
        let lhs = fileModel(path: "a.swift", openFile: {}, withActions: true)
        let rhs = fileModel(path: "a.swift", openFile: {}, withActions: true)

        #expect(lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func sameContextProviderIdentityIsEqual() {
        let provider = DiffReviewContextProvider { .init(old: .unavailable, new: .unavailable) }
        let lhs = fileModel(path: "a.swift", contextProvider: provider)
        let rhs = fileModel(path: "a.swift", contextProvider: provider)

        #expect(lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func differentContextProviderIdentityIsNotEqual() {
        // Different provider instances are never equal, even with identical
        // content: DiffReviewFileSection keys stale-load rejection off
        // contextProvider.id, so treating these as unchanged would let a
        // swapped-in file keep serving a previous provider's context.
        let lhs = fileModel(path: "a.swift", contextProvider: DiffReviewContextProvider { .init(old: .unavailable, new: .unavailable) })
        let rhs = fileModel(path: "a.swift", contextProvider: DiffReviewContextProvider { .init(old: .unavailable, new: .unavailable) })

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func contextProviderPresenceMismatchIsNotEqual() {
        let lhs = fileModel(path: "a.swift", contextProvider: DiffReviewContextProvider { .init(old: .unavailable, new: .unavailable) })
        let rhs = fileModel(path: "a.swift")

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func sameImageProviderIdentityIsEqual() {
        let provider = imageProvider(revision: "abc123")
        let lhs = fileModel(path: "a.png", imageProvider: provider)
        let rhs = fileModel(path: "a.png", imageProvider: provider)

        #expect(lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func differentImageProviderRevisionIsNotEqual() {
        let lhs = fileModel(path: "a.png", imageProvider: imageProvider(revision: "abc123"))
        let rhs = fileModel(path: "a.png", imageProvider: imageProvider(revision: "def456"))

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func openFilePresenceMismatchIsNotEqual() {
        let lhs = fileModel(path: "a.swift", openFile: {})
        let rhs = fileModel(path: "a.swift")

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func mutationActionsPresenceMismatchIsNotEqual() {
        let lhs = fileModel(path: "a.swift", withActions: true)
        let rhs = fileModel(path: "a.swift", withActions: false)

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func partialMutationActionsPresenceMismatchIsNotEqual() {
        var lhs = fileModel(path: "a.swift")
        lhs.stagedMutationActions = DiffReviewStagedMutationActions(unstageFile: {})
        var rhs = fileModel(path: "a.swift")
        rhs.stagedMutationActions = DiffReviewStagedMutationActions(unstageHunk: { _ in })

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func unstageEnabledBaseMismatchIsNotEqual() {
        // A `busy` flip doesn't change any other file content, but it does
        // change whether "Drop from commit" should render as enabled — the
        // equality check must catch it so the button doesn't go stale.
        let lhs = fileModel(path: "a.swift", withActions: true, unstageEnabledBase: true)
        let rhs = fileModel(path: "a.swift", withActions: true, unstageEnabledBase: false)

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func differentDisplayModelIsNotEqual() {
        let lhs = fileModel(path: "a.swift", lineText: "let a = 1")
        let rhs = fileModel(path: "a.swift", lineText: "let a = 2")

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func parsedDiffDoesNotParticipateWhenRenderedContentIsUnchanged() {
        let lhs = fileModel(path: "a.swift")
        let rhs = DiffReviewFileSectionModel(
            summary: lhs.summary,
            parsedDiff: ParsedDiff(hunks: []),
            displayModel: lhs.displayModel,
            placeholderMessage: lhs.placeholderMessage,
            openFile: lhs.openFile,
            contextProvider: lhs.contextProvider,
            stagedMutationActions: lhs.stagedMutationActions
        )

        #expect(lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func differentSummaryIsNotEqual() {
        let lhs = fileModel(path: "a.swift", additions: 1)
        let rhs = fileModel(path: "a.swift", additions: 2)

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func sessionsWithSameContentAreEqual() {
        let lhs = session(files: [fileModel(path: "a.swift", openFile: {}), fileModel(path: "b.swift")])
        let rhs = session(files: [fileModel(path: "a.swift", openFile: {}), fileModel(path: "b.swift")])

        #expect(lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func sessionsWithDifferentFileCountAreNotEqual() {
        let lhs = session(files: [fileModel(path: "a.swift")])
        let rhs = session(files: [fileModel(path: "a.swift"), fileModel(path: "b.swift")])

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }

    @Test func sessionsWithOneDifferingFileAreNotEqual() {
        let lhs = session(files: [fileModel(path: "a.swift", lineText: "old")])
        let rhs = session(files: [fileModel(path: "a.swift", lineText: "new")])

        #expect(!lhs.hasSameRenderableContent(as: rhs))
    }
}

private func fileModel(
    path: String,
    additions: Int = 1,
    lineText: String = "let a = 1",
    openFile: (() -> Void)? = nil,
    contextProvider: DiffReviewContextProvider? = nil,
    imageProvider: DiffReviewImageProvider? = nil,
    withActions: Bool = false,
    unstageEnabledBase: Bool = true
) -> DiffReviewFileSectionModel {
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
    let model = DiffDisplayModel(
        filePath: path,
        groups: [DiffDisplayGroup(id: "\(path):hunk:0", header: hunk.header, sourceHunk: hunk, rows: [row])]
    )
    return DiffReviewFileSectionModel(
        summary: DiffReviewFileSummary(
            path: path,
            namespace: "staged",
            groupID: "staged",
            groupTitle: "Staged",
            status: .modified,
            additions: additions,
            deletions: 0,
            isRenderable: true,
            originalPath: nil
        ),
        parsedDiff: ParsedDiff(hunks: [hunk]),
        displayModel: model,
        placeholderMessage: nil,
        openFile: openFile,
        contextProvider: contextProvider,
        imageProvider: imageProvider,
        stagedMutationActions: withActions
            ? DiffReviewStagedMutationActions(
                unstageFile: {},
                unstageHunk: { _ in },
                isHunkUnstageEnabled: { _ in true },
                unstageEnabledBase: unstageEnabledBase
            )
            : nil
    )
}

private func imageProvider(revision: String) -> DiffReviewImageProvider {
    DiffReviewImageProvider(
        id: DiffReviewImageProviderID(
            source: .commit,
            repository: "/repo",
            beforeRevision: "\(revision)^",
            afterRevision: revision,
            beforePath: "Assets/logo.png",
            afterPath: "Assets/logo.png"
        ),
        load: {
            ImageDiffPair(before: .missing, after: .missing, oldPath: nil, kind: .modified)
        }
    )
}

private func session(files: [DiffReviewFileSectionModel]) -> DiffReviewLoadedSession {
    DiffReviewLoadedSession(
        files: files,
        summary: DiffReviewSessionModel(files: files.map(\.summary), groupsEnabled: false)
    )
}
