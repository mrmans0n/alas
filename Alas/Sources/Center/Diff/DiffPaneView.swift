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
    static func visibleRows(
        in group: DiffDisplayGroup,
        expandedCollapsedRowIDs: Set<String>
    ) -> [DiffDisplayRow] {
        group.rows.flatMap { row in
            guard row.kind == .collapsed, expandedCollapsedRowIDs.contains(row.id) else {
                return [row]
            }
            return [row] + row.collapsedRows
        }
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
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    let hunkActions: (ParsedDiff.Hunk) -> DiffPaneHunkActions

    @Environment(\.theme) private var theme
    @State private var expandedCollapsedRowIDs: Set<String> = []

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
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in },
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
        self.onReviewLineSelected = onReviewLineSelected
        self.hunkActions = hunkActions
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsToolbar {
                toolbar
            }
            diffBody
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: verticalScrollMode == .internalScroll ? .infinity : nil,
            alignment: .topLeading
        )
        .background(theme.color("bg-1"))
    }

    @ViewBuilder
    private var diffBody: some View {
        if verticalScrollMode == .internalScroll {
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    rowsStack
                        .frame(minWidth: proxy.size.width, alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
            }
        } else {
            rowsStack
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var rowsStack: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.groups) { group in
                hunk(group)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
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

    private func hunk(_ group: DiffDisplayGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hunkHeader(group)
            DiffPaneTextDocumentView(
                group: group,
                expandedCollapsedRowIDs: expandedCollapsedRowIDs,
                layoutMode: layoutMode,
                wrapLines: wrapLines,
                showWhitespace: showWhitespace,
                fileExtension: fileExtension,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                theme: theme,
                lspContext: lspContext,
                onReviewLineSelected: onReviewLineSelected
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
        .padding(.bottom, 10)
    }

    private func hunkHeader(_ group: DiffDisplayGroup) -> some View {
        let actions = hunkActions(group.sourceHunk)
        return HStack(spacing: 8) {
            Text(group.header)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
            Spacer(minLength: 12)
            if !DiffCollapsedContextController.collapsedRowIDs(in: group).isEmpty {
                let expanded = DiffCollapsedContextController.isExpanded(group, expandedIDs: expandedCollapsedRowIDs)
                hunkActionButton(
                    systemName: expanded ? "minus.square" : "plus.square",
                    tooltip: expanded ? "Collapse context" : "Expand context"
                ) {
                    expandedCollapsedRowIDs = DiffCollapsedContextController.toggled(
                        group,
                        expandedIDs: expandedCollapsedRowIDs
                    )
                }
            }
            if let stage = actions.stage {
                hunkActionButton(systemName: "plus.square", tooltip: "Stage hunk", action: stage)
            }
            if let discard = actions.discard {
                hunkActionButton(systemName: "trash", tooltip: "Discard hunk", action: discard)
            }
            if let dropFromCommit = actions.dropFromCommit {
                hunkActionButton(systemName: "minus.circle", tooltip: "Drop from commit", action: dropFromCommit)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private func hunkActionButton(
        systemName: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        DiffPaneActionButton(systemName: systemName, tooltip: tooltip, action: action)
            .frame(width: 22, height: 20)
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

private struct DiffPaneActionButton: NSViewRepresentable {
    let systemName: String
    let tooltip: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: image(),
            target: context.coordinator,
            action: #selector(Coordinator.fire)
        )
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = image()
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
    }

    private func image() -> NSImage {
        NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip) ?? NSImage()
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func fire() {
            action()
        }
    }
}
