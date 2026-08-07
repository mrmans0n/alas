import AppKit
import SwiftUI

struct DiffPaneHunkActions {
    var stage: (() -> Void)?
    var discard: (() -> Void)?
    var dropFromCommit: (() -> Void)?
}

enum DiffSelectionController {
    static func selection(
        current: DiffSelectionRange?,
        clicked anchor: DiffLineAnchor,
        extend: Bool
    ) -> DiffSelectionRange {
        guard extend, let current else {
            return DiffSelectionRange(first: anchor, last: anchor)
        }
        return DiffSelectionRange(first: current.first, last: anchor)
    }
}

enum DiffCollapsedContextController {
    static func collapsedRowIDs(in group: DiffDisplayGroup) -> Set<String> {
        Set(group.rows.filter { $0.kind == .collapsed }.map(\.id))
    }

    static func isExpanded(_ group: DiffDisplayGroup, expandedIDs: Set<String>) -> Bool {
        let ids = collapsedRowIDs(in: group)
        return !ids.isEmpty && ids.isSubset(of: expandedIDs)
    }

    static func toggled(_ group: DiffDisplayGroup, expandedIDs: Set<String>) -> Set<String> {
        let ids = collapsedRowIDs(in: group)
        guard !ids.isEmpty else { return expandedIDs }

        var updated = expandedIDs
        if ids.isSubset(of: expandedIDs) {
            updated.subtract(ids)
        } else {
            updated.formUnion(ids)
        }
        return updated
    }
}

enum DiffPaneRowProjection {
    static func visibleRowsSnapshot(
        in group: DiffDisplayGroup,
        expandedCollapsedRowIDs: Set<String>
    ) -> DiffDisplayRowsSnapshot {
        guard !expandedCollapsedRowIDs.isEmpty,
              group.rows.contains(where: { $0.kind == .collapsed && expandedCollapsedRowIDs.contains($0.id) })
        else {
            return DiffDisplayRowsSnapshot(rows: group.rows, signature: group.rowsSignature)
        }

        var rows: [DiffDisplayRow] = []
        rows.reserveCapacity(group.rows.count)
        for row in group.rows {
            rows.append(row)
            if row.kind == .collapsed, expandedCollapsedRowIDs.contains(row.id) {
                rows.append(contentsOf: row.collapsedRows)
            }
        }
        return DiffDisplayRowsSnapshot(rows: rows)
    }

    static func visibleRows(
        in group: DiffDisplayGroup,
        expandedCollapsedRowIDs: Set<String>
    ) -> [DiffDisplayRow] {
        visibleRowsSnapshot(
            in: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs
        ).rows
    }

    static func stackedLines(for rows: [DiffDisplayRow]) -> [(row: DiffDisplayRow, line: DiffDisplayLine)] {
        var output: [(row: DiffDisplayRow, line: DiffDisplayLine)] = []
        var index = 0

        while index < rows.count {
            let row = rows[index]
            guard isChanged(row) else {
                output.append(contentsOf: stackedLines(for: row).map { (row, $0) })
                index += 1
                continue
            }

            let start = index
            while index < rows.count, isChanged(rows[index]) {
                index += 1
            }
            let changedRows = Array(rows[start..<index])
            output.append(contentsOf: changedRows.compactMap { row in
                row.old.map { (row, $0) }
            })
            output.append(contentsOf: changedRows.compactMap { row in
                row.new.map { (row, $0) }
            })
        }

        return output
    }

    private static func isChanged(_ row: DiffDisplayRow) -> Bool {
        row.kind == .replacement || row.kind == .delete || row.kind == .add
    }

    static func stackedLines(for row: DiffDisplayRow) -> [DiffDisplayLine] {
        if row.kind == .context || row.kind == .expandedContext {
            if let new = row.new { return [new] }
            if let old = row.old { return [old] }
            return []
        }
        return [row.old, row.new].compactMap { $0 }
    }
}

enum DiffPaneVerticalScrollMode {
    case internalScroll
    case staticHeight
}

