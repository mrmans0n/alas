import AppKit
import SwiftUI

struct PendingContextExpansion {
    let key: DiffContextExpansionKey
    let mode: DiffContextExpansionMode
    let edge: DiffContextExpansionEdge?
}

/// O(1) signal that resets loaded context state when the file, its context
/// provider, or its structural layout changes.
struct DiffReviewContextStateSignature: Equatable {
    let fileID: String
    let providerID: String
    let structuralHash: Int?
}

enum DiffReviewActiveCommentCandidate: Equatable {
    case draft(String)
    case inlineFeedback(String)
    case thread(String)
}

enum DiffReviewHunkFusionResolver {
    static func states(for groups: [DiffReviewRenderContext.Group]) -> [DiffPaneHunkFusionState] {
        var states = DiffPaneHunkFusionResolver.states(for: groups.map(\.displayGroup))
        guard states.count == groups.count else { return states }

        for index in groups.indices.dropLast()
            where states[index].fusedWithNext && !groups[index + 1].inlineFeedback.isEmpty {
            states[index] = DiffPaneHunkFusionState(
                fusedWithPrevious: states[index].fusedWithPrevious,
                fusedWithNext: false
            )
            states[index + 1] = DiffPaneHunkFusionState(
                fusedWithPrevious: false,
                fusedWithNext: states[index + 1].fusedWithNext
            )
        }

        return states
    }
}

struct DiffReviewActiveCommentIDs {
    var hoveredDraftCommentID: String?
    var focusedDraftCommentID: String?
    var hoveredInlineFeedbackID: String?
    var focusedFeedbackID: String?
    var activeThreadID: String?

    var orderedCandidates: [DiffReviewActiveCommentCandidate] {
        [
            hoveredDraftCommentID.map(DiffReviewActiveCommentCandidate.draft),
            hoveredInlineFeedbackID.map(DiffReviewActiveCommentCandidate.inlineFeedback),
            activeThreadID.map(DiffReviewActiveCommentCandidate.thread),
            focusedDraftCommentID.map(DiffReviewActiveCommentCandidate.draft),
            focusedFeedbackID.map(DiffReviewActiveCommentCandidate.inlineFeedback),
        ].compactMap(\.self)
    }
}

enum ReviewDraftComposerKeyboardAction: Equatable {
    case save
    case cancel

    static func resolve(key: String, modifiers: NSEvent.ModifierFlags) -> Self? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if key == "\r", flags.contains(.command) {
            return .save
        }
        if key == "\u{1b}" {
            return .cancel
        }
        return nil
    }
}

enum ReviewDraftQuote {
    static func markdown(path: String, selectedText: String) -> String {
        let code = selectedText.trimmingCharacters(in: .newlines)
        var longestBacktickRun = 0
        var currentBacktickRun = 0
        for character in code {
            if character == "`" {
                currentBacktickRun += 1
                longestBacktickRun = max(longestBacktickRun, currentBacktickRun)
            } else {
                currentBacktickRun = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longestBacktickRun + 1))
        let language = LanguageRegistry.highlighterExtension(forPath: path)
        return "\(fence)\(language)\n\(code)\n\(fence)"
    }

    static func insertion(markdown: String, in text: String, replacing range: NSRange) -> String {
        let text = text as NSString
        let before = text.substring(to: range.location)
        let after = text.substring(from: NSMaxRange(range))
        let prefix = before.isEmpty || before.hasSuffix("\n") ? "" : "\n\n"
        let suffix = after.isEmpty || after.hasPrefix("\n") ? "" : "\n\n"
        return prefix + markdown + suffix
    }
}

