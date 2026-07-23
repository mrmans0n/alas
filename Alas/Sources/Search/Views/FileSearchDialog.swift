import SwiftUI

/// Top-level overlay dialog. Renders as a full-screen translucent backdrop
/// with a centered card that animates in. Pass `appState` for open-action
/// routing.
struct FileSearchDialog: View {
    @Bindable var appState: AppState
    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool

    var body: some View {
        if appState.isSearchOpen {
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 0) {
                    SearchInputRow(model: appState.search, inputFocused: $inputFocused)
                    ScopeRow(
                        model: appState.search,
                        isThisWorktreeAvailable: appState.selectedWorktreeId != nil
                    )
                    if let banner = appState.search.results.partialFailureMessage {
                        BannerRow(text: banner)
                    }
                    resultList
                    SearchFooter(model: appState.search, showsKindToggle: true)
                }
                .frame(width: 720)
                .frame(maxHeight: 520)
                .background(theme.color("bg-1").opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
                .padding(.top, 70)
                .frame(maxHeight: .infinity, alignment: .top)
                .onTapGesture { /* swallow taps so backdrop doesn't close */ }
                .onKeyPress { press in handleKey(press) }
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
            .onAppear { requestInputFocus() }
            .onChange(of: appState.isSearchOpen) { _, isOpen in
                if isOpen { requestInputFocus() }
            }
        }
    }

    @ViewBuilder
    private var resultList: some View {
        let model = appState.search
        if model.totalResultRows == 0 {
            SearchEmptyState(model: model)
                .frame(minHeight: 240, maxHeight: 460)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        switch model.kind {
                        case .files:
                            ForEach(Array(model.results.fileResults.enumerated()), id: \.element.id) { idx, r in
                                FileResultRow(
                                    result: r,
                                    isSelected: idx == model.selectedIndex,
                                    showsRepoBadge: model.scope == .allRepos,
                                    repoName: repoName(for: r),
                                    onTap: { open(r) },
                                    onHover: { model.selectedIndex = idx }
                                )
                                // Identity/scroll anchor is the file id, not the
                                // row position. A stable position id (`.id(idx)`)
                                // let LazyVStack cache the row and never rebuild
                                // it when the file at that position changed,
                                // freezing stale results; a data-based id changes
                                // with the file and still gives `scrollTo` an
                                // explicit target for keyboard navigation.
                                .id(r.id)
                            }
                        case .content:
                            contentGroupViews(model: model)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 240, maxHeight: 460)
                .onChange(of: model.scrollToSelectionTick) { _, _ in
                    // Scroll target is the selected row's element id — matching
                    // the identities the ForEach rows now use.
                    let targetId: String? = switch model.kind {
                    case .files:
                        model.results.fileResults[safe: model.selectedIndex]?.id
                    case .content:
                        hit(at: model.selectedIndex, in: model.results.contentGroups)?.id
                    }
                    if let targetId {
                        proxy.scrollTo(targetId, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contentGroupViews(model: SearchModel) -> some View {
        let pairs: [(ContentSearchGroup, Int)] = {
            var out: [(ContentSearchGroup, Int)] = []
            var base = 0
            for g in model.results.contentGroups {
                out.append((g, base))
                base += g.hits.count
            }
            return out
        }()
        ForEach(pairs, id: \.0.id) { group, baseIdx in
            ContentResultGroupView(
                group: group,
                baseIndex: baseIdx,
                selectedIndex: model.selectedIndex,
                onTap: { hit in openContent(hit) },
                onHover: { idx in model.selectedIndex = idx }
            )
        }
    }

    private func openContent(_ hit: ContentSearchHit) {
        appState.openFile(
            relativePath: hit.relativePath,
            worktreeId: hit.worktreeId,
            revealLine: hit.revealLine,
            revealCharacter: hit.revealCharacter
        )
        close()
    }

    /// Resolve a flat selection index to a hit by walking groups in order.
    private func hit(at index: Int, in groups: [ContentSearchGroup]) -> ContentSearchHit? {
        var remaining = index
        for group in groups {
            if remaining < group.hits.count {
                return group.hits[remaining]
            }
            remaining -= group.hits.count
        }
        return nil
    }

    private func repoName(for r: FileSearchResult) -> String? {
        appState.projects.first(where: { $0.id == r.projectId })?.name
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let model = appState.search
        switch press.key {
        case .escape:
            close()
            return .handled
        case .upArrow:
            model.moveSelection(to: max(0, model.selectedIndex - 1))
            return .handled
        case .downArrow:
            model.moveSelection(to: min(max(0, model.totalResultRows - 1), model.selectedIndex + 1))
            return .handled
        case .return:
            // Branch on kind so a Tab → Return on a stale file row from a
            // previous mode doesn't open the wrong thing while content
            // results haven't arrived yet.
            switch model.kind {
            case .files:
                if let row = model.results.fileResults[safe: model.selectedIndex] {
                    open(row)
                }
            case .content:
                if let hit = hit(at: model.selectedIndex, in: model.results.contentGroups) {
                    openContent(hit)
                }
            }
            return .handled
        case .tab:
            model.toggleKind()
            return .handled
        default:
            return .ignored
        }
    }

    private func open(_ r: FileSearchResult) {
        appState.openFile(relativePath: r.relativePath, worktreeId: r.worktreeId)
        close()
    }

    private func close() {
        appState.search.close()
        appState.isSearchOpen = false
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

private struct BannerRow: View {
    let text: String
    @Environment(\.theme) private var theme
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.color("warn"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(theme.color("warn").opacity(0.10))
            .overlay(
                Rectangle()
                    .fill(theme.color("line-soft"))
                    .frame(height: 0.5),
                alignment: .bottom
            )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