enum DiffPaneStaticHeightEstimator {
    private static let minimumHunkHeaderHeight: CGFloat = 38
    private static let hunkHeaderVerticalPadding: CGFloat = 16
    private static let textVerticalInset: CGFloat = 16
    private static let minimumHunkBodyHeight: CGFloat = 36
    private static let stackHorizontalPadding: CGFloat = 20
    private static let textHorizontalInset: CGFloat = 20
    private static let lineNumberGutterMinimumThickness: CGFloat = 42
    private static let lineNumberGutterHorizontalPadding: CGFloat = 8

    static func estimatedHeight(
        for model: DiffDisplayModel,
        layoutMode: DiffLayoutMode,
        expandedCollapsedRowIDs: Set<String>,
        codeFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        headerFont: NSFont? = nil,
        wrapLines: Bool = false,
        availableWidth: CGFloat? = nil,
        showWhitespace: Bool = false
    ) -> CGFloat {
        estimatedHeight(
            for: model,
            layoutMode: layoutMode,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs,
            codeFont: codeFont,
            headerFont: headerFont,
            wrapLines: wrapLines,
            availableWidth: availableWidth,
            showWhitespace: showWhitespace,
            fusionStates: nil,
        )
    }

    static func estimatedHeight(
        for model: DiffDisplayModel,
        layoutMode: DiffLayoutMode,
        expandedCollapsedRowIDs: Set<String>,
        codeFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        headerFont: NSFont? = nil,
        wrapLines: Bool = false,
        availableWidth: CGFloat? = nil,
        showWhitespace: Bool = false,
        fusionStates suppliedFusionStates: [DiffPaneHunkFusionState]?
    ) -> CGFloat {
        let fusionStates: [DiffPaneHunkFusionState]
        if let suppliedFusionStates, suppliedFusionStates.count == model.groups.count {
            fusionStates = suppliedFusionStates
        } else {
            fusionStates = DiffPaneHunkFusionResolver.states(for: model.groups)
        }
        let topPadding = fusionStates.first?.outerTopPadding ?? 10
        let bottomPadding = fusionStates.last?.outerBottomPadding ?? 10
        let codeLineHeight = lineHeight(for: codeFont, multiplier: CenterTypography.lineHeightMultiple)
        let hunkHeaderHeight = max(
            minimumHunkHeaderHeight,
            lineHeight(for: headerFont ?? codeFont, multiplier: 1) + hunkHeaderVerticalPadding
        )
        let contextControlRowHeight = DiffPaneTextDocumentBuilder.expandableContextRowHeight(font: codeFont)
        let hunkHeights = model.groups.enumerated().reduce(CGFloat(0)) { total, item in
            let (index, group) = item
            let fusion = index < fusionStates.count ? fusionStates[index] : .none
            let rowsHeight = cachedTextRowsHeight(
                group: group,
                expandedCollapsedRowIDs: expandedCollapsedRowIDs,
                layoutMode: layoutMode,
                codeLineHeight: codeLineHeight,
                contextControlRowHeight: contextControlRowHeight,
                wrapLines: wrapLines,
                availableWidth: availableWidth,
                codeFont: codeFont,
                showWhitespace: showWhitespace
            )

            return total
                + hunkHeaderHeight
                + max(minimumHunkBodyHeight, rowsHeight + textVerticalInset)
                + fusion.bottomPadding
        }

        return topPadding + hunkHeights + bottomPadding
    }

