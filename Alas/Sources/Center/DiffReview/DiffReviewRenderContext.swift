import Combine
import Foundation

struct DiffReviewRenderContextKey: Hashable {
    private let fileID: String
    private let displayContentHash: Int
    private let providerAvailable: Bool
    private let contextExpansion: ContextExpansionStateSignature
    private let inlineFeedback: [InlineFeedbackSignature]
    private let draftComments: [DraftCommentSignature]
    private let pendingDraftPlacement: PendingDraftPlacementSignature?
    private let canCreateDraftComment: Bool
    private let threads: [ThreadSignature]
    private let annotations: [AnnotationSignature]

    init(
        fileID: DiffReviewFileID,
        displayModel: DiffDisplayModel,
        contextSnapshot: DiffReviewFileContextSnapshot?,
        contextProviderAvailable: Bool,
        contextExpansion: DiffContextExpansionState,
        inlineFeedback: [DiffReviewInlineFeedback],
        draftComments: [ReviewDraftComment],
        pendingDraftAnchor: DiffReviewLineAnchor?,
        canCreateDraftComment: Bool,
        threads: [DiffInlineCommentThread],
        annotations: [DiffInlineAnnotation]
    ) {
        self.fileID = fileID.rawValue
        self.displayContentHash = displayModel.contentHash
        self.providerAvailable = contextProviderAvailable
        self.contextExpansion = ContextExpansionStateSignature(
            groups: displayModel.groups,
            snapshot: contextSnapshot,
            providerAvailable: contextProviderAvailable,
            expansion: contextExpansion
        )
        self.inlineFeedback = inlineFeedback.map(InlineFeedbackSignature.init)
        self.draftComments = draftComments.map(DraftCommentSignature.init)
        self.pendingDraftPlacement = pendingDraftAnchor.map(PendingDraftPlacementSignature.init)
        self.canCreateDraftComment = canCreateDraftComment
        self.threads = threads.map(ThreadSignature.init)
        self.annotations = annotations.map(AnnotationSignature.init)
    }
}

struct DiffReviewRenderContext: Equatable {
    struct Group: Equatable, Identifiable {
        let displayGroup: DiffDisplayGroup
        let inlineFeedback: [DiffReviewInlineFeedback]
        let segments: [Segment]

        var id: String { displayGroup.id }

        var containsLocalAccessories: Bool {
            segments.contains { !$0.draftComments.isEmpty || $0.showsComposer }
        }
    }

    struct Segment: Equatable, Identifiable {
        let id: String
        let rows: [DiffDisplayRow]
        let rowsSignature: DiffDisplayRowsSignature
        let draftComments: [ReviewDraftComment]
        let showsComposer: Bool
        let blocks: [DiffInlineCommentLayout.Block]

        init(
            id: String,
            rows: [DiffDisplayRow],
            rowsSignature: DiffDisplayRowsSignature? = nil,
            draftComments: [ReviewDraftComment],
            showsComposer: Bool,
            blocks: [DiffInlineCommentLayout.Block]
        ) {
            self.id = id
            self.rows = rows
            self.rowsSignature = rowsSignature ?? DiffDisplayRowsSignature(rows)
            self.draftComments = draftComments
            self.showsComposer = showsComposer
            self.blocks = blocks
        }

        static func == (lhs: Segment, rhs: Segment) -> Bool {
            lhs.id == rhs.id
                && lhs.rowsSignature == rhs.rowsSignature
                && lhs.draftComments == rhs.draftComments
                && lhs.showsComposer == rhs.showsComposer
                && lhs.blocks == rhs.blocks
        }
    }

    let groups: [Group]
    let fileLevelInlineFeedback: [DiffReviewInlineFeedback]
    let inlineFeedbackByGroupID: [String: [DiffReviewInlineFeedback]]
    let fileLevelDraftComments: [ReviewDraftComment]
    let draftPlacement: ReviewDraftCommentPlacement.Result
    let groupData: [String: Group]

    func group(id: String) -> Group? {
        groupData[id]
    }
}