struct ReviewDraftComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let theme: Theme
    let isFocused: FocusState<Bool>.Binding
    let focusRequestGeneration: Int
    let quoteMarkdown: String?
    let quoteInsertionGeneration: Int
    let onSave: () -> Void
    let onCancel: () -> Void

    init(
        text: Binding<String>,
        theme: Theme,
        isFocused: FocusState<Bool>.Binding,
        focusRequestGeneration: Int = 0,
        quoteMarkdown: String? = nil,
        quoteInsertionGeneration: Int = 0,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _text = text
        self.theme = theme
        self.isFocused = isFocused
        self.focusRequestGeneration = focusRequestGeneration
        self.quoteMarkdown = quoteMarkdown
        self.quoteInsertionGeneration = quoteInsertionGeneration
        self.onSave = onSave
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let textView = ReviewDraftComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.onKeyboardAction = context.coordinator.perform
        textView.onWindowChanged = { [weak coordinator = context.coordinator] in
            coordinator?.requestFocusIfNeeded()
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyTheme(to: scrollView, textView: textView)
        context.coordinator.requestFocusIfNeeded()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ReviewDraftComposerNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onKeyboardAction = context.coordinator.perform
        textView.onWindowChanged = { [weak coordinator = context.coordinator] in
            coordinator?.requestFocusIfNeeded()
        }
        applyTheme(to: scrollView, textView: textView)
        context.coordinator.requestQuoteInsertionIfNeeded()
        context.coordinator.requestFocusIfNeeded()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelScheduledFocusRequest()
        coordinator.cancelScheduledQuoteInsertion()
        guard let textView = scrollView.documentView as? ReviewDraftComposerNSTextView else { return }
        textView.onKeyboardAction = nil
        textView.onWindowChanged = nil
        coordinator.editorUndoManager.removeAllActions()
        textView.delegate = nil
    }

    private func applyTheme(to scrollView: NSScrollView, textView: NSTextView) {
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor(theme.color("bg-2")).cgColor
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = NSColor(theme.color("fg"))
        textView.insertionPointColor = NSColor(theme.color("accent"))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let editorUndoManager = UndoManager()
        var parent: ReviewDraftComposerTextEditor
        weak var textView: NSTextView?
        private var latestFulfilledFocusRequestGeneration = 0
        private var latestQuoteInsertionGeneration = 0
        private var scheduledQuoteInsertionTask: Task<Void, Never>?

        func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }
        private var scheduledFocusRequestGeneration: Int?
        private var scheduledFocusTask: Task<Void, Never>?

        init(_ parent: ReviewDraftComposerTextEditor) {
            self.parent = parent
        }

        deinit {
            scheduledFocusTask?.cancel()
            scheduledQuoteInsertionTask?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }

        func requestQuoteInsertionIfNeeded() {
            let generation = parent.quoteInsertionGeneration
            if generation == 0 {
                latestQuoteInsertionGeneration = 0
                scheduledQuoteInsertionTask?.cancel()
                return
            }
            guard generation != latestQuoteInsertionGeneration else { return }
            latestQuoteInsertionGeneration = generation
            scheduledQuoteInsertionTask?.cancel()
            scheduledQuoteInsertionTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      self.parent.quoteInsertionGeneration == generation,
                      let markdown = self.parent.quoteMarkdown,
                      let textView = self.textView as? PairedDelimiterTextView
                else { return }
                let range = textView.selectedRange()
                let insertion = ReviewDraftQuote.insertion(markdown: markdown, in: textView.string, replacing: range)
                textView.performNativeTextInsertion {
                    textView.insertText(insertion, replacementRange: range)
                }
            }
        }

        func cancelScheduledQuoteInsertion() {
            scheduledQuoteInsertionTask?.cancel()
            scheduledQuoteInsertionTask = nil
        }

        func requestFocusIfNeeded() {
            let generation = parent.focusRequestGeneration
            let hasExplicitRequest = generation > latestFulfilledFocusRequestGeneration
            let hasLegacyRequest = generation == 0 && parent.isFocused.wrappedValue
            guard hasExplicitRequest || hasLegacyRequest else {
                cancelScheduledFocusRequest()
                return
            }
            guard scheduledFocusRequestGeneration != generation else { return }

            cancelScheduledFocusRequest()
            scheduledFocusRequestGeneration = generation
            scheduledFocusTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                defer {
                    if self.scheduledFocusRequestGeneration == generation {
                        self.scheduledFocusRequestGeneration = nil
                        self.scheduledFocusTask = nil
                    }
                }

                guard self.parent.focusRequestGeneration == generation else { return }
                if generation == 0 {
                    guard self.parent.isFocused.wrappedValue else { return }
                } else {
                    guard generation > self.latestFulfilledFocusRequestGeneration else { return }
                }
                guard let textView = self.textView,
                      let window = textView.window
                else { return }

                if window.firstResponder !== textView {
                    guard window.makeFirstResponder(textView) else { return }
                }
                if generation > 0 {
                    self.latestFulfilledFocusRequestGeneration = generation
                }
            }
        }

        func cancelScheduledFocusRequest() {
            scheduledFocusTask?.cancel()
            scheduledFocusTask = nil
            scheduledFocusRequestGeneration = nil
        }

        func perform(_ action: ReviewDraftComposerKeyboardAction) {
            switch action {
            case .save:
                parent.onSave()
            case .cancel:
                parent.onCancel()
            }
        }
    }
}

private final class ReviewDraftComposerNSTextView: PairedDelimiterTextView {
    var onKeyboardAction: (@MainActor (ReviewDraftComposerKeyboardAction) -> Void)?
    var onWindowChanged: (@MainActor () -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        if let action = ReviewDraftComposerKeyboardAction.resolve(key: key, modifiers: event.modifierFlags) {
            onKeyboardAction?(action)
            return
        }
        super.keyDown(with: event)
    }
}

enum ReviewDraftCommentPlacement {
    struct RowKey: Hashable, Equatable {
        let side: DiffReviewInlineFeedbackSide
        let line: Int
    }

    struct Result: Equatable {
        let fileLevel: [ReviewDraftComment]
        let image: [ReviewDraftComment]
        let byRowAnchor: [RowKey: [ReviewDraftComment]]
        let groupIDByCommentID: [String: String]
    }

    static func position(
        _ comments: [ReviewDraftComment],
        in groups: [DiffDisplayGroup]
    ) -> Result {
        let visibleKeys = Set(groups.flatMap(allRowKeys))
        let groupIDByKey = firstGroupIDByRowKey(in: groups)
        var fileLevel: [ReviewDraftComment] = []
        var image: [ReviewDraftComment] = []
        var byRowAnchor: [RowKey: [ReviewDraftComment]] = [:]
        var groupIDByCommentID: [String: String] = [:]

        for comment in comments where comment.state != .dismissed {
            if case .image = comment.anchor {
                image.append(comment)
                continue
            }
            guard let lineRange = comment.normalizedLineRange else {
                fileLevel.append(comment)
                continue
            }
            let key = RowKey(side: comment.side, line: lineRange.upperBound)
            if visibleKeys.contains(key) {
                byRowAnchor[key, default: []].append(comment)
                if let groupID = groupIDByKey[key] {
                    groupIDByCommentID[comment.id] = groupID
                }
            } else {
                fileLevel.append(comment)
            }
        }

        return Result(
            fileLevel: sorted(fileLevel),
            image: sorted(image),
            byRowAnchor: byRowAnchor.mapValues(sorted),
            groupIDByCommentID: groupIDByCommentID
        )
    }

    private static func firstGroupIDByRowKey(in groups: [DiffDisplayGroup]) -> [RowKey: String] {
        var output: [RowKey: String] = [:]
        for group in groups {
            for key in allRowKeys(in: group) where output[key] == nil {
                output[key] = group.id
            }
        }
        return output
    }

    static func visibleRowKeys(in group: DiffDisplayGroup) -> [RowKey] {
        group.rows.flatMap { row -> [RowKey] in
            visibleRowKeys(in: row)
        }
    }

    static func allRowKeys(in group: DiffDisplayGroup) -> [RowKey] {
        group.rows.flatMap(allRowKeys)
    }

    static func visibleRowKeys(in row: DiffDisplayRow) -> [RowKey] {
        var keys: [RowKey] = []
        if let oldLine = row.old?.lineNumber {
            keys.append(RowKey(side: .old, line: oldLine))
        }
        if let newLine = row.new?.lineNumber {
            keys.append(RowKey(side: .new, line: newLine))
        }
        for line in Set([row.old?.lineNumber, row.new?.lineNumber].compactMap(\.self)).sorted() {
            keys.append(RowKey(side: .unknown, line: line))
        }
        return keys
    }

    static func allRowKeys(in row: DiffDisplayRow) -> [RowKey] {
        visibleRowKeys(in: row) + row.collapsedRows.flatMap(allRowKeys)
    }

