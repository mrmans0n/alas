import AppKit
import SwiftUI

enum DiffReviewRailTooltip {
    static func text(for file: DiffReviewFileSummary) -> String {
        file.path
    }
}

/// Open-thread counts per path plus the rail-wide totals, derived in a single
/// pass. The rail evaluates on every review-surface body pass — including the
/// ones a scroll-spy file change triggers mid-fling — so counting per visible
/// row rescanned every thread each time.
struct DiffReviewRailThreadCounts: Equatable {
    private let openByPath: [String: Int]
    let openTotal: Int
    let resolvedTotal: Int

    init(threads: [ReviewThread]) {
        var openByPath: [String: Int] = [:]
        var openTotal = 0
        var resolvedTotal = 0
        for thread in threads {
            if thread.isResolved {
                resolvedTotal += 1
                continue
            }
            guard !thread.isOutdated else { continue }
            openTotal += 1
            if let path = thread.path {
                openByPath[path, default: 0] += 1
            }
        }
        self.openByPath = openByPath
        self.openTotal = openTotal
        self.resolvedTotal = resolvedTotal
    }

    func openCount(forPath path: String) -> Int {
        openByPath[path] ?? 0
    }
}

struct DiffReviewRail: View {
    let session: DiffReviewSessionModel
    @Binding var selectedFileID: DiffReviewFileID
    @Binding var collapsed: Bool
    var displayControls: DiffReviewDisplayControlBindings? = nil
    var threads: [ReviewThread] = []
    let onSelectFile: (DiffReviewFileID) -> Void

    @Environment(\.theme) private var theme
    @State private var filterQuery = ""

    init(
        session: DiffReviewSessionModel,
        selectedFileID: Binding<DiffReviewFileID>,
        collapsed: Binding<Bool>,
        displayControls: DiffReviewDisplayControlBindings? = nil,
        threads: [ReviewThread] = [],
        filterQuery: String = "",
        onSelectFile: @escaping (DiffReviewFileID) -> Void
    ) {
        self.session = session
        _selectedFileID = selectedFileID
        _collapsed = collapsed
        self.displayControls = displayControls
        self.threads = threads
        _filterQuery = State(initialValue: filterQuery)
        self.onSelectFile = onSelectFile
    }

    private var filteredSession: DiffReviewSessionModel {
        DiffReviewRailFilter.session(session, matching: filterQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            if collapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .frame(width: collapsed ? 44 : 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(width: 0.5), alignment: .trailing)
    }

    private var expandedBody: some View {
        let visibleSession = filteredSession
        let threadCounts = DiffReviewRailThreadCounts(threads: threads)
        return VStack(spacing: 0) {
            expandedHeader
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if DiffReviewRailFilter.isActive(filterQuery), visibleSession.files.isEmpty {
                            Text("No matching files")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.color("fg-faint"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(
                                    DiffReviewAccessibilityMarker(
                                        identifier: "diff-review-rail-filter-empty",
                                        label: "No matching files"
                                    )
                                )
                        } else {
                            ForEach(DiffReviewRailRows.rows(for: visibleSession)) { row in
                                expandedRow(row, threadCounts: threadCounts)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    proxy.scrollTo(selectedFileID.rawValue, anchor: .center)
                }
                .onChange(of: selectedFileID) { _, id in
                    withAnimation(.easeInOut(duration: 0.14)) {
                        proxy.scrollTo(id.rawValue, anchor: .center)
                    }
                }
            }
            if threadCounts.openTotal > 0 || threadCounts.resolvedTotal > 0 {
                threadSummaryStrip(threadCounts)
            }
        }
    }

    private func threadSummaryStrip(_ counts: DiffReviewRailThreadCounts) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bubble.left")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.color("fg-faint"))
            Text(Self.threadSummaryLabel(counts))
                .font(.caption)
                .foregroundColor(theme.color("fg-muted"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .top)
    }

    private static func threadSummaryLabel(_ counts: DiffReviewRailThreadCounts) -> String {
        switch (counts.openTotal, counts.resolvedTotal) {
        case (let o, 0):
            return "\(o) open"
        case (0, let r):
            return "\(r) resolved"
        case (let o, let r):
            return "\(o) open · \(r) resolved"
        }
    }

    private var collapsedBody: some View {
        let visibleFiles = filteredSession.files
        return VStack(spacing: 8) {
            collapseButton
                .padding(.top, 8)
            Divider()
                .overlay(theme.color("line"))
                .padding(.horizontal, 8)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleFiles) { file in
                            collapsedMarker(for: file)
                                .id(file.id.rawValue)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear {
                    proxy.scrollTo(selectedFileID.rawValue, anchor: .center)
                }
                .onChange(of: selectedFileID) { _, id in
                    withAnimation(.easeInOut(duration: 0.14)) {
                        proxy.scrollTo(id.rawValue, anchor: .center)
                    }
                }
            }
        }
    }

    private var expandedHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(session.fileCount) changed \(session.fileCount == 1 ? "file" : "files")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text("+\(session.totalAdditions)")
                            .foregroundColor(theme.color("add"))
                        Text("-\(session.totalDeletions)")
                            .foregroundColor(theme.color("del"))
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                Spacer(minLength: 8)
                collapseButton
            }