enum DiffReviewRenderContextBuilder {
    static func build(
        fileID: DiffReviewFileID,
        displayModel: DiffDisplayModel,
        contextSnapshot: DiffReviewFileContextSnapshot?,
        contextProviderAvailable: Bool,
        contextExpansion: DiffContextExpansionState,
        inlineFeedback: [DiffReviewInlineFeedback],
        draftComments: [ReviewDraftComment],
        pendingDraftAnchor: DiffReviewLineAnchor?,
        canCreateDraftComment: Bool,
        threads: [DiffInlineCommentThread],
        annotations: [DiffInlineAnnotation]
    ) -> DiffReviewRenderContext {
        _ = fileID
        let displayGroups = DiffContextExpandedDisplayBuilder.derive(
            groups: displayModel.groups,
            snapshot: contextSnapshot,
            providerAvailable: contextProviderAvailable,
            expansion: contextExpansion,
            filePath: displayModel.filePath,
            chunkSize: 10
        )
        let inlinePlacement = DiffReviewInlineFeedbackPlacement.position(inlineFeedback, in: displayGroups)
        let draftPlacement = ReviewDraftCommentPlacement.position(draftComments, in: displayGroups)
        let groups = displayGroups.map { group in
            let segmented = ReviewDraftCommentRowSegmentation.segments(
                for: group,
                placement: draftPlacement,
                pendingAnchor: pendingDraftAnchor,
                canCreateDraftComment: canCreateDraftComment
            )
            let segments = segmented.items.map { segment in
                let matchedThreads = threads.filter { thread in
                    segment.rows.contains {
                        thread.isOldSide
                            ? $0.old?.anchor.oldLine == thread.newLine
                            : $0.new?.anchor.newLine == thread.newLine
                    }
                }
                let matchedAnnotations = annotations.filter { annotation in
                    segment.rows.contains { $0.new?.anchor.newLine == annotation.newLine }
                }
                return DiffReviewRenderContext.Segment(
                    id: segment.id,
                    rows: segment.rows,
                    rowsSignature: segment.rowsSignature,
                    draftComments: segment.draftComments,
                    showsComposer: segment.showsComposer,
                    blocks: DiffInlineCommentLayout.blocks(
                        visibleRows: DiffDisplayRowsSnapshot(
                            rows: segment.rows,
                            signature: segment.rowsSignature
                        ),
                        threads: matchedThreads,
                        annotations: matchedAnnotations
                    )
                )
            }

            return DiffReviewRenderContext.Group(
                displayGroup: group,
                inlineFeedback: inlinePlacement.byGroupID[group.id] ?? [],
                segments: segments
            )
        }

        return DiffReviewRenderContext(
            groups: groups,
            fileLevelInlineFeedback: inlinePlacement.fileLevel,
            inlineFeedbackByGroupID: inlinePlacement.byGroupID,
            fileLevelDraftComments: draftPlacement.fileLevel,
            draftPlacement: draftPlacement,
            groupData: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        )
    }
}

@MainActor
final class DiffReviewRenderContextCache: ObservableObject {
    private let maximumEntryCount: Int
    private var storage: [DiffReviewRenderContextKey: DiffReviewRenderContext] = [:]
    private var recency: [DiffReviewRenderContextKey] = []

    #if DEBUG
    private(set) var missCount = 0

    var missCountForTests: Int { missCount }
    #endif

    init(limit: Int = 8) {
        maximumEntryCount = max(1, limit)
    }

    init(maximumEntryCount: Int) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func context(
        key: DiffReviewRenderContextKey,
        build: () -> DiffReviewRenderContext
    ) -> DiffReviewRenderContext {
        if let cached = storage[key] {
            markRecentlyUsed(key)
            return cached
        }

        #if DEBUG
        missCount += 1
        #endif

        let context = build()
        storage[key] = context
        markRecentlyUsed(key)
        pruneIfNeeded()
        return context
    }