    static func sorted(_ comments: [ReviewDraftComment]) -> [ReviewDraftComment] {
        comments.sorted { lhs, rhs in
            if lhs.path != rhs.path {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            if let lhsRange = lhs.normalizedLineRange, let rhsRange = rhs.normalizedLineRange {
                if lhsRange.lowerBound != rhsRange.lowerBound {
                    return lhsRange.lowerBound < rhsRange.lowerBound
                }
                if lhsRange.upperBound != rhsRange.upperBound {
                    return lhsRange.upperBound < rhsRange.upperBound
                }
            } else if lhs.normalizedLineRange != nil {
                return false
            } else if rhs.normalizedLineRange != nil {
                return true
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    static func comments(
        matching keys: [RowKey],
        in placement: Result,
        groupID: String? = nil,
        excludingIDs excludedIDs: Set<String> = []
    ) -> [ReviewDraftComment] {
        var seenIDs = excludedIDs
        var comments: [ReviewDraftComment] = []
        for key in keys {
            for comment in placement.byRowAnchor[key] ?? [] {
                if let groupID, placement.groupIDByCommentID[comment.id] != groupID {
                    continue
                }
                guard seenIDs.insert(comment.id).inserted else { continue }
                comments.append(comment)
            }
        }
        return sorted(comments)
    }
}

enum ReviewDraftCommentRowSegmentation {
    struct Segment: Equatable, Identifiable {
        let id: String
        let rows: [DiffDisplayRow]
        let rowsSignature: DiffDisplayRowsSignature
        let draftComments: [ReviewDraftComment]
        let showsComposer: Bool

        init(
            id: String,
            rows: [DiffDisplayRow],
            rowsSignature: DiffDisplayRowsSignature? = nil,
            draftComments: [ReviewDraftComment],
            showsComposer: Bool
        ) {
            self.id = id
            self.rows = rows
            self.rowsSignature = rowsSignature ?? DiffDisplayRowsSignature(rows)
            self.draftComments = draftComments
            self.showsComposer = showsComposer
        }

        static func == (lhs: Segment, rhs: Segment) -> Bool {
            lhs.id == rhs.id
                && lhs.rowsSignature == rhs.rowsSignature
                && lhs.draftComments == rhs.draftComments
                && lhs.showsComposer == rhs.showsComposer
        }
    }

    struct Result: Equatable {
        let items: [Segment]

        var containsLocalAccessories: Bool {
            items.contains { !$0.draftComments.isEmpty || $0.showsComposer }
        }
    }

    static func segments(
        for group: DiffDisplayGroup,
        placement: ReviewDraftCommentPlacement.Result,
        pendingAnchor: DiffReviewLineAnchor?,
        canCreateDraftComment: Bool = true
    ) -> Result {
        let pendingKey = pendingAnchor.flatMap { pendingRowKey(for: $0, in: group) }
        let duplicatePendingKey = pendingKey.map { key in
            group.rows.filter { ReviewDraftCommentPlacement.allRowKeys(in: $0).contains(key) }.count > 1
        } ?? false
        var segments: [Segment] = []
        var bufferedRows: [DiffDisplayRow] = []
        var emittedCommentIDs: Set<String> = []

        for row in group.rows {
            bufferedRows.append(row)
            let keys = ReviewDraftCommentPlacement.allRowKeys(in: row)
            let comments = ReviewDraftCommentPlacement.comments(
                matching: keys,
                in: placement,
                groupID: group.id,
                excludingIDs: emittedCommentIDs
            )
            emittedCommentIDs.formUnion(comments.map(\.id))
            let showsComposer = canCreateDraftComment && (pendingKey.map { key in
                guard keys.contains(key) else { return false }
                guard duplicatePendingKey, let pendingAnchor else { return true }
                return rowContainsDisplayRowIndex(pendingAnchor.endRowIndex, row: row)
            } ?? false)
            guard !comments.isEmpty || showsComposer else { continue }

            segments.append(Segment(
                id: "\(group.id)-segment-\(segments.count)",
                rows: bufferedRows,
                draftComments: comments,
                showsComposer: showsComposer
            ))
            bufferedRows = []
        }

        if !bufferedRows.isEmpty {
            segments.append(Segment(
                id: "\(group.id)-segment-\(segments.count)",
                rows: bufferedRows,
                draftComments: [],
                showsComposer: false
            ))
        }

        return Result(items: segments)
    }

    static func canonicalPendingAnchor(
        _ anchor: DiffReviewLineAnchor,
        in groups: [DiffDisplayGroup]
    ) -> DiffReviewLineAnchor {
        guard anchor.side == .unknown else { return anchor }
        guard groups.contains(where: { canPlaceUnknownAnchor(anchor, in: $0) }) else { return anchor }

        if let range = selectedLineRange(anchor.selectedLines, side: .new, requiresChange: true) {
            return DiffReviewLineAnchor(
                path: anchor.path,
                side: .new,
                line: range.lowerBound,
                endLine: range.lowerBound == range.upperBound ? nil : range.upperBound,
                rowIndex: anchor.rowIndex,
                endRowIndex: anchor.endRowIndex,
                selectedLines: anchor.selectedLines,
                selectedText: anchor.selectedText
            )
        }

        if let range = selectedLineRange(anchor.selectedLines, side: .old, requiresChange: true) {
            return DiffReviewLineAnchor(
                path: anchor.path,
                side: .old,
                line: range.lowerBound,
                endLine: range.lowerBound == range.upperBound ? nil : range.upperBound,
                rowIndex: anchor.rowIndex,
                endRowIndex: anchor.endRowIndex,
                selectedLines: anchor.selectedLines,
                selectedText: anchor.selectedText
            )
        }

        return anchor
    }

    static func sourceIndexedAnchor(
        _ anchor: DiffReviewLineAnchor,
        in rows: [DiffDisplayRow]
    ) -> DiffReviewLineAnchor {
        let rowIndex = sourceRowIndex(for: anchor.rowIndex, side: anchor.side, in: rows) ?? anchor.rowIndex
        let endRowIndex = sourceRowIndex(for: anchor.endRowIndex, side: anchor.side, in: rows) ?? anchor.endRowIndex
        guard rowIndex != anchor.rowIndex || endRowIndex != anchor.endRowIndex else { return anchor }

        return DiffReviewLineAnchor(
            path: anchor.path,
            side: anchor.side,
            line: anchor.line,
            endLine: anchor.endLine,
            rowIndex: rowIndex,
            endRowIndex: endRowIndex,
            selectedLines: anchor.selectedLines,
            selectedText: anchor.selectedText
        )
    }

    private static func pendingRowKey(
        for anchor: DiffReviewLineAnchor,
        in group: DiffDisplayGroup
    ) -> ReviewDraftCommentPlacement.RowKey? {
        guard anchor.side == .unknown else {
            return ReviewDraftCommentPlacement.RowKey(side: anchor.side, line: anchor.draftPlacementLine)
        }

        guard canPlaceUnknownAnchor(anchor, in: group) else { return nil }
        let canonicalAnchor = canonicalPendingAnchor(anchor, in: [group])
        return ReviewDraftCommentPlacement.RowKey(
            side: canonicalAnchor.side,
            line: canonicalAnchor.draftPlacementLine
        )
    }

    private static func canPlaceUnknownAnchor(
        _ anchor: DiffReviewLineAnchor,
        in group: DiffDisplayGroup
    ) -> Bool {
        let keys = Set(ReviewDraftCommentPlacement.allRowKeys(in: group))
        return keys.contains(ReviewDraftCommentPlacement.RowKey(side: .unknown, line: anchor.draftPlacementLine))
            || keys.contains(ReviewDraftCommentPlacement.RowKey(side: .unknown, line: anchor.line))
    }

    private static func rowContainsDisplayRowIndex(_ rowIndex: Int, row: DiffDisplayRow) -> Bool {
        row.old?.anchor.rowIndex == rowIndex
            || row.new?.anchor.rowIndex == rowIndex
            || row.collapsedRows.contains { rowContainsDisplayRowIndex(rowIndex, row: $0) }
    }

    private static func sourceRowIndex(
        for localRowIndex: Int,
        side: DiffReviewInlineFeedbackSide,
        in rows: [DiffDisplayRow]
    ) -> Int? {
        guard rows.indices.contains(localRowIndex) else { return nil }
        let row = rows[localRowIndex]
        switch side {
        case .old:
            return row.old?.anchor.rowIndex ?? row.new?.anchor.rowIndex
        case .new:
            return row.new?.anchor.rowIndex ?? row.old?.anchor.rowIndex
        case .unknown:
            return row.old?.anchor.rowIndex ?? row.new?.anchor.rowIndex
        }
    }

    private static func selectedLineRange(
        _ selectedLines: [DiffReviewLineAnchor.SelectedLine],
        side: DiffReviewInlineFeedbackSide,
        requiresChange: Bool
    ) -> ClosedRange<Int>? {
        let lines = selectedLines.compactMap { line -> Int? in
            guard line.side == side else { return nil }
            guard !requiresChange || line.isChange else { return nil }
            return line.line
        }
        guard let lower = lines.min(), let upper = lines.max() else { return nil }
        return lower...upper
    }
}

enum DiffReviewInlineFeedbackPlacement {
    struct Result: Equatable {
        let fileLevel: [DiffReviewInlineFeedback]
        let byGroupID: [String: [DiffReviewInlineFeedback]]
    }

    static func position(
        _ items: [DiffReviewInlineFeedback],
        in groups: [DiffDisplayGroup]
    ) -> Result {
        var fileLevel: [DiffReviewInlineFeedback] = []
        var byGroupID: [String: [DiffReviewInlineFeedback]] = [:]

        for item in items {
            guard let line = item.anchor.line,
                  let group = groups.first(where: { contains(line: line, side: item.anchor.side, in: $0) })
            else {
                fileLevel.append(item)
                continue
            }
            byGroupID[group.id, default: []].append(item)
        }

        return Result(fileLevel: fileLevel, byGroupID: byGroupID)
    }

    private static func contains(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        in group: DiffDisplayGroup
    ) -> Bool {
        group.rows.contains { row in
            contains(line: line, side: side, in: row)
        }
    }

    private static func contains(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        in row: DiffDisplayRow
    ) -> Bool {
        if rowMatches(line: line, side: side, row: row) {
            return true
        }
        return row.collapsedRows.contains { collapsedRow in
            contains(line: line, side: side, in: collapsedRow)
        }
    }

    private static func rowMatches(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        row: DiffDisplayRow
    ) -> Bool {
        switch side {
        case .new:
            return row.new?.lineNumber == line
        case .old:
            return row.old?.lineNumber == line
        case .unknown:
            return row.new?.lineNumber == line || row.old?.lineNumber == line
        }
    }
}

enum ReviewDraftCommentDisplayPolicy {
    static let cardMinimumHeight: CGFloat = 86
    private static let estimatedBodyCharactersPerLine = 86
    private static let estimatedBodyLineHeight: CGFloat = 15.5
    private static let cardNonBodyHeight: CGFloat = 52
    private static let stackVerticalPadding: CGFloat = 20
    private static let rowSpacing: CGFloat = 6

    static func estimatedHeight(for comments: [ReviewDraftComment]) -> CGFloat {
        guard !comments.isEmpty else { return 0 }

        let visibleHeights = comments.reduce(CGFloat(0)) { total, comment in
            total + estimatedCardHeight(for: comment)
        }
        let spacingHeight = CGFloat(max(0, comments.count - 1)) * rowSpacing
        return stackVerticalPadding + visibleHeights + spacingHeight
    }

    static func estimatedCardHeight(for comment: ReviewDraftComment) -> CGFloat {
        let bodyLineCount = estimatedLineCount(for: comment.bodyMarkdown)
        let bodyHeight = CGFloat(bodyLineCount) * estimatedBodyLineHeight

        return max(cardMinimumHeight, cardNonBodyHeight + bodyHeight)
    }

    private static func estimatedLineCount(for source: String) -> Int {
        let logicalLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        return logicalLines.reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(estimatedBodyCharactersPerLine))))
        }
    }
}

