import AppKit
import SwiftUI

struct ReviewTargetDialog: View {
    @Bindable var appState: AppState
    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool
    /// See RepoSelectorDialog: ignore hovers caused by rows scrolling under
    /// a stationary cursor, so keyboard navigation doesn't fight hover.
    @State private var lastHoverLocation: CGPoint?

    private var model: ReviewTargetPaletteModel { appState.reviewPalette }

    var body: some View {
        if appState.isReviewPaletteOpen {
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { appState.closeReviewPaletteOverlay() }

                VStack(spacing: 0) {
                    inputRow
                    if let launchError = model.launchError {
                        errorBanner(launchError)
                    }
                    rowList
                    footer
                }
                .frame(width: 720)
                .background(theme.color("bg-1").opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
                .padding(.top, 70)
                .frame(maxHeight: .infinity, alignment: .top)
                .onTapGesture { /* swallow */ }
                .onKeyPress { press in handleKey(press) }
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
            .onAppear { requestInputFocus() }
            .onChange(of: appState.isReviewPaletteOpen) { _, isOpen in
                if isOpen { requestInputFocus() }
            }
            .task(id: taskKey) {
                switch model.level {
                case .worktrees:
                    await model.loadWorktreeMetrics(environment: environment)
                case .targets:
                    await model.loadTargets(environment: environment)
                }
            }
            .task(id: validationTaskKey) {
                guard case .targets = model.level else { return }
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                await model.validateRevisionQuery(environment: environment)
            }
        }
    }

    private var environment: ReviewTargetPaletteEnvironment {
        appState.reviewTargetPaletteEnvironment()
    }

    /// Reload data when the level changes (drill in / back).
    private var taskKey: String {
        switch model.level {
        case .worktrees: return "worktrees"
        case .targets(let worktree): return "targets:\(worktree.id)"
        }
    }

    private var validationTaskKey: String {
        switch model.level {
        case .worktrees:
            return "revision-validation:worktrees"
        case .targets(let worktree):
            return "revision-validation:\(worktree.id):\(model.query)"
        }
    }

    // MARK: - Subviews

    private var inputRow: some View {
        HStack(spacing: 10) {
            if case .targets(let worktree) = model.level {
                if model.canGoBack {
                    Button {
                        _ = model.back()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.color("fg-muted"))
                    }
                    .buttonStyle(.plain)
                    .help("Back to worktrees")
                }
                Text(worktree.branch)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Divider().frame(height: 14)
            } else {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(theme.color("fg-dim"))
            }
            TextField(placeholder, text: Bindable(model).query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 15))
                .foregroundColor(theme.color("fg"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var placeholder: String {
        switch model.level {
        case .worktrees: return "Review worktree…"
        case .targets: return "Filter commits and branches…"
        }
    }

    @ViewBuilder
    private var rowList: some View {
        switch model.level {
        case .worktrees:
            worktreeList
        case .targets:
            targetList
        }
    }

    private var worktreeList: some View {
        let entries = model.worktreeEntries(environment: environment)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        messageRow("No worktrees in this project")
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        worktreeRow(entry, isSelected: index == model.selectedIndex)
                            // Data-based id, not the row position: a positional
                            // id freezes LazyVStack rows against filtering.
                            .id(entry.id)
                            .onTapGesture {
                                model.setSelectedIndex(index, selectable: entries.map { _ in true })
                                Task { await model.activateSelection(environment: environment) }
                            }
                            .onHover { hovering in
                                guard hovering else { return }
                                let current = NSEvent.mouseLocation
                                if lastHoverLocation == current { return }
                                lastHoverLocation = current
                                model.setSelectedIndex(index, selectable: entries.map { _ in true })
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 200, maxHeight: 420)
            .onChange(of: model.scrollToSelectionTick) { _, _ in
                if entries.indices.contains(model.selectedIndex) {
                    proxy.scrollTo(entries[model.selectedIndex].id)
                }
            }
        }
    }

    private func worktreeRow(_ entry: ReviewTargetPaletteModel.WorktreeEntry, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.worktree.branch)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                    if entry.isCurrent {
                        Text("current")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.color("fg-dim"))
                    }
                }
                Text(entry.worktree.path.path)
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let ahead = entry.aheadCount {
                Text(ahead == 0 ? "up to date" : "\(ahead) ahead")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ahead == 0 ? theme.color("fg-dim") : theme.color("accent"))
            }
            if entry.worktree.status == .dirty {
                Circle()
                    .fill(theme.color("warn"))
                    .frame(width: 6, height: 6)
                    .help("Uncommitted changes")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? theme.color("accent-soft") : Color.clear)
        .contentShape(Rectangle())
    }

    private var targetList: some View {
        let rows = model.targetRows()
        let selectable = rows.map(\.isSelectable)
        let selectedCommit: CommitInfo? = {
            if rows.indices.contains(model.selectedIndex),
               case .commit(let commit) = rows[model.selectedIndex] {
                return commit
            }
            return nil
        }()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.stableId) { index, row in
                        targetRowView(
                            row,
                            index: index,
                            isSelected: index == model.selectedIndex,
                            selectedCommit: selectedCommit,
                            selectable: selectable
                        )
                        // Content-derived id so filtering rebuilds rows instead
                        // of leaving stale LazyVStack cells at fixed positions.
                        .id(row.stableId)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 200, maxHeight: 420)
            .onChange(of: model.scrollToSelectionTick) { _, _ in
                if rows.indices.contains(model.selectedIndex) {
                    proxy.scrollTo(rows[model.selectedIndex].stableId)
                }
            }
        }
    }

    @ViewBuilder
    private func targetRowView(
        _ row: ReviewTargetPaletteModel.TargetRow,
        index: Int,
        isSelected: Bool,
        selectedCommit: CommitInfo?,
        selectable: [Bool]
    ) -> some View {
        switch row {
        case .header(let title):
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-faint"))
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 3)
        case .message(let text):
            messageRow(text)
        case .followedRevision(let expression, let resolvedSHA, let branch, _):
            followedRevisionRow(
                expression: expression,
                resolvedSHA: resolvedSHA,
                branch: branch,
                isSelected: isSelected
            )
            .onTapGesture {
                model.setSelectedIndex(index, selectable: selectable)
                Task { await model.activateSelection(environment: environment) }
            }
            .onHover { hovering in
                guard hovering else { return }
                let current = NSEvent.mouseLocation
                if lastHoverLocation == current { return }
                lastHoverLocation = current
                model.setSelectedIndex(index, selectable: selectable)
            }
        case .commit(let commit):
            commitRow(commit, isSelected: isSelected, selectedCommit: selectedCommit)
                .onTapGesture {
                    model.setSelectedIndex(index, selectable: selectable)
                    Task { await model.activateSelection(environment: environment) }
                }
                .onHover { hovering in
                    guard hovering else { return }
                    let current = NSEvent.mouseLocation
                    if lastHoverLocation == current { return }
                    lastHoverLocation = current
                    model.setSelectedIndex(index, selectable: selectable)
                }
        case .branch(let name):
            branchRow(name, isSelected: isSelected)
                .onTapGesture {
                    model.setSelectedIndex(index, selectable: selectable)
                    Task { await model.activateSelection(environment: environment) }
                }
                .onHover { hovering in
                    guard hovering else { return }
                    let current = NSEvent.mouseLocation
                    if lastHoverLocation == current { return }
                    lastHoverLocation = current
                    model.setSelectedIndex(index, selectable: selectable)
                }
        }
    }

    private func commitRow(
        _ commit: CommitInfo,
        isSelected: Bool,
        selectedCommit: CommitInfo?
    ) -> some View {
        let isAnchor = model.rangeAnchor?.id == commit.id
        let inRange = model.isInRangePreview(commit, selected: selectedCommit)
        return HStack(spacing: 10) {
            Button {
                model.toggleAnchor(commit)
            } label: {
                Image(systemName: isAnchor
                    ? "smallcircle.filled.circle.fill"
                    : "smallcircle.filled.circle")
                    .foregroundColor(isAnchor ? theme.color("accent") : theme.color("fg-muted"))
            }
            .buttonStyle(.plain)
            .help("Set as range start")
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Text("\(commit.shortSha) · \(commit.author)")
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("fg-dim"))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? theme.color("accent-soft")
                : (inRange ? theme.color("accent-soft").opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func branchRow(_ name: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? theme.color("accent-soft") : Color.clear)
        .contentShape(Rectangle())
    }

    private func followedRevisionRow(
        expression: String,
        resolvedSHA: String,
        branch: String,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pin")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
            VStack(alignment: .leading, spacing: 1) {
                Text(expression)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Text("\(String(resolvedSHA.prefix(10))) · \(branch)")
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("fg-dim"))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? theme.color("accent-soft") : Color.clear)
        .contentShape(Rectangle())
    }

    private func messageRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(theme.color("fg-dim"))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("del"))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(theme.color("del").opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch model.level {
            case .worktrees:
                label("↑↓ navigate")
                label("↵ review vs base")
                label("→ browse commits")
                label("esc close")
            case .targets:
                label("↑↓ navigate")
                label("↵ review")
                label("⊙ set range start")
                label(model.canGoBack ? "esc back" : "esc close")
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2").opacity(0.5))
        .overlay(
            Rectangle().fill(theme.color("line-soft")).frame(height: 0.5),
            alignment: .top
        )
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
    }

    // MARK: - Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let selectable: [Bool]
        switch model.level {
        case .worktrees:
            selectable = model.worktreeEntries(environment: environment).map { _ in true }
        case .targets:
            selectable = model.targetRows().map(\.isSelectable)
        }
        switch press.key {
        case .escape:
            if !model.back() {
                appState.closeReviewPaletteOverlay()
            }
            return .handled
        case .upArrow:
            if press.modifiers.contains(.shift),
               model.extendCommitRangeSelection(step: -1) {
                return .handled
            }
            model.moveSelection(step: -1, selectable: selectable)
            return .handled
        case .downArrow:
            if press.modifiers.contains(.shift),
               model.extendCommitRangeSelection(step: 1) {
                return .handled
            }
            model.moveSelection(step: 1, selectable: selectable)
            return .handled
        case .return:
            Task { await model.activateSelection(environment: environment) }
            return .handled
        case .rightArrow, .tab:
            if case .worktrees = model.level {
                model.drillIntoSelectedWorktree(environment: environment)
                return .handled
            }
            return .ignored
        default:
            return .ignored
        }
    }

    private func requestInputFocus() {
        inputFocused = false
        DispatchQueue.main.async {
            inputFocused = true
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }
}