    /// Shared cache entry point for both the legacy section and the flattened
    /// AppKit row plan. Keeping this construction here prevents either path
    /// from accidentally deriving a second context for the same file pass.
    func reviewContext(
        fileID: DiffReviewFileID,
        displayModel: DiffDisplayModel,
        contextSnapshot: DiffReviewFileContextSnapshot?,
        contextProviderAvailable: Bool,
        contextExpansion: DiffContextExpansionState,
        inlineFeedback: [DiffReviewInlineFeedback],
        draftComments: [ReviewDraftComment],
        pendingDraftAnchor: DiffReviewLineAnchor?,
        canCreateDraftComment: Bool,
        threads: [DiffInlineCommentThread],
        annotations: [DiffInlineAnnotation]
    ) -> DiffReviewRenderContext {
        let key = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: displayModel,
            contextSnapshot: contextSnapshot,
            contextProviderAvailable: contextProviderAvailable,
            contextExpansion: contextExpansion,
            inlineFeedback: inlineFeedback,
            draftComments: draftComments,
            pendingDraftAnchor: pendingDraftAnchor,
            canCreateDraftComment: canCreateDraftComment,
            threads: threads,
            annotations: annotations
        )
        return context(key: key) {
            DiffReviewRenderContextBuilder.build(
                fileID: fileID,
                displayModel: displayModel,
                contextSnapshot: contextSnapshot,
                contextProviderAvailable: contextProviderAvailable,
                contextExpansion: contextExpansion,
                inlineFeedback: inlineFeedback,
                draftComments: draftComments,
                pendingDraftAnchor: pendingDraftAnchor,
                canCreateDraftComment: canCreateDraftComment,
                threads: threads,
                annotations: annotations
            )
        }
    }

    func removeAll() {
        storage.removeAll()
        recency.removeAll()
        #if DEBUG
        missCount = 0
        #endif
    }

    private func markRecentlyUsed(_ key: DiffReviewRenderContextKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func pruneIfNeeded() {
        while recency.count > maximumEntryCount {
            let key = recency.removeFirst()
            storage.removeValue(forKey: key)
        }
    }
}

private struct ContextExpansionStateSignature: Hashable {
    let snapshot: SnapshotSignature
    let boundaries: [BoundarySignature]
    let expandedSnapshotContent: [ExpandedSnapshotLineSignature]

    init(
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        providerAvailable: Bool,
        expansion: DiffContextExpansionState
    ) {
        self.snapshot = SnapshotSignature(snapshot)
        guard providerAvailable else {
            boundaries = []
            expandedSnapshotContent = []
            return
        }

        var signatures: [BoundarySignature] = []
        var expandedLines: [ExpandedSnapshotLineSignature] = []

        for groupIndex in groups.indices {
            let group = groups[groupIndex]
            if groupIndex == groups.startIndex {
                signatures.append(Self.externalSignature(
                    group: group,
                    groupIndex: groupIndex,
                    boundary: .above,
                    groups: groups,
                    snapshot: snapshot,
                    expansion: expansion,
                    expandedLines: &expandedLines
                ))
            }

            if groupIndex + 1 < groups.endIndex {
                signatures.append(Self.sharedSignature(
                    upperGroup: group,
                    lowerGroup: groups[groupIndex + 1],
                    upperGroupIndex: groupIndex,
                    groups: groups,
                    snapshot: snapshot,
                    expansion: expansion,
                    expandedLines: &expandedLines
                ))
            } else {
                signatures.append(Self.externalSignature(
                    group: group,
                    groupIndex: groupIndex,
                    boundary: .below,
                    groups: groups,
                    snapshot: snapshot,
                    expansion: expansion,
                    expandedLines: &expandedLines
                ))
            }
        }
        boundaries = signatures
        expandedSnapshotContent = expandedLines
    }

    private static func externalSignature(
        group: DiffDisplayGroup,
        groupIndex: Int,
        boundary: DiffContextBoundary,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        expansion: DiffContextExpansionState,
        expandedLines: inout [ExpandedSnapshotLineSignature]
    ) -> BoundarySignature {
        let key = DiffContextExpansionKey(groupID: group.id, boundary: boundary)
        let range = BoundaryRange(
            group: group,
            groupIndex: groupIndex,
            boundary: boundary,
            groups: groups,
            snapshot: snapshot
        )
        let available = range.lineCount
        let expanded = min(expansion.expandedLineCount(for: key), available)
        if expanded > 0 {
            expandedLines.append(contentsOf: range.expandedLineSignatures(
                groupID: group.id,
                boundary: boundary,
                expandedCount: expanded,
                snapshot: snapshot
            ))
        }
        return BoundarySignature(
            key: key,
            boundary: boundary.rawValue,
            availableLineCount: available,
            topExpandedLineCount: expanded,
            bottomExpandedLineCount: 0
        )
    }