enum DiffReviewInlineFeedbackDisplayPolicy {
    static let maximumVisibleCards = 3
    static let cardMinimumHeight: CGFloat = 78
    static let moreRowEstimatedHeight: CGFloat = 20
    private static let estimatedBodyCharactersPerLine = 86
    private static let estimatedBodyLineHeight: CGFloat = 15.5
    private static let cardNonBodyHeight: CGFloat = 46
    private static let stackVerticalPadding: CGFloat = 20
    private static let rowSpacing: CGFloat = 6

    struct Display {
        let visibleItems: [DiffReviewInlineFeedback]
        let hiddenCount: Int
    }

    static func display(for items: [DiffReviewInlineFeedback]) -> Display {
        display(for: items, includingRequiredIDs: [])
    }

    static func display(
        for items: [DiffReviewInlineFeedback],
        includingRequiredIDs requiredIDs: Set<String>
    ) -> Display {
        let visibleItems = Array(items.prefix(maximumVisibleCards))
        let visibleIDs = Set(visibleItems.map(\.id))
        let requiredItems = items.filter { requiredIDs.contains($0.id) && !visibleIDs.contains($0.id) }
        let visible = visibleItems + requiredItems
        return Display(
            visibleItems: visible,
            hiddenCount: max(0, items.count - visible.count)
        )
    }

