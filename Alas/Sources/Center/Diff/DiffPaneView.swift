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

    static func stackedLines(for row: DiffDisplayRow) -> [DiffDisplayLine] {
        if row.kind == .context {
            if let new = row.new { return [new] }
            if let old = row.old { return [old] }
            return []
        }
        return [row.old, row.new].compactMap { $0 }
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
    let hunkActions: (ParsedDiff.Hunk) -> DiffPaneHunkActions

    @Environment(\.theme) private var theme
    @State private var selection: DiffSelectionRange?
    @State private var draftAnchor: DiffLineAnchor?
    @State private var expandedCollapsedRowIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            diffBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
    }

    private var diffBody: some View {
        GeometryReader { proxy in
            ScrollView(scrollAxes) {
                rowsStack
                    .frame(minWidth: proxy.size.width, alignment: .topLeading)
                    .fixedSize(horizontal: !wrapLines, vertical: false)
            }
            .defaultScrollAnchor(.topLeading)
        }
    }

    private var scrollAxes: Axis.Set {
        wrapLines ? [.vertical] : [.vertical, .horizontal]
    }

    private var rowsStack: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.groups) { group in
                hunk(group)
            }
        }
        .padding(.vertical, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Seg(
                value: $layoutMode,
                options: DiffLayoutMode.allCases.map { ($0, $0.title) }
            )
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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
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
            ForEach(DiffPaneRowProjection.visibleRows(
                in: group,
                expandedCollapsedRowIDs: expandedCollapsedRowIDs
            )) { row in
                switch row.kind {
                case .collapsed:
                    collapsedRow(row)
                case .context, .add, .delete, .replacement:
                    switch layoutMode {
                    case .split:
                        splitRow(row)
                    case .stacked:
                        stackedRow(row)
                    }
                }
            }
        }
    }

    private func hunkHeader(_ group: DiffDisplayGroup) -> some View {
        let actions = hunkActions(group.sourceHunk)
        return HStack(spacing: 8) {
            Text(group.header)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
            Spacer(minLength: 12)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
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

    private func splitRow(_ row: DiffDisplayRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            splitCell(line: row.old, rowKind: row.kind, side: .old)
            Rectangle()
                .fill(theme.color("line"))
                .frame(width: 0.5)
            splitCell(line: row.new, rowKind: row.kind, side: .new)
        }
    }

    private func splitCell(
        line: DiffDisplayLine?,
        rowKind: DiffDisplayRow.Kind,
        side: DiffLineSide
    ) -> some View {
        Group {
            if let line {
                lineCell(line, side: side)
            } else {
                emptyCell(rowKind: rowKind, side: side)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func stackedRow(_ row: DiffDisplayRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(DiffPaneRowProjection.stackedLines(for: row)) { line in
                lineCell(line, side: line.anchor.side)
            }
        }
    }

    private func lineCell(_ line: DiffDisplayLine, side: DiffLineSide) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.lineNumber.map(String.init) ?? "")
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1))
                .foregroundColor(theme.color("fg-faint"))
                .frame(width: 44, alignment: .trailing)
                .textSelection(.disabled)
            DiffCodeText(
                text: line.text,
                fileExtension: fileExtension,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                wrapLines: wrapLines,
                showWhitespace: showWhitespace,
                inlineSpans: line.inlineSpans,
                inlineTone: inlineTone(for: line.kind)
            )
            if draftAnchor == line.anchor {
                Text("Draft note")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("accent"))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.color("accent-soft"))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .textSelection(.disabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, CenterTypography.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(lineBackground(for: line, side: side))
        .overlay(selectionOverlay(for: line.anchor))
        .contentShape(Rectangle())
        .onTapGesture {
            selection = DiffSelectionController.selection(
                current: selection,
                clicked: line.anchor,
                extend: NSEvent.modifierFlags.contains(.shift)
            )
        }
        .contextMenu {
            Button("Add Note") {
                draftAnchor = line.anchor
            }
            Button("Copy Line") {
                Clipboard.copy(line.text)
            }
        }
    }

    private func emptyCell(rowKind: DiffDisplayRow.Kind, side: DiffLineSide) -> some View {
        HStack(spacing: 8) {
            Text("")
                .frame(width: 44)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, CenterTypography.rowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: codeFontSize * 1.25, alignment: .topLeading)
        .background(emptyBackground(for: rowKind, side: side))
    }

    private func collapsedRow(_ row: DiffDisplayRow) -> some View {
        let isExpanded = expandedCollapsedRowIDs.contains(row.id)
        return Button {
            if isExpanded {
                expandedCollapsedRowIDs.remove(row.id)
            } else {
                expandedCollapsedRowIDs.insert(row.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(row.collapsedLineCount) unchanged lines")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
            }
            .foregroundColor(theme.color("fg-dim"))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
            .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func selectionOverlay(for anchor: DiffLineAnchor) -> some View {
        if selection?.contains(anchor) == true {
            Rectangle()
                .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
        }
    }

    private func lineBackground(for line: DiffDisplayLine, side: DiffLineSide) -> Color {
        let base: Color
        switch line.kind {
        case .add:
            base = theme.color("add").opacity(0.14)
        case .delete:
            base = theme.color("del").opacity(0.14)
        case .context:
            base = theme.color("bg-1")
        }

        if selection?.contains(line.anchor) == true {
            return theme.color("accent-soft")
        }
        return base
    }

    private func emptyBackground(for rowKind: DiffDisplayRow.Kind, side: DiffLineSide) -> Color {
        switch (rowKind, side) {
        case (.add, .old), (.replacement, .old):
            return theme.color("bg-2").opacity(0.55)
        case (.delete, .new), (.replacement, .new):
            return theme.color("bg-2").opacity(0.55)
        default:
            return theme.color("bg-1")
        }
    }

    private func inlineTone(for kind: ParsedDiff.Hunk.Line.Kind) -> DiffInlineTone {
        switch kind {
        case .add:
            return .add
        case .delete:
            return .del
        case .context:
            return .accent
        }
    }
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