    private static func sharedSignature(
        upperGroup: DiffDisplayGroup,
        lowerGroup: DiffDisplayGroup,
        upperGroupIndex: Int,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        expansion: DiffContextExpansionState,
        expandedLines: inout [ExpandedSnapshotLineSignature]
    ) -> BoundarySignature {
        let key = DiffContextExpansionKey.shared(upperGroupID: upperGroup.id, lowerGroupID: lowerGroup.id)
        let range = BoundaryRange(
            group: upperGroup,
            groupIndex: upperGroupIndex,
            boundary: .below,
            groups: groups,
            snapshot: snapshot
        )
        let available = range.lineCount
        let topExpanded = min(expansion.expandedLineCount(for: key, edge: .top), available)
        let bottomExpanded = min(
            expansion.expandedLineCount(for: key, edge: .bottom),
            max(0, available - topExpanded)
        )
        if topExpanded > 0 {
            expandedLines.append(contentsOf: range.expandedLineSignatures(
                groupID: key.groupID,
                boundary: .below,
                expandedCount: topExpanded,
                snapshot: snapshot
            ))
        }
        if bottomExpanded > 0 {
            expandedLines.append(contentsOf: range.expandedLineSignatures(
                groupID: key.groupID,
                boundary: .above,
                expandedCount: bottomExpanded,
                snapshot: snapshot
            ))
        }
        return BoundarySignature(
            key: key,
            boundary: DiffContextBoundary.below.rawValue,
            availableLineCount: available,
            topExpandedLineCount: topExpanded,
            bottomExpandedLineCount: bottomExpanded
        )
    }
}

private struct BoundarySignature: Hashable {
    let key: DiffContextExpansionKey
    let boundary: String
    let availableLineCount: Int
    let topExpandedLineCount: Int
    let bottomExpandedLineCount: Int
}

private struct SnapshotSignature: Hashable {
    let old: LinesSignature
    let new: LinesSignature

    init(_ snapshot: DiffReviewFileContextSnapshot?) {
        old = LinesSignature(snapshot?.old)
        new = LinesSignature(snapshot?.new)
    }
}

private struct LinesSignature: Hashable {
    enum Availability: Hashable {
        case missing
        case unavailable
        case available
    }

    let availability: Availability
    let lineCount: Int

    init(_ lines: DiffReviewFileContextLines?) {
        switch lines {
        case nil:
            availability = .missing
            lineCount = 0
        case .unavailable:
            availability = .unavailable
            lineCount = 0
        case .available(let values):
            availability = .available
            lineCount = values.count
        }
    }
}

private struct ExpandedSnapshotLineSignature: Hashable {
    let groupID: String
    let boundary: String
    let offset: Int
    let oldLineNumber: Int?
    let oldTextHash: Int?
    let newLineNumber: Int?
    let newTextHash: Int?
}

private struct BoundaryRange {
    let oldStart: Int?
    let oldCount: Int
    let newStart: Int?
    let newCount: Int

    var lineCount: Int {
        max(oldCount, newCount)
    }

    init(
        group: DiffDisplayGroup,
        groupIndex: Int,
        boundary: DiffContextBoundary,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?
    ) {
        guard Self.ownsBoundary(groupIndex: groupIndex, boundary: boundary), let snapshot else {
            oldStart = nil
            oldCount = 0
            newStart = nil
            newCount = 0
            return
        }

        let previous = groupIndex > 0 ? groups[groupIndex - 1] : nil
        let next = groupIndex + 1 < groups.count ? groups[groupIndex + 1] : nil
        let currentOld = group.oldSideExtent
        let currentNew = group.newSideExtent
        let previousOld = previous?.oldSideExtent
        let previousNew = previous?.newSideExtent
        let nextOld = next?.oldSideExtent
        let nextNew = next?.newSideExtent

        switch boundary {
        case .above:
            let oldStart = previousOld?.lineAfter ?? 1
            let newStart = previousNew?.lineAfter ?? 1
            self.oldStart = oldStart
            oldCount = Self.lineCount(start: oldStart, end: currentOld.lineBefore, snapshotLines: snapshot.old.signatureLineCount)
            self.newStart = newStart
            newCount = Self.lineCount(start: newStart, end: currentNew.lineBefore, snapshotLines: snapshot.new.signatureLineCount)
        case .below:
            let oldStart = currentOld.lineAfter
            let newStart = currentNew.lineAfter
            self.oldStart = oldStart
            oldCount = Self.lineCount(
                start: oldStart,
                end: nextOld?.lineBefore ?? snapshot.old.signatureLineCount,
                snapshotLines: snapshot.old.signatureLineCount
            )
            self.newStart = newStart
            newCount = Self.lineCount(
                start: newStart,
                end: nextNew?.lineBefore ?? snapshot.new.signatureLineCount,
                snapshotLines: snapshot.new.signatureLineCount
            )
        }
    }