    static func estimatedHeight(for itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }

        let visibleCount = min(itemCount, maximumVisibleCards)
        let hiddenCount = max(0, itemCount - visibleCount)
        let rowCount = visibleCount + (hiddenCount > 0 ? 1 : 0)
        let rowHeights = CGFloat(visibleCount) * cardMinimumHeight
            + (hiddenCount > 0 ? moreRowEstimatedHeight : 0)
        let spacingHeight = CGFloat(max(0, rowCount - 1)) * rowSpacing

        return stackVerticalPadding + rowHeights + spacingHeight
    }

    static func estimatedHeight(for items: [DiffReviewInlineFeedback]) -> CGFloat {
        guard !items.isEmpty else { return 0 }

        let display = display(for: items)
        let visibleHeights = display.visibleItems.reduce(CGFloat(0)) { total, item in
            total + estimatedCardHeight(for: item)
        }
        let rowCount = display.visibleItems.count + (display.hiddenCount > 0 ? 1 : 0)
        let moreHeight = display.hiddenCount > 0 ? moreRowEstimatedHeight : 0
        let spacingHeight = CGFloat(max(0, rowCount - 1)) * rowSpacing

        return stackVerticalPadding + visibleHeights + moreHeight + spacingHeight
    }

    static func estimatedCardHeight(for item: DiffReviewInlineFeedback) -> CGFloat {
        let bodyLineCount = estimatedLineCount(for: item.bodyPreview)
        let bodyHeight = CGFloat(bodyLineCount) * estimatedBodyLineHeight

        return max(cardMinimumHeight, cardNonBodyHeight + bodyHeight)
    }

    private static func estimatedLineCount(for source: String) -> Int {
        let logicalLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        return logicalLines.reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(estimatedBodyCharactersPerLine))))
        }
    }
}

enum DiffReviewInlineFeedbackMarkdown {
    private static let typography = ACPChatTypography(fontFamily: "", fontSize: 11)

    static func view(_ source: String, noninteractiveTapAction: (() -> Void)? = nil) -> some View {
        ACPMarkdownText(
            raw: source,
            typography: typography,
            showsCodeBlockCopyButton: false,
            noninteractiveTapAction: noninteractiveTapAction
        )
    }

    @MainActor
    static func inlineMarkdown(_ source: String) -> AttributedString {
        var result = AttributedString()
        for block in ACPMarkdownText.parse(source) {
            let (text, literal) = {
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                return (text, false)
            case .taskList(let items):
                return (items.map { "[\($0.isChecked ? "x" : " ")] \($0.text)" }.joined(separator: " "), false)
            case .code(_, let body), .streamingCode(_, let body), .mermaid(let body):
                return (body, true)
            case .table(let header, let rows):
                return (([header] + rows).map { $0.joined(separator: " ") }.joined(separator: " "), false)
            }
            }()
            if !result.characters.isEmpty { result.append(AttributedString("\n")) }
            result.append(literal ? AttributedString(text) : ACPMarkdownInlineRenderer.cleanAttributedString(text))
        }
        return result
    }

    @MainActor
    static func plainText(_ source: String) -> String {
        ACPMarkdownText.parse(source).compactMap { block -> String? in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                return ACPMarkdownInlineRenderer.plainText(text)
            case .taskList(let items):
                return items.map { ACPMarkdownInlineRenderer.plainText($0.text) }.joined(separator: " ")
            case .code(_, let body), .streamingCode(_, let body):
                return body
            case .mermaid(let source):
                return source
            case .table(let header, let rows):
                return ([header] + rows).map { row in
                    row.map { ACPMarkdownInlineRenderer.plainText($0) }.joined(separator: " ")
                }.joined(separator: " ")
            }
        }.joined(separator: " ")
    }
}

struct ReviewDraftCommentEditorState: Equatable {
    var isEditing = false
    var editingBody = ""
}

struct ReviewDraftCommentCard: View {
    let comment: ReviewDraftComment
    let file: DiffReviewFileSummary
    let isFocused: Bool
    var markerNumber: Int? = nil
    let actions: ReviewDraftCommentActions
    let reviewFeedbackTarget: ReviewFeedbackTarget
    let onSelect: (ReviewDraftComment) -> Void
    var onHoverChange: (Bool) -> Void = { _ in }
    var onEditorActiveChange: (Bool) -> Void = { _ in }
    var editorState: Binding<ReviewDraftCommentEditorState>?

    @Environment(\.theme) private var theme
    @State private var localEditorState = ReviewDraftCommentEditorState()
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardContent
                .background(selectionPressMarker)