    /// Row-height estimation walks every row of a hunk, so a multi-file review
    /// re-walks thousands of rows each time a row plan is rebuilt — including
    /// rebuilds triggered by unrelated state such as the selected file
    /// changing mid-fling. The result is a pure function of the group's
    /// content and the presentation inputs below, so memoize it.
    private static func cachedTextRowsHeight(
        group: DiffDisplayGroup,
        expandedCollapsedRowIDs: Set<String>,
        layoutMode: DiffLayoutMode,
        codeLineHeight: CGFloat,
        contextControlRowHeight: CGFloat,
        wrapLines: Bool,
        availableWidth: CGFloat?,
        codeFont: NSFont,
        showWhitespace: Bool
    ) -> CGFloat {
        var hasher = Hasher()
        hasher.combine(group.contentHash)
        hasher.combine(layoutMode)
        hasher.combine(codeLineHeight)
        hasher.combine(contextControlRowHeight)
        hasher.combine(wrapLines)
        hasher.combine(availableWidth)
        hasher.combine(codeFont.fontName)
        hasher.combine(codeFont.pointSize)
        hasher.combine(showWhitespace)
        // Only expansions belonging to this group change its height.
        for row in group.rows where row.kind == .collapsed && expandedCollapsedRowIDs.contains(row.id) {
            hasher.combine(row.id)
        }
        let key = hasher.finalize()

        if let cached = rowsHeightCache.value(forKey: key) { return cached }

        let visibleRows = DiffPaneRowProjection.visibleRows(
            in: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs
        )
        let height = textRowsHeight(
            for: visibleRows,
            layoutMode: layoutMode,
            codeLineHeight: codeLineHeight,
            contextControlRowHeight: contextControlRowHeight,
            wrapLines: wrapLines,
            wrappingColumnWidth: wrappingColumnWidth(
                layoutMode: layoutMode,
                availableWidth: availableWidth,
                rows: visibleRows
            ),
            codeFont: codeFont,
            showWhitespace: showWhitespace
        )
        rowsHeightCache.setValue(height, forKey: key)
        return height
    }

    static let rowsHeightCache = HeightCache()