    func expandedLineSignatures(
        groupID: String,
        boundary: DiffContextBoundary,
        expandedCount: Int,
        snapshot: DiffReviewFileContextSnapshot?
    ) -> [ExpandedSnapshotLineSignature] {
        guard let snapshot, expandedCount > 0 else { return [] }
        let available = lineCount
        let offsets: Range<Int>
        switch boundary {
        case .above:
            offsets = (available - expandedCount)..<available
        case .below:
            offsets = 0..<expandedCount
        }
        return offsets.map { offset in
            let oldNumber = Self.lineNumber(
                start: oldStart,
                count: oldCount,
                offset: offset,
                totalCount: available,
                boundary: boundary
            )
            let newNumber = Self.lineNumber(
                start: newStart,
                count: newCount,
                offset: offset,
                totalCount: available,
                boundary: boundary
            )
            return ExpandedSnapshotLineSignature(
                groupID: groupID,
                boundary: boundary.rawValue,
                offset: offset,
                oldLineNumber: oldNumber,
                oldTextHash: oldNumber.flatMap { snapshot.old.signatureLineHash(at: $0) },
                newLineNumber: newNumber,
                newTextHash: newNumber.flatMap { snapshot.new.signatureLineHash(at: $0) }
            )
        }
    }

    private static func ownsBoundary(groupIndex: Int, boundary: DiffContextBoundary) -> Bool {
        switch boundary {
        case .above:
            groupIndex == 0
        case .below:
            true
        }
    }

    private static func lineCount(start: Int, end: Int?, snapshotLines: Int?) -> Int {
        guard let snapshotLines, let end else { return 0 }
        let clampedStart = max(1, start)
        let clampedEnd = min(end, snapshotLines)
        guard clampedStart <= clampedEnd else { return 0 }
        return clampedEnd - clampedStart + 1
    }

    private static func lineNumber(
        start: Int?,
        count: Int,
        offset: Int,
        totalCount: Int,
        boundary: DiffContextBoundary
    ) -> Int? {
        guard let start, count > 0 else { return nil }
        let hiddenPadding = totalCount - count
        switch boundary {
        case .above:
            let index = offset - hiddenPadding
            guard index >= 0, index < count else { return nil }
            return start + index
        case .below:
            guard offset < count else { return nil }
            return start + offset
        }
    }
}

private extension DiffReviewFileContextLines {
    var signatureLineCount: Int? {
        guard case .available(let lines) = self else { return nil }
        return lines.count
    }

    func signatureLineHash(at number: Int) -> Int? {
        guard case .available(let lines) = self else { return nil }
        let index = number - 1
        guard lines.indices.contains(index) else { return nil }
        return lines[index].hashValue
    }
}

private struct InlineFeedbackSignature: Hashable {
    let id: String
    let providerName: String
    let author: String?
    let bodyPreview: String
    let status: String
    let providerURL: String?
    let anchorPath: String
    let anchorLine: Int?
    let anchorSide: String
    let evidenceItemID: String?

    init(_ feedback: DiffReviewInlineFeedback) {
        id = feedback.id
        providerName = feedback.providerName
        author = feedback.author
        bodyPreview = feedback.bodyPreview
        status = String(describing: feedback.status)
        providerURL = feedback.providerURL?.absoluteString
        anchorPath = feedback.anchor.path
        anchorLine = feedback.anchor.line
        anchorSide = feedback.anchor.side.rawValue
        evidenceItemID = feedback.evidenceItemID
    }
}