            actionRow
        }
        .padding(8)
        .frame(minHeight: ReviewDraftCommentDisplayPolicy.cardMinimumHeight, alignment: .top)
        .background(isFocused ? theme.color("accent-soft") : theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? theme.color("accent") : statusColor.opacity(0.65), lineWidth: isFocused ? 1 : 0.75)
        )
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-comment-\(comment.id)",
                label: accessibilityLabel
            )
        )
        .background(focusedMarker)
        .onHover { hovering in
            onHoverChange(Self.reportsHover(isHovered: hovering, isFocused: isFocused))
        }
        .onChange(of: editorStateBinding.wrappedValue.isEditing) { _, isEditing in
            onEditorActiveChange(isEditing)
        }
    }

    static func reportsHover(isHovered: Bool, isFocused: Bool) -> Bool {
        isHovered
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 3)
                .contentShape(Rectangle())
                .onTapGesture(perform: selectWhenNotEditing)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(draftLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)

                    if let markerNumber {
                        Text("#\(markerNumber)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.color("accent"))
                    }

                    Text(lineDescription)
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-faint"))

                    if comment.state == .resolved {
                        Text(resolvedLabel)
                            .font(.system(size: 10))
                            .foregroundColor(theme.color("fg-faint"))
                    }
                }
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture(perform: selectWhenNotEditing)

                ForEach(providerStateLabels.indices, id: \.self) { index in
                    let label = providerStateLabels[index]
                    Text(label.text)
                        .font(.system(size: 10))
                        .foregroundColor(label.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if editorStateBinding.wrappedValue.isEditing {
                    ReviewDraftComposerTextEditor(
                        text: editorStateBinding.editingBody,
                        theme: theme,
                        isFocused: $editorFocused,
                        onSave: saveEditingComment,
                        onCancel: cancelEditingComment
                    )
                    .frame(minHeight: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.color("line"), lineWidth: 0.75)
                    )
                    .accessibilityIdentifier("diff-review-draft-comment-editor-\(comment.id)")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        DiffReviewInlineFeedbackMarkdown.view(
                            comment.bodyMarkdown,
                            noninteractiveTapAction: selectWhenNotEditing
                        )

                        ForEach(comment.allReplies) { reply in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reply.author.displayName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.color("accent"))
                                DiffReviewInlineFeedbackMarkdown.view(
                                    reply.bodyMarkdown,
                                    noninteractiveTapAction: selectWhenNotEditing
                                )
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(theme.color("accent"))
                                    .frame(width: 2)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var selectionPressMarker: some View {
        if !editorStateBinding.wrappedValue.isEditing {
            ReviewDraftCommentActionPressMarker(
                identifier: "diff-review-draft-comment-select-\(comment.id)",
                label: "Select draft comment",
                action: { onSelect(comment) }
            )
        }
    }

    private func selectWhenNotEditing() {
        guard !editorStateBinding.wrappedValue.isEditing else { return }
        onSelect(comment)
    }

    @ViewBuilder
    private var focusedMarker: some View {
        if isFocused {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-comment-focused-\(comment.id)",
                label: accessibilityLabel
            )
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let availability = actions.availability(comment)
        if availability.canEdit
            || availability.canDelete
            || availability.canResolve
            || availability.canDismiss
            || availability.canCopyPrompt
            || availability.canShowSendToAgent
            || availability.canPublishProvider
        {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if editorStateBinding.wrappedValue.isEditing {
                    actionButton(id: "save", title: "Save") {
                        saveEditingComment()
                    }
                    actionButton(id: "cancel", title: "Cancel") {
                        cancelEditingComment()
                    }
                } else if availability.canEdit {
                    actionButton(id: "edit", title: "Edit") {
                        editorStateBinding.wrappedValue.editingBody = comment.bodyMarkdown
                        editorStateBinding.wrappedValue.isEditing = true
                        editorFocused = true
                    }
                }
                if availability.canDelete {
                    actionButton(id: "delete", title: "Delete") {
                        actions.delete(comment)
                    }
                }
                if availability.canResolve {
                    actionButton(id: "resolve", title: "Resolve") {
                        actions.resolve(comment)
                    }
                }
                if availability.canDismiss {
                    actionButton(id: "dismiss", title: "Dismiss") {
                        actions.dismiss(comment)
                    }
                }
                if availability.canCopyPrompt {
                    actionButton(id: "copy", title: "Copy") {
                        actions.copyPrompt(feedbackBundle)
                    }
                }
                if availability.canPublishProvider {
                    actionButton(id: "publish", title: "Publish") {
                        actions.publishProvider(comment)
                    }
                }
                if availability.canShowSendToAgent {
                    sendToAgentControl(isEnabled: availability.canSendToAgent)
                }
            }
        }
    }

    @ViewBuilder
    private func sendToAgentControl(isEnabled: Bool) -> some View {
        let targets = actions.agentTargets()
        if targets.count > 1 {
            Menu {
                let existingTargets = targets.filter { !$0.isNewChat }
                let newChatTargets = targets.filter { $0.isNewChat }
                ForEach(existingTargets) { target in
                    Button {
                        actions.sendToAgent(feedbackBundle, target)
                    } label: {
                        sendToAgentTargetLabel(target)
                    }
                }
                if !existingTargets.isEmpty, !newChatTargets.isEmpty {
                    Divider()
                }
                ForEach(newChatTargets) { target in
                    Button {
                        actions.sendToAgent(feedbackBundle, target)
                    } label: {
                        sendToAgentTargetLabel(target)
                    }
                }
            } label: {
                sendActionLabel(enabled: isEnabled, showsMenuIndicator: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(!isEnabled)
            .help("Send")
            .accessibilityIdentifier("diff-review-draft-comment-action-send-\(comment.id)")
            .accessibilityLabel("Send")
        } else {
            sendActionButton(enabled: isEnabled) {
                guard let target = targets.first else { return }
                actions.sendToAgent(feedbackBundle, target)
            }
        }
    }

    private func sendToAgentTargetLabel(_ target: ReviewFeedbackAgentTarget) -> some View {
        Label {
            Text(target.title)
        } icon: {
            if let agent = actions.agent(target) {
                Image(nsImage: AgentLogoView.menuImage(for: agent, size: 14))
            } else {
                Image(systemName: "sparkle")
            }
        }
    }

    private func sendActionButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            sendActionLabel(enabled: enabled, showsMenuIndicator: false)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Send")
        .accessibilityIdentifier(accessibilityIdentifier(forActionID: "send"))
        .accessibilityLabel("Send")
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "\(markerIdentifier(forActionID: "send"))-label",
                label: "Send"
            )
        )
        .background(
            ReviewDraftCommentActionPressMarker(
                identifier: markerIdentifier(forActionID: "send"),
                label: "Send",
                isEnabled: enabled,
                action: action
            )
        )
    }

    private func sendActionLabel(enabled: Bool, showsMenuIndicator: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 9.5, weight: .semibold))
            Text("Send")
                .font(.system(size: 10, weight: .semibold))
            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .padding(.leading, 1)
            }
        }
        .foregroundColor(enabled ? theme.color("bg-0") : theme.color("fg-faint"))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(enabled ? theme.color("accent") : theme.color("bg-3"))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func actionButton(
        id: String,
        title: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(enabled ? theme.color("fg-muted") : theme.color("fg-faint"))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityIdentifier(accessibilityIdentifier(forActionID: id))
        .accessibilityLabel(title)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "\(markerIdentifier(forActionID: id))-label",
                label: title
            )
        )
        .background(
            ReviewDraftCommentActionPressMarker(
                identifier: markerIdentifier(forActionID: id),
                label: title,
                isEnabled: enabled,
                action: action
            )
        )
    }

    private func accessibilityIdentifier(forActionID id: String) -> String {
        return "diff-review-draft-comment-button-\(id)-\(comment.id)"
    }

    private func markerIdentifier(forActionID id: String) -> String {
        if id == "publish" {
            return "diff-review-draft-comment-publish-\(comment.id)"
        }
        return "diff-review-draft-comment-action-\(id)-\(comment.id)"
    }

    private func saveEditingComment() {
        actions.edit(comment, editorStateBinding.wrappedValue.editingBody)
        cancelEditingComment()
    }

    private func cancelEditingComment() {
        editorStateBinding.wrappedValue.isEditing = false
        editorStateBinding.wrappedValue.editingBody = ""
        editorFocused = false
    }

    private var editorStateBinding: Binding<ReviewDraftCommentEditorState> {
        editorState ?? $localEditorState
    }

    private var feedbackBundle: ReviewFeedbackBundle {
        ReviewFeedbackBundle(
            target: reviewFeedbackTarget,
            comments: [comment]
        )
    }

    private var lineDescription: String {
        switch comment.anchor {
        case .file:
            return "whole file"
        case .image(let side, let x, let y):
            return String(format: "%@ image at %.1f%%, %.1f%%", side.rawValue, x * 100, y * 100)
        case .line(_, let startLine, let endLine, _):
            let range = min(startLine, endLine ?? startLine)...max(startLine, endLine ?? startLine)
            if range.lowerBound == range.upperBound {
                return "line \(range.lowerBound)"
            }
            return "lines \(range.lowerBound)-\(range.upperBound)"
        }
    }

    private var draftLabel: String {
        let author = comment.effectiveAuthor
        return author.isAgent ? "\(author.displayName) draft" : "Local draft"
    }

    private var resolvedLabel: String {
        if let resolvedBy = comment.resolvedBy, resolvedBy.isAgent {
            return "resolved by \(resolvedBy.displayName)"
        }
        return "resolved"
    }

    private var accessibilityLabel: String {
        [
            "Local draft",
            lineDescription,
            comment.state == .resolved ? "resolved" : nil,
            providerStateLabels.map(\.text).joined(separator: ", "),
            DiffReviewInlineFeedbackMarkdown.plainText(comment.bodyMarkdown),
        ]
        .compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        .joined(separator: ", ")
    }

    private var providerStateLabels: [(text: String, color: Color)] {
        var labels: [(text: String, color: Color)] = []
        if let publish = comment.providerPublish {
            labels.append(("published to \(publish.provider.displayName)", theme.color("fg-faint")))
        }
        if let error = comment.providerError {
            labels.append(("\(error.provider.displayName) error: \(error.message)", theme.color("warn")))
        }
        return labels
    }

    private var statusColor: Color {
        switch comment.state {
        case .active:
            theme.color("warn")
        case .resolved:
            theme.color("add")
        case .dismissed:
            theme.color("fg-muted")
        }
    }
}