    /// Small lock-guarded memo. `estimatedHeight` is reachable from both the
    /// main actor and the background highlight prewarmer.
    final class HeightCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int: CGFloat] = [:]

        #if DEBUG
        private var hits = 0
        private var misses = 0

        /// Row walks avoided (`hits`) versus performed (`misses`).
        var statisticsForTests: (hits: Int, misses: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (hits, misses)
        }

        func resetStatisticsForTests() {
            lock.lock()
            defer { lock.unlock() }
            hits = 0
            misses = 0
        }
        #endif

        func value(forKey key: Int) -> CGFloat? {
            lock.lock()
            defer { lock.unlock() }
            let value = storage[key]
            #if DEBUG
            if value == nil { misses += 1 } else { hits += 1 }
            #endif
            return value
        }

        func setValue(_ value: CGFloat, forKey key: Int) {
            lock.lock()
            defer { lock.unlock() }
            if storage.count > 4096 { storage.removeAll(keepingCapacity: true) }
            storage[key] = value
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAll(keepingCapacity: true)
        }
    }

    private static func textRowsHeight(
        for rows: [DiffDisplayRow],
        layoutMode: DiffLayoutMode,
        codeLineHeight: CGFloat,
        contextControlRowHeight: CGFloat,
        wrapLines: Bool,
        wrappingColumnWidth: CGFloat?,
        codeFont: NSFont,
        showWhitespace: Bool
    ) -> CGFloat {
        let visibleRows = rows.isEmpty ? [nil] : rows.map(Optional.some)
        return visibleRows.reduce(CGFloat(0)) { total, row in
            let lineCount: Int
            switch (layoutMode, row) {
            case (_, let row?) where row.kind == .collapsed:
                lineCount = wrappedLineCount(
                    for: collapsedText(for: row),
                    wrapLines: wrapLines,
                    columnWidth: wrappingColumnWidth,
                    codeFont: codeFont,
                    showWhitespace: showWhitespace
                )
            case (_, let row?) where row.kind == .expandableContext:
                lineCount = 1
            case (.split, let row?):
                lineCount = max(
                    wrappedLineCount(for: row.old, wrapLines: wrapLines, columnWidth: wrappingColumnWidth, codeFont: codeFont, showWhitespace: showWhitespace),
                    wrappedLineCount(for: row.new, wrapLines: wrapLines, columnWidth: wrappingColumnWidth, codeFont: codeFont, showWhitespace: showWhitespace),
                    1
                )
            case (.split, nil):
                lineCount = 1
            case (.stacked, let row?):
                lineCount = max(DiffPaneRowProjection.stackedLines(for: row).reduce(0) { total, line in
                    total + wrappedLineCount(for: line, wrapLines: wrapLines, columnWidth: wrappingColumnWidth, codeFont: codeFont, showWhitespace: showWhitespace)
                }, 1)
            case (.stacked, nil):
                lineCount = 1
            }
            return total + CGFloat(lineCount) * rowHeight(
                for: row,
                codeLineHeight: codeLineHeight,
                contextControlRowHeight: contextControlRowHeight
            )
        }
    }

    private static func rowHeight(
        for row: DiffDisplayRow?,
        codeLineHeight: CGFloat,
        contextControlRowHeight: CGFloat
    ) -> CGFloat {
        guard let row else { return codeLineHeight }
        switch row.kind {
        case .collapsed, .expandableContext:
            return contextControlRowHeight
        case .context, .expandedContext, .add, .delete, .replacement:
            return codeLineHeight
        }
    }

    private static func wrappingColumnWidth(
        layoutMode: DiffLayoutMode,
        availableWidth: CGFloat?,
        rows: [DiffDisplayRow]
    ) -> CGFloat? {
        guard let availableWidth, availableWidth > 1 else { return nil }

        let textPaneWidth = max(availableWidth - stackHorizontalPadding, 1)
        let paneWidth: CGFloat
        switch layoutMode {
        case .split:
            paneWidth = DiffPaneSplitGeometry.frames(containerWidth: textPaneWidth).oldPane.width
        case .stacked:
            paneWidth = textPaneWidth
        }
        return max(paneWidth - lineNumberGutterThickness(rows: rows) - textHorizontalInset, 1)
    }

    private static func wrappedLineCount(
        for line: DiffDisplayLine?,
        wrapLines: Bool,
        columnWidth: CGFloat?,
        codeFont: NSFont,
        showWhitespace: Bool
    ) -> Int {
        guard let line else { return 1 }
        return wrappedLineCount(
            for: line.text,
            wrapLines: wrapLines,
            columnWidth: columnWidth,
            codeFont: codeFont,
            showWhitespace: showWhitespace
        )
    }

    private static func wrappedLineCount(
        for text: String,
        wrapLines: Bool,
        columnWidth: CGFloat?,
        codeFont: NSFont,
        showWhitespace: Bool
    ) -> Int {
        guard wrapLines, let columnWidth else { return 1 }
        let characterWidth = max(ceil(("8" as NSString).size(withAttributes: [.font: codeFont]).width), 1)
        let estimatedWidth = CGFloat(estimatedRenderedColumnUnits(in: text, showWhitespace: showWhitespace)) * characterWidth
        return max(Int(ceil(estimatedWidth / columnWidth)), 1)
    }

    private static func estimatedRenderedColumnUnits(in text: String, showWhitespace: Bool) -> Int {
        text.reduce(0) { total, character in
            if character == "\t" {
                return total + (showWhitespace ? 1 : 4)
            }
            return total + 1
        }
    }

    private static func collapsedText(for row: DiffDisplayRow) -> String {
        "... \(row.collapsedLineCount) unchanged lines"
    }

    private static func lineNumberGutterThickness(rows: [DiffDisplayRow]) -> CGFloat {
        let maxDigits = rows
            .flatMap { [$0.old?.lineNumber, $0.new?.lineNumber] }
            .compactMap { $0.map(String.init) }
            .map(\.count)
            .max() ?? 1
        let sample = String(repeating: "8", count: max(maxDigits, 1)) as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let width = ceil(sample.size(withAttributes: [.font: font]).width)
        return max(lineNumberGutterMinimumThickness, width + lineNumberGutterHorizontalPadding * 2)
    }

    private static func lineHeight(for font: NSFont, multiplier: CGFloat) -> CGFloat {
        ceil((font.ascender + abs(font.descender) + font.leading) * multiplier)
    }
}

