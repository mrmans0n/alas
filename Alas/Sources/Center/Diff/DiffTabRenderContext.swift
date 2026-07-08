import Combine
import Foundation

struct DiffTabRenderContextKey: Hashable {
    private let displayModel: DiffTabDisplayModelSignature
    private let draftComments: [DiffTabDraftCommentSignature]
    private let pendingDraftPlacement: DiffTabPendingDraftPlacementSignature?

    init(
        model: DiffDisplayModel,
        comments: [ReviewDraftComment],
        pendingDraftAnchor: DiffReviewLineAnchor?
    ) {
        displayModel = DiffTabDisplayModelSignature(filePath: model.filePath, groups: model.groups)
        draftComments = comments.map(DiffTabDraftCommentSignature.init)
        pendingDraftPlacement = pendingDraftAnchor.map(DiffTabPendingDraftPlacementSignature.init)
    }
}

struct DiffTabRenderContext: Equatable {
    struct Group: Equatable, Identifiable {
        let id: String
        let group: DiffDisplayGroup
        let segments: [ReviewDraftCommentRowSegmentation.Segment]

        var containsLocalAccessories: Bool {
            segments.contains { !$0.draftComments.isEmpty || $0.showsComposer }
        }
    }

    let key: DiffTabRenderContextKey
    let fileLevelDraftComments: [ReviewDraftComment]
    let draftPlacement: ReviewDraftCommentPlacement.Result
    let groupData: [Group]

    func group(id: String) -> Group? {
        groupData.first { $0.id == id }
    }
}

enum DiffTabRenderContextBuilder {
    static func build(
        model: DiffDisplayModel,
        comments: [ReviewDraftComment],
        pendingDraftAnchor: DiffReviewLineAnchor?
    ) -> DiffTabRenderContext {
        let key = DiffTabRenderContextKey(
            model: model,
            comments: comments,
            pendingDraftAnchor: pendingDraftAnchor
        )
        return build(
            key: key,
            model: model,
            comments: comments,
            pendingDraftAnchor: pendingDraftAnchor
        )
    }

    static func build(
        key: DiffTabRenderContextKey,
        model: DiffDisplayModel,
        comments: [ReviewDraftComment],
        pendingDraftAnchor: DiffReviewLineAnchor?
    ) -> DiffTabRenderContext {
        let draftPlacement = ReviewDraftCommentPlacement.position(comments, in: model.groups)
        let groupData = model.groups.map { group in
            DiffTabRenderContext.Group(
                id: group.id,
                group: group,
                segments: ReviewDraftCommentRowSegmentation.segments(
                    for: group,
                    placement: draftPlacement,
                    pendingAnchor: pendingDraftAnchor
                ).items
            )
        }

        return DiffTabRenderContext(
            key: key,
            fileLevelDraftComments: draftPlacement.fileLevel,
            draftPlacement: draftPlacement,
            groupData: groupData
        )
    }
}

@MainActor
final class DiffTabRenderContextCache: ObservableObject {
    private let maximumEntryCount: Int
    private var storage: [DiffTabRenderContextKey: DiffTabRenderContext] = [:]
    private var recency: [DiffTabRenderContextKey] = []

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
        key: DiffTabRenderContextKey,
        build: () -> DiffTabRenderContext
    ) -> DiffTabRenderContext {
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

    func removeAll() {
        storage.removeAll()
        recency.removeAll()
        #if DEBUG
        missCount = 0
        #endif
    }

    private func markRecentlyUsed(_ key: DiffTabRenderContextKey) {
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

private struct DiffTabDisplayModelSignature: Hashable {
    let filePath: String
    let groups: [DiffTabGroupSignature]

    init(filePath: String, groups: [DiffDisplayGroup]) {
        self.filePath = filePath
        self.groups = groups.map(DiffTabGroupSignature.init)
    }
}

private struct DiffTabGroupSignature: Hashable {
    let id: String
    let header: String
    let sourceHunk: DiffTabHunkSignature
    let rows: [DiffTabRowSignature]

    init(_ group: DiffDisplayGroup) {
        id = group.id
        header = group.header
        sourceHunk = DiffTabHunkSignature(group.sourceHunk)
        rows = group.rows.map(DiffTabRowSignature.init)
    }
}

private struct DiffTabHunkSignature: Hashable {
    let header: String
    let oldStart: Int
    let newStart: Int
    let lines: [DiffTabHunkLineSignature]

    init(_ hunk: ParsedDiff.Hunk) {
        header = hunk.header
        oldStart = hunk.oldStart
        newStart = hunk.newStart
        lines = hunk.lines.map(DiffTabHunkLineSignature.init)
    }
}

private struct DiffTabHunkLineSignature: Hashable {
    let kind: String
    let textHash: Int
    let oldNumber: Int?
    let newNumber: Int?

    init(_ line: ParsedDiff.Hunk.Line) {
        kind = String(describing: line.kind)
        textHash = line.text.hashValue
        oldNumber = line.oldNumber
        newNumber = line.newNumber
    }
}

private struct DiffTabRowSignature: Hashable {
    let id: String
    let kind: String
    let old: DiffTabLineSignature?
    let new: DiffTabLineSignature?
    let collapsedLineCount: Int
    let collapsedRows: [DiffTabRowSignature]
    let contextExpansion: DiffTabContextExpansionSignature?

    init(_ row: DiffDisplayRow) {
        id = row.id
        kind = String(describing: row.kind)
        old = row.old.map(DiffTabLineSignature.init)
        new = row.new.map(DiffTabLineSignature.init)
        collapsedLineCount = row.collapsedLineCount
        collapsedRows = row.collapsedRows.map(DiffTabRowSignature.init)
        contextExpansion = row.contextExpansion.map(DiffTabContextExpansionSignature.init)
    }
}

private struct DiffTabLineSignature: Hashable {
    let id: String
    let side: Int
    let oldLine: Int?
    let newLine: Int?
    let textHash: Int
    let lineNumber: Int?
    let kind: String
    let inlineSpansHash: Int
    let noTrailingNewline: Bool

    init(_ line: DiffDisplayLine) {
        id = line.id
        side = line.anchor.side.rawValue
        oldLine = line.anchor.oldLine
        newLine = line.anchor.newLine
        textHash = line.text.hashValue
        lineNumber = line.lineNumber
        kind = String(describing: line.kind)
        inlineSpansHash = line.inlineSpans.hashValue
        noTrailingNewline = line.noTrailingNewline
    }
}

private struct DiffTabContextExpansionSignature: Hashable {
    let groupID: String
    let boundary: String
    let remainingLineCount: Int

    init(_ expansion: DiffContextExpansionRow) {
        groupID = expansion.key.groupID
        boundary = expansion.boundary.rawValue
        remainingLineCount = expansion.remainingLineCount
    }
}

private struct DiffTabDraftCommentSignature: Hashable {
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
    let providerPublish: DiffTabProviderPublishSignature?
    let providerError: DiffTabProviderErrorSignature?

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
        providerPublish = comment.providerPublish.map(DiffTabProviderPublishSignature.init)
        providerError = comment.providerError.map(DiffTabProviderErrorSignature.init)
    }
}

private struct DiffTabProviderPublishSignature: Hashable {
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

private struct DiffTabProviderErrorSignature: Hashable {
    let provider: String
    let message: String
    let occurredAt: Date

    init(_ error: ReviewDraftProviderError) {
        provider = String(describing: error.provider)
        message = error.message
        occurredAt = error.occurredAt
    }
}

private struct DiffTabPendingDraftPlacementSignature: Hashable {
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