extension DiffReviewLineAnchor {
    var draftPlacementLine: Int {
        endLine ?? line
    }
}

struct ReviewDraftCommentActionPressMarker: NSViewRepresentable {
    let identifier: String
    let label: String
    var isEnabled = true
    let action: () -> Void

    func makeNSView(context: Context) -> ReviewDraftCommentActionPressView {
        let view = ReviewDraftCommentActionPressView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
        return view
    }

    func updateNSView(_ view: ReviewDraftCommentActionPressView, context: Context) {
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
    }
}

final class ReviewDraftCommentActionPressView: NSView {
    var isEnabled = true
    var action: () -> Void = {}

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action()
        return true
    }
}

struct DiffReviewInlineFeedbackCard: View {
    let item: DiffReviewInlineFeedback
    let file: DiffReviewFileSummary
    let isFocused: Bool
    let actions: DiffReviewInlineFeedbackActions
    let onSelect: (DiffReviewInlineFeedback) -> Void
    var onHoverChange: (Bool) -> Void = { _ in }
    var onEditorActiveChange: (Bool) -> Void = { _ in }
    var replyEditorState: Binding<DiffReviewInlineFeedbackReplyEditorState>?

    @Environment(\.theme) private var theme
    @State private var localReplyEditor = DiffReviewInlineFeedbackReplyEditorState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardContent
                .background(
                    ReviewDraftCommentActionPressMarker(
                        identifier: "diff-review-inline-feedback-select-\(item.id)",
                        label: "Select inline feedback",
                        action: select
                    )
                )