private struct DraftCommentSignature: Hashable {
    let id: String
    let fileID: String
    let path: String
    let originalPath: String?
    let side: String
    let startLine: Int
    let endLine: Int?
    let selectedText: String?
    let bodyMarkdown: String
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let providerPublish: ProviderPublishSignature?
    let providerError: ProviderErrorSignature?

    init(_ comment: ReviewDraftComment) {
        id = comment.id
        fileID = comment.fileID.rawValue
        path = comment.path
        originalPath = comment.originalPath
        side = comment.side.rawValue
        startLine = comment.startLine
        endLine = comment.endLine
        selectedText = comment.selectedText
        bodyMarkdown = comment.bodyMarkdown
        state = comment.state.rawValue
        createdAt = comment.createdAt
        updatedAt = comment.updatedAt
        providerPublish = comment.providerPublish.map(ProviderPublishSignature.init)
        providerError = comment.providerError.map(ProviderErrorSignature.init)
    }
}

private struct ProviderPublishSignature: Hashable {
    let provider: String
    let host: String
    let repositorySlug: String
    let reviewNumber: Int
    let threadID: String?
    let commentID: String?
    let url: String?
    let publishedAt: Date

    init(_ publish: ReviewDraftProviderPublish) {
        provider = String(describing: publish.provider)
        host = publish.host
        repositorySlug = publish.repositorySlug
        reviewNumber = publish.reviewNumber
        threadID = publish.threadID
        commentID = publish.commentID
        url = publish.url?.absoluteString
        publishedAt = publish.publishedAt
    }
}

private struct ProviderErrorSignature: Hashable {
    let provider: String
    let message: String
    let occurredAt: Date

    init(_ error: ReviewDraftProviderError) {
        provider = String(describing: error.provider)
        message = error.message
        occurredAt = error.occurredAt
    }
}

private struct PendingDraftPlacementSignature: Hashable {
    let side: String
    let line: Int
    let rowIndex: Int
    let endRowIndex: Int
    private let selectedLines: [SelectedLineSignature]

    init(_ anchor: DiffReviewLineAnchor) {
        side = anchor.side.rawValue
        line = anchor.endLine ?? anchor.line
        rowIndex = anchor.rowIndex
        endRowIndex = anchor.endRowIndex
        selectedLines = anchor.selectedLines.map(SelectedLineSignature.init)
    }

    private struct SelectedLineSignature: Hashable {
        let side: String
        let line: Int
        let isChange: Bool

        init(_ line: DiffReviewLineAnchor.SelectedLine) {
            side = line.side.rawValue
            self.line = line.line
            isChange = line.isChange
        }
    }
}

private struct ThreadSignature: Hashable {
    let id: String
    let filePath: String
    let newLine: Int
    let startLine: Int?
    let isOldSide: Bool
    let isResolved: Bool
    let isOutdated: Bool
    let viewerCanReply: Bool
    let viewerCanResolve: Bool
    let viewerCanUnresolve: Bool
    let comments: [CommentSignature]

    init(_ thread: DiffInlineCommentThread) {
        id = thread.id
        filePath = thread.filePath
        newLine = thread.newLine
        startLine = thread.startLine
        isOldSide = thread.isOldSide
        isResolved = thread.isResolved
        isOutdated = thread.isOutdated
        viewerCanReply = thread.viewerCanReply
        viewerCanResolve = thread.viewerCanResolve
        viewerCanUnresolve = thread.viewerCanUnresolve
        comments = thread.comments.map(CommentSignature.init)
    }
}

private struct CommentSignature: Hashable {
    let id: String
    let author: String
    let body: String
    let viewerCanUpdate: Bool
    let viewerCanDelete: Bool

    init(_ comment: DiffInlineComment) {
        id = comment.id
        author = comment.author
        body = comment.body
        viewerCanUpdate = comment.viewerCanUpdate
        viewerCanDelete = comment.viewerCanDelete
    }
}

private struct AnnotationSignature: Hashable {
    let id: String
    let checkName: String
    let newLine: Int
    let level: String
    let message: String
    let rawDetails: String?

    init(_ annotation: DiffInlineAnnotation) {
        id = annotation.id
        checkName = annotation.checkName
        newLine = annotation.newLine
        level = String(describing: annotation.level)
        message = annotation.message
        rawDetails = annotation.rawDetails
    }
}