private struct DiffPaneStaticWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct DiffPaneHunkFusionState: Equatable {
    static let none = DiffPaneHunkFusionState(fusedWithPrevious: false, fusedWithNext: false)

    let fusedWithPrevious: Bool
    let fusedWithNext: Bool

    var bottomPadding: CGFloat {
        fusedWithNext ? 0 : 10
    }

    var outerTopPadding: CGFloat {
        fusedWithPrevious ? 0 : 10
    }

    var outerBottomPadding: CGFloat {
        fusedWithNext ? 0 : 10
    }
}

enum DiffPaneHunkFusionResolver {
    static func states(for groups: [DiffDisplayGroup]) -> [DiffPaneHunkFusionState] {
        guard !groups.isEmpty else { return [] }
        var states = Array(repeating: DiffPaneHunkFusionState.none, count: groups.count)
        guard groups.count > 1 else { return states }

        for index in groups.indices.dropLast() {
            guard
                let endingKey = sharedBridgeKeyEnding(groups[index]),
                let startingKey = sharedBridgeKeyStarting(groups[index + 1]),
                endingKey == startingKey
            else {
                continue
            }
            states[index] = DiffPaneHunkFusionState(
                fusedWithPrevious: states[index].fusedWithPrevious,
                fusedWithNext: true
            )
            states[index + 1] = DiffPaneHunkFusionState(
                fusedWithPrevious: true,
                fusedWithNext: states[index + 1].fusedWithNext
            )
        }
        return states
    }

    private static func sharedBridgeKeyEnding(_ group: DiffDisplayGroup) -> DiffContextExpansionKey? {
        group.sharedContextAfter
    }

    private static func sharedBridgeKeyStarting(_ group: DiffDisplayGroup) -> DiffContextExpansionKey? {
        group.sharedContextBefore
    }
}

struct DiffPaneHunkCardShape: Shape {
    let fusion: DiffPaneHunkFusionState

    func path(in rect: CGRect) -> Path {
        let topRadius: CGFloat = fusion.fusedWithPrevious ? 0 : 7
        let bottomRadius: CGFloat = fusion.fusedWithNext ? 0 : 7
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: topRadius,
                bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius,
                topTrailing: topRadius
            ),
            style: .continuous
        )
        .path(in: rect)
    }
}