            actionRow
        }
        .padding(8)
        .frame(minHeight: DiffReviewInlineFeedbackDisplayPolicy.cardMinimumHeight, alignment: .top)
        .background(isFocused ? theme.color("accent-soft") : theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? theme.color("accent") : theme.color("line"), lineWidth: isFocused ? 1 : 0.5)
        )
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-\(item.id)",
                label: accessibilityLabel
            )
        )
        .background(focusedMarker)
        .onHover { hovering in
            onHoverChange(Self.reportsHover(isHovered: hovering, isFocused: isFocused))
        }
        .onChange(of: replyEditorBinding.wrappedValue.isReplying) { _, isReplying in
            onEditorActiveChange(isReplying)
        }
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 3)
                .contentShape(Rectangle())
                .onTapGesture(perform: select)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.providerName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)

                    if let author = item.author, !author.isEmpty {
                        Text(author)
                            .font(.system(size: 10))
                            .foregroundColor(theme.color("fg-muted"))
                    }

                    if let line = item.anchor.line {
                        Text("line \(line)")
                            .font(.system(size: 10))
                            .foregroundColor(theme.color("fg-faint"))
                    }
                }
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture(perform: select)

                DiffReviewInlineFeedbackMarkdown.view(item.bodyPreview, noninteractiveTapAction: select)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private func select() {
        DiffReviewInlineFeedbackCardInteraction.select(item, onSelect: onSelect)
    }

    static func reportsHover(isHovered: Bool, isFocused: Bool) -> Bool {
        isHovered
    }

    @ViewBuilder
    private var focusedMarker: some View {
        if isFocused {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-focused-\(item.id)",
                label: accessibilityLabel
            )
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let availability = actions.availability(item, file)
        if replyEditorBinding.wrappedValue.isReplying {
            VStack(alignment: .leading, spacing: 6) {
                PairedTextEditor(
                    text: replyEditorBinding.body,
                    font: .systemFont(ofSize: 11.5),
                    textColor: NSColor(theme.color("fg")),
                    placeholder: "Reply"
                )
                    .frame(minHeight: 32, maxHeight: 96)
                    .padding(7)
                    .background(theme.color("bg-1"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .topLeading) {
                        if replyEditorBinding.wrappedValue.body.isEmpty {
                            Text("Reply")
                                .font(.system(size: 11.5))
                                .foregroundColor(theme.color("fg-muted"))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Reply")
                    .accessibilityIdentifier("diff-review-inline-feedback-reply-\(item.id)")

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    inlineActionButton(id: "reply-save", title: "Save") {
                        _ = replyEditorBinding.wrappedValue.save(item) { feedback, body in
                            actions.replyProvider(feedback, file, body)
                        }
                    }
                    inlineActionButton(id: "reply-cancel", title: "Cancel") {
                        replyEditorBinding.wrappedValue.cancel()
                    }
                }
            }
        } else if availability.canOpenProvider
            || availability.canCopyContext
            || availability.canSendToAgent
            || availability.canReplyProvider
            || availability.canResolveProvider
            || availability.canUnresolveProvider {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if availability.canOpenProvider {
                    inlineActionButton(id: "open", title: "Open") {
                        DiffReviewInlineFeedbackCardInteraction.open(item) { feedback in
                            actions.openProvider(feedback, file)
                        }
                    }
                }
                if availability.canCopyContext {
                    inlineActionButton(id: "copy", title: "Copy") {
                        DiffReviewInlineFeedbackCardInteraction.copy(item) { feedback in
                            actions.copyContext(feedback, file)
                        }
                    }
                }
                if availability.canSendToAgent {
                    inlineActionButton(id: "send", title: "Send") {
                        DiffReviewInlineFeedbackCardInteraction.send(item) { feedback in
                            actions.sendToAgent(feedback, file)
                        }
                    }
                }
                if availability.canReplyProvider {
                    inlineActionButton(id: "reply", title: "Reply") {
                        replyEditorBinding.wrappedValue.start()
                    }
                }
                if availability.canResolveProvider {
                    inlineActionButton(id: "resolve", title: "Resolve") {
                        actions.resolveProvider(item, file)
                    }
                }
                if availability.canUnresolveProvider {
                    inlineActionButton(id: "unresolve", title: "Unresolve") {
                        actions.unresolveProvider(item, file)
                    }
                }
            }
        }
    }

    private func inlineActionButton(id: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityIdentifier("diff-review-inline-feedback-\(id)-\(item.id)")
        .accessibilityLabel(title)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-action-\(id)-\(item.id)",
                label: title
            )
        )
        .background(
            ReviewDraftCommentActionPressMarker(
                identifier: "diff-review-inline-feedback-action-\(id)-\(item.id)",
                label: title,
                action: action
            )
        )
    }

    private var replyEditorBinding: Binding<DiffReviewInlineFeedbackReplyEditorState> {
        replyEditorState ?? $localReplyEditor
    }

    private var accessibilityLabel: String {
        [
            item.providerName,
            item.author,
            item.anchor.line.map { "line \($0)" },
            DiffReviewInlineFeedbackMarkdown.plainText(item.bodyPreview),
        ]
        .compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        .joined(separator: ", ")
    }

    private var statusColor: Color {
        switch item.status {
        case .actionable, .pending:
            theme.color("accent")
        case .failed:
            theme.color("del")
        case .passed, .resolved:
            theme.color("add")
        case .cancelled, .unknown:
            theme.color("fg-muted")
        }
    }
}

enum DiffReviewInlineFeedbackCardInteraction {
    static func select(
        _ item: DiffReviewInlineFeedback,
        onSelect: (DiffReviewInlineFeedback) -> Void
    ) {
        onSelect(item)
    }

    static func open(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback) -> Void
    ) {
        action(item)
    }

    static func copy(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback) -> Void
    ) {
        action(item)
    }

    static func send(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback) -> Void
    ) {
        action(item)
    }

    static func reply(
        _ item: DiffReviewInlineFeedback,
        body: String,
        action: (DiffReviewInlineFeedback, String) -> Void
    ) {
        action(item, body)
    }
}

struct DiffReviewInlineFeedbackReplyEditorState: Equatable {
    var isReplying = false
    var body = ""

    mutating func start() {
        body = ""
        isReplying = true
    }

    mutating func cancel() {
        body = ""
        isReplying = false
    }

    @discardableResult
    mutating func save(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback, String) -> Void
    ) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        DiffReviewInlineFeedbackCardInteraction.reply(item, body: trimmed, action: action)
        body = ""
        isReplying = false
        return true
    }
}

struct DiffReviewInlineFeedbackMoreRow: View {
    let hiddenCount: Int

    @Environment(\.theme) private var theme

    var body: some View {
        Text("+\(hiddenCount) more feedback")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(theme.color("fg-muted"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(
                DiffReviewAccessibilityMarker(
                    identifier: "diff-review-inline-feedback-more",
                    label: "+\(hiddenCount) more feedback"
                )
            )
    }
}

enum DiffReviewFileSectionActions {
    static func openFileButtonTitle(for file: DiffReviewFileSectionModel) -> String? {
        file.openFile == nil ? nil : "Open File"
    }
}