            if let displayControls {
                DiffReviewDisplayControls(bindings: displayControls)
            }

            DiffReviewRailFilterField(text: $filterQuery)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private var collapseButton: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: collapsed ? "sidebar.left" : "sidebar.leading")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 26, height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand file rail" : "Collapse file rail")
        .accessibilityIdentifier("diff-review-rail-collapse-toggle")
    }

    @ViewBuilder
    private func expandedRow(
        _ row: DiffReviewRailRow,
        threadCounts: DiffReviewRailThreadCounts
    ) -> some View {
        switch row.kind {
        case let .sourceHeader(id, title, fileCount):
            sourceHeader(id: id, title: title, fileCount: fileCount)
        case let .directory(name, depth):
            directoryRow(name: name, depth: depth)
        case let .file(file, depth, name):
            fileRow(file, depth: depth, name: name, threadCounts: threadCounts)
        case .divider:
            Divider()
                .overlay(theme.color("line"))
                .padding(.vertical, 6)
        }
    }

    private func sourceHeader(id: String, title: String, fileCount: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
            Text("\(fileCount)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.color("fg-faint"))
        }
        .padding(.horizontal, 5)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityIdentifier("diff-review-rail-source-\(id)")
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-rail-source-\(id)",
                label: title
            )
        )
    }

    private func directoryRow(name: String, depth: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.color("fg-faint"))
                .frame(width: 13)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * DiffReviewRailSelectedRowStyle.fileDepthIndent + 4)
        .frame(height: 22)
    }

    private func fileRow(
        _ file: DiffReviewFileSummary,
        depth: Int,
        name: String,
        threadCounts: DiffReviewRailThreadCounts
    ) -> some View {
        let selected = selectedFileID == file.id
        return Button {
            selectedFileID = file.id
            onSelectFile(file.id)
        } label: {
            HStack(spacing: 6) {
                FileTypeIconView(filename: name, size: 16)
                    .frame(width: 16, height: 16)
                    .background(
                        DiffReviewAccessibilityMarker(
                            identifier: "diff-review-rail-row-icon-\(file.id.rawValue)",
                            label: name
                        )
                    )
                ReviewDraftCommentActionPressMarker(
                    identifier: "diff-review-rail-row-\(file.id.rawValue)",
                    label: file.path
                ) {
                    selectedFileID = file.id
                    onSelectFile(file.id)
                }
                .frame(width: 1, height: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selected ? theme.color("fg") : theme.color("fg-muted"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let directory = file.directory {
                        Text(directory)
                            .font(.system(size: 10))
                            .foregroundColor(theme.color("fg-faint"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                let openCount = threadCounts.openCount(forPath: file.path)
                if openCount > 0 {
                    threadBadge(openCount)
                }
                changeSummary(file)
            }
            .padding(
                .leading,
                CGFloat(depth) * DiffReviewRailSelectedRowStyle.fileDepthIndent
                    + DiffReviewRailSelectedRowStyle.contentLeadingPadding
            )
            .padding(.trailing, 6)
            .frame(height: 34)
            .background(alignment: .leading) {
                if selected {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: DiffReviewRailSelectedRowStyle.cornerRadius)
                            .fill(theme.color(DiffReviewRailSelectedRowStyle.backgroundToken))
                        Rectangle()
                            .fill(theme.color("accent"))
                            .frame(
                                width: DiffReviewRailSelectedRowStyle.accentRailWidth,
                                height: DiffReviewRailSelectedRowStyle.accentRailHeight
                            )
                            .cornerRadius(DiffReviewRailSelectedRowStyle.accentRailCornerRadius)
                            .offset(x: DiffReviewRailSelectedRowStyle.accentRailXOffset)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .id(file.id.rawValue)
        .accessibilityIdentifier("diff-review-rail-row-\(file.id.rawValue)")
        .background(
            ZStack {
                DiffReviewAccessibilityMarker(
                    identifier: "diff-review-rail-row-\(file.id.rawValue)",
                    label: file.path
                )
                DiffReviewAccessibilityMarker(
                    identifier: "diff-review-rail-row-scroll-id-\(file.id.rawValue)",
                    label: file.id.rawValue
                )
                if selected {
                    DiffReviewAccessibilityMarker(
                        identifier: "diff-review-rail-row-selected-\(file.id.rawValue)",
                        label: file.path
                    )
                }
            }
        )
        .help(DiffReviewRailTooltip.text(for: file))
    }

    private func collapsedMarker(for file: DiffReviewFileSummary) -> some View {
        let selected = selectedFileID == file.id
        return Button {
            selectedFileID = file.id
            onSelectFile(file.id)
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? theme.color(DiffReviewRailSelectedRowStyle.backgroundToken) : theme.color("bg-3"))
                    .frame(width: 28, height: 26)
                Rectangle()
                    .fill(selected ? theme.color("accent") : Color.clear)
                    .frame(
                        width: DiffReviewRailSelectedRowStyle.accentRailWidth,
                        height: DiffReviewRailSelectedRowStyle.accentRailHeight
                    )
                    .cornerRadius(DiffReviewRailSelectedRowStyle.accentRailCornerRadius)
                    .offset(x: DiffReviewRailSelectedRowStyle.accentRailXOffset)
                Text(file.status.glyph)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(selected ? theme.color("fg") : statusColor(file.status))
                    .frame(width: 28, height: 26)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("diff-review-rail-marker-\(file.id.rawValue)")
        .background(
            ZStack {
                DiffReviewAccessibilityMarker(
                    identifier: "diff-review-rail-marker-\(file.id.rawValue)",
                    label: file.path
                )
                DiffReviewAccessibilityMarker(
                    identifier: "diff-review-rail-marker-scroll-id-\(file.id.rawValue)",
                    label: file.id.rawValue
                )
                if selected {
                    DiffReviewAccessibilityMarker(
                        identifier: "diff-review-rail-marker-selected-\(file.id.rawValue)",
                        label: file.path
                    )
                }
            }
        )
        .help(DiffReviewRailTooltip.text(for: file))
    }

    private func threadBadge(_ count: Int) -> some View {
        Label("\(count)", systemImage: "bubble.left")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(theme.color("fg-muted"))
            .labelStyle(ThreadBadgeLabelStyle())
    }

    private func changeSummary(_ file: DiffReviewFileSummary) -> some View {
        HStack(spacing: 5) {
            if file.additions > 0 {
                Text("+\(file.additions)")
                    .foregroundColor(theme.color("add"))
            }
            if file.deletions > 0 {
                Text("-\(file.deletions)")
                    .foregroundColor(theme.color("del"))
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    private func statusColor(_ status: DiffReviewFileStatus) -> Color {
        switch status {
        case .added:
            theme.color("add")
        case .deleted:
            theme.color("del")
        case .renamed, .copied:
            theme.color("accent")
        case .conflicted:
            theme.color("warn")
        case .modified, .unknown:
            theme.color("fg-dim")
        }
    }
}

private struct DiffReviewRailFilterField: View {
    @Binding var text: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-dim"))
                .accessibilityHidden(true)
            TextField("Filter files…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg"))
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("diff-review-rail-filter-field")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear file filter")
                .background(
                    DiffReviewAccessibilityMarker(
                        identifier: "diff-review-rail-filter-clear",
                        label: "Clear file filter"
                    )
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(theme.color("bg-1"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ThreadBadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

enum DiffReviewRailSelectedRowStyle {
    static let backgroundToken = "bg-4"
    static let accentRailWidth: CGFloat = 3
    static let accentRailHeight: CGFloat = 14
    static let accentRailCornerRadius: CGFloat = 2
    static let accentRailXOffset: CGFloat = 2
    static let cornerRadius: CGFloat = 6
    static let fileDepthIndent: CGFloat = 6
    static let contentLeadingPadding: CGFloat = 6
}

struct DiffReviewDisplayControlBindings {
    let layoutMode: Binding<DiffLayoutMode>
    let wrapLines: Binding<Bool>
    let showWhitespace: Binding<Bool>
}

struct DiffReviewDisplayControls: View {
    let bindings: DiffReviewDisplayControlBindings

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            layoutSwitcher
            controlButton(
                identifier: "diff-review-wrap-toggle",
                systemName: bindings.wrapLines.wrappedValue ? "text.justify.left" : "text.alignleft",
                tooltip: "Wrap lines",
                isActive: bindings.wrapLines.wrappedValue
            ) {
                bindings.wrapLines.wrappedValue.toggle()
            }
            controlButton(
                identifier: "diff-review-whitespace-toggle",
                systemName: "paragraphsign",
                tooltip: "Show whitespace",
                isActive: bindings.showWhitespace.wrappedValue
            ) {
                bindings.showWhitespace.wrappedValue.toggle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-display-controls",
                label: "Diff display controls"
            )
        )
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
        let active = bindings.layoutMode.wrappedValue == mode
        return Button {
            bindings.layoutMode.wrappedValue = mode
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(active ? theme.color("fg") : theme.color("fg-muted"))
                .frame(width: 28, height: 24)
                .background(active ? theme.color("bg-1") : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(mode.title)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-layout-\(mode.rawValue)",
                label: mode.title
            )
        )
    }

    private func controlButton(
        identifier: String,
        systemName: String,
        tooltip: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? theme.color("accent") : theme.color("fg-muted"))
                .frame(width: 26, height: 24)
                .background(isActive ? theme.color("accent-soft") : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: identifier,
                label: tooltip
            )
        )
    }
}

struct DiffReviewAccessibilityMarker: NSViewRepresentable {
    let identifier: String
    var label: String? = nil

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
    }
}