struct DiffPaneView: View {
    let model: DiffDisplayModel
    let fileExtension: String
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    var showsToolbar: Bool = true
    var verticalScrollMode: DiffPaneVerticalScrollMode = .internalScroll
    var lspContext: DiffPaneLSPContext? = nil
    var activeCommentHighlight: DiffReviewCommentHighlight? = nil
    var allowsReviewLineSelection: Bool = true
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    var onContextExpansion: DiffContextExpansionHandler = { _, _, _ in }
    var threads: [DiffInlineCommentThread] = []
    var annotations: [DiffInlineAnnotation] = []
    var onReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }
    var onResolve: (DiffInlineCommentThread) -> Void = { _ in }
    var onUnresolve: (DiffInlineCommentThread) -> Void = { _ in }
    var onEdit: (DiffInlineCommentThread, DiffInlineComment, String) -> Void = { _, _, _ in }
    var onDelete: (DiffInlineCommentThread, DiffInlineComment) -> Void = { _, _ in }
    var canReply: Bool = false
    var canResolve: Bool = false
    var onStageReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }
    var canAddToReview: Bool = false
    var hunkFusionStates: [DiffPaneHunkFusionState]? = nil
    let hunkActions: (ParsedDiff.Hunk) -> DiffPaneHunkActions

    @Environment(\.theme) private var theme
    @State private var presentationState = DiffPanePresentationState()
    @State private var staticRowsWidth: CGFloat = 0
    @State private var appKitScrollerEnabled = AppKitDiffScrollerFlag.isEnabled
    @State private var activeThreadReplanGeneration = 0

    init(
        model: DiffDisplayModel,
        fileExtension: String,
        layoutMode: Binding<DiffLayoutMode>,
        wrapLines: Binding<Bool>,
        showWhitespace: Binding<Bool>,
        codeFontFamily: String,
        codeFontSize: CGFloat,
        showsToolbar: Bool = true,
        verticalScrollMode: DiffPaneVerticalScrollMode = .internalScroll,
        lspContext: DiffPaneLSPContext? = nil,
        activeCommentHighlight: DiffReviewCommentHighlight? = nil,
        allowsReviewLineSelection: Bool = true,
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in },
        onContextExpansion: @escaping DiffContextExpansionHandler = { _, _, _ in },
        threads: [DiffInlineCommentThread] = [],
        annotations: [DiffInlineAnnotation] = [],
        onReply: @escaping (DiffInlineCommentThread, String) -> Void = { _, _ in },
        onResolve: @escaping (DiffInlineCommentThread) -> Void = { _ in },
        onUnresolve: @escaping (DiffInlineCommentThread) -> Void = { _ in },
        onEdit: @escaping (DiffInlineCommentThread, DiffInlineComment, String) -> Void = { _, _, _ in },
        onDelete: @escaping (DiffInlineCommentThread, DiffInlineComment) -> Void = { _, _ in },
        canReply: Bool = false,
        canResolve: Bool = false,
        onStageReply: @escaping (DiffInlineCommentThread, String) -> Void = { _, _ in },
        canAddToReview: Bool = false,
        hunkFusionStates: [DiffPaneHunkFusionState]? = nil,
        hunkActions: @escaping (ParsedDiff.Hunk) -> DiffPaneHunkActions
    ) {
        self.model = model
        self.fileExtension = fileExtension
        self._layoutMode = layoutMode
        self._wrapLines = wrapLines
        self._showWhitespace = showWhitespace
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = codeFontSize
        self.showsToolbar = showsToolbar
        self.verticalScrollMode = verticalScrollMode
        self.lspContext = lspContext
        self.activeCommentHighlight = activeCommentHighlight
        self.allowsReviewLineSelection = allowsReviewLineSelection
        self.onReviewLineSelected = onReviewLineSelected
        self.onContextExpansion = onContextExpansion
        self.threads = threads
        self.annotations = annotations
        self.onReply = onReply
        self.onResolve = onResolve
        self.onUnresolve = onUnresolve
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.canReply = canReply
        self.canResolve = canResolve
        self.onStageReply = onStageReply
        self.canAddToReview = canAddToReview
        self.hunkFusionStates = hunkFusionStates
        self.hunkActions = hunkActions
    }

    var body: some View {
        Group {
            VStack(spacing: 0) {
                if showsToolbar {
                    toolbar
                }
                diffBody
                    .id(appKitScrollerEnabled)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: verticalScrollMode == .internalScroll ? .infinity : nil,
                alignment: .topLeading
            )
            .background(theme.color("bg-1"))
        }
        .onReceive(
            NotificationCenter.default.publisher(for: AppKitDiffScrollerFlag.overrideDidChangeNotification)
        ) { _ in
            let flagEnabled = AppKitDiffScrollerFlag.isEnabled
            guard flagEnabled != appKitScrollerEnabled else { return }
            presentationState = DiffPanePresentationState()
            appKitScrollerEnabled = flagEnabled
        }
        .onReceive(presentationState.$activeThreadID) { _ in
            activeThreadReplanGeneration &+= 1
        }
    }

    nonisolated static func usesAppKitScroller(
        flagEnabled: Bool,
        verticalScrollMode: DiffPaneVerticalScrollMode
    ) -> Bool {
        guard flagEnabled else { return false }
        if case .internalScroll = verticalScrollMode {
            return true
        }
        return false
    }

    @ViewBuilder
    private var diffBody: some View {
        let _ = activeThreadReplanGeneration
        let input = synchronizedRowPlanInput()
        if Self.usesAppKitScroller(
            flagEnabled: appKitScrollerEnabled,
            verticalScrollMode: verticalScrollMode
        ) {
            let fusionStates = resolvedHunkFusionStates
            let plan = DiffPaneRowPlanBuilder.build(input: input, state: presentationState)
                .withContentInsets(.init(
                    top: outerTopPadding(for: fusionStates),
                    bottom: outerBottomPadding(for: fusionStates),
                    left: 10,
                    right: 10
                ))
            AppKitDiffScroller(
                plan: plan,
                scrollRequest: nil,
                onActiveOwnerChange: { _ in },
                onScrollRequestCompletion: { _ in }
            )
        } else if verticalScrollMode == .internalScroll {
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    lazyRowsStack
                        .frame(minWidth: proxy.size.width, alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
            }
        } else {
            staticRowsStack
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: DiffPaneStaticWidthPreferenceKey.self,
                            value: proxy.size.width
                        )
                    }
                )
                .onPreferenceChange(DiffPaneStaticWidthPreferenceKey.self) { width in
                    if abs(staticRowsWidth - width) > 0.5 {
                        staticRowsWidth = width
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    idealHeight: staticRowsEstimatedHeight,
                    alignment: .topLeading
                )
        }
    }

    private func synchronizedRowPlanInput() -> DiffPaneRowPlanInput {
        let input = rowPlanInput
        presentationState.actionRelay.update(from: input)
        return input
    }

    private var staticRowsEstimatedHeight: CGFloat {
        DiffPaneStaticHeightEstimator.estimatedHeight(
            for: model,
            layoutMode: layoutMode,
            expandedCollapsedRowIDs: presentationState.expandedCollapsedRowIDs,
            codeFont: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            headerFont: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize - 1),
            wrapLines: wrapLines,
            availableWidth: staticRowsWidth > 1 ? staticRowsWidth : nil,
            showWhitespace: showWhitespace,
            fusionStates: resolvedHunkFusionStates,
        )
    }

    private var lazyRowsStack: some View {
        let indexedGroups = Array(model.groups.enumerated())
        let fusionStates = resolvedHunkFusionStates
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(indexedGroups, id: \.element.id) { index, group in
                hunk(group, fusion: fusionStates[index], input: synchronizedRowPlanInput())
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, outerTopPadding(for: fusionStates))
        .padding(.bottom, outerBottomPadding(for: fusionStates))
    }

    private var staticRowsStack: some View {
        let indexedGroups = Array(model.groups.enumerated())
        let fusionStates = resolvedHunkFusionStates
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(indexedGroups, id: \.element.id) { index, group in
                hunk(group, fusion: fusionStates[index], input: synchronizedRowPlanInput())
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, outerTopPadding(for: fusionStates))
        .padding(.bottom, outerBottomPadding(for: fusionStates))
    }

    private var resolvedHunkFusionStates: [DiffPaneHunkFusionState] {
        if let hunkFusionStates, hunkFusionStates.count == model.groups.count {
            return hunkFusionStates
        }
        return DiffPaneHunkFusionResolver.states(for: model.groups)
    }

    private func outerTopPadding(for fusionStates: [DiffPaneHunkFusionState]) -> CGFloat {
        fusionStates.first?.outerTopPadding ?? 10
    }

    private func outerBottomPadding(for fusionStates: [DiffPaneHunkFusionState]) -> CGFloat {
        fusionStates.last?.outerBottomPadding ?? 10
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            layoutSwitcher
            Spacer()
            toolbarButton(
                systemName: wrapLines ? "text.justify.left" : "text.alignleft",
                tooltip: "Wrap lines",
                isActive: wrapLines
            ) {
                wrapLines.toggle()
            }
            toolbarButton(
                systemName: "paragraphsign",
                tooltip: "Show whitespace",
                isActive: showWhitespace
            ) {
                showWhitespace.toggle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .accessibilityIdentifier("diff-pane-toolbar")
        .background(DiffPaneToolbarMarker())
        .background(theme.color("bg-1"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private var layoutSwitcher: some View {
        HStack(spacing: 0) {
            layoutButton(.split, systemName: "rectangle.split.2x1")
            layoutButton(.stacked, systemName: "rectangle.split.1x2")
        }
        .padding(3)
        .background(theme.color("bg-3"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
    }

    private func layoutButton(_ mode: DiffLayoutMode, systemName: String) -> some View {
        let active = layoutMode == mode
        return Button {
            layoutMode = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(active ? theme.color("fg") : theme.color("fg-muted"))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(active ? theme.color("bg-1") : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(mode.title)
    }

    private func toolbarButton(
        systemName: String,
        tooltip: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? theme.color("accent") : theme.color("fg-muted"))
                .frame(width: 24, height: 22)
                .background(isActive ? theme.color("accent-soft") : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func hunk(
        _ group: DiffDisplayGroup,
        fusion: DiffPaneHunkFusionState,
        input: DiffPaneRowPlanInput
    ) -> some View {
        DiffPaneHunkRow(
            group: group,
            fusion: fusion,
            input: input,
            state: presentationState
        )
    }

    private var rowPlanInput: DiffPaneRowPlanInput {
        DiffPaneRowPlanInput(
            model: model,
            fileExtension: fileExtension,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            codeFontFamily: codeFontFamily,
            codeFontSize: codeFontSize,
            theme: theme,
            lspContext: lspContext,
            activeCommentHighlight: activeCommentHighlight,
            allowsReviewLineSelection: allowsReviewLineSelection,
            onReviewLineSelected: onReviewLineSelected,
            onContextExpansion: onContextExpansion,
            threads: threads,
            annotations: annotations,
            onReply: onReply,
            onResolve: onResolve,
            onUnresolve: onUnresolve,
            onEdit: onEdit,
            onDelete: onDelete,
            canReply: canReply,
            canResolve: canResolve,
            onStageReply: onStageReply,
            canAddToReview: canAddToReview,
            hunkFusionStates: hunkFusionStates,
            hunkActions: hunkActions
        )
    }
}

enum DiffPaneActiveHighlightResolver {
    static func activeHighlight(
        parentHighlight: DiffReviewCommentHighlight?,
        threads: [DiffInlineCommentThread],
        activeThreadID: String?,
        rows: [DiffDisplayRow]
    ) -> DiffReviewCommentHighlight? {
        if let threadHighlight = activeThreadHighlight(
            threads: threads,
            activeThreadID: activeThreadID,
            rows: rows
        ) {
            return threadHighlight
        }

        if let parentHighlight,
           rowsContainHighlight(parentHighlight, rows: rows) {
            return parentHighlight
        }

        return nil
    }

    private static func activeThreadHighlight(
        threads: [DiffInlineCommentThread],
        activeThreadID: String?,
        rows: [DiffDisplayRow]
    ) -> DiffReviewCommentHighlight? {
        guard let activeThread = threads.first(where: { $0.id == activeThreadID }),
              rows.contains(where: { row in
                  activeThread.isOldSide
                      ? activeThread.lineRange.contains(row.old?.anchor.oldLine ?? -1)
                      : activeThread.lineRange.contains(row.new?.anchor.newLine ?? -1)
              })
        else { return nil }

        return DiffReviewCommentHighlight(
            path: activeThread.filePath,
            side: activeThread.isOldSide ? .old : .new,
            lineRange: activeThread.lineRange
        )
    }

    private static func rowsContainHighlight(_ highlight: DiffReviewCommentHighlight, rows: [DiffDisplayRow]) -> Bool {
        rows.contains { row in
            rowContainsHighlight(highlight, row: row)
        }
    }

    private static func rowContainsHighlight(_ highlight: DiffReviewCommentHighlight, row: DiffDisplayRow) -> Bool {
        highlight.matchesVisibleSourceLine(row.old) || highlight.matchesVisibleSourceLine(row.new)
    }
}

private struct DiffPaneToolbarMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier("diff-pane-toolbar")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
