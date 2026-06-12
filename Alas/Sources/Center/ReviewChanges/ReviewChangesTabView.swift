import SwiftUI

struct ReviewChangesLoadToken: Equatable {
    let key: String
    let id: UUID

    static func next(key: String) -> ReviewChangesLoadToken {
        ReviewChangesLoadToken(key: key, id: UUID())
    }

    func isActive(activeKey: String?, activeID: UUID) -> Bool {
        activeKey == key && activeID == id
    }
}

struct ReviewChangesLoadKey {
    @MainActor
    static func build(tabID: TabID, worktreePath: URL, rightPaneState: RightPaneState?) -> String {
        [
            tabID,
            worktreePath.path,
            rightPaneState.map(fingerprint) ?? "no-right-pane-state",
        ].joined(separator: "\u{0}")
    }

    @MainActor
    static func fingerprint(rightPaneState: RightPaneState) -> String {
        fingerprint(
            changes: rightPaneState.changes,
            indexFingerprint: rightPaneState.indexFingerprint,
            changesGeneration: rightPaneState.changesGeneration
        )
    }

    static func fingerprint(
        changes: [ChangedFile],
        indexFingerprint: String,
        changesGeneration: Int = 0
    ) -> String {
        let changeTokens = changes
            .sorted { lhs, rhs in
                if lhs.stage != rhs.stage { return lhs.stage.rawValue < rhs.stage.rawValue }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            .map { change in
                [
                    change.stage.rawValue,
                    change.path,
                    change.status,
                    "\(change.add)",
                    "\(change.del)",
                    change.renameFrom ?? "",
                    change.conflict?.rawValue ?? "",
                ].joined(separator: "\u{1f}")
            }
            .joined(separator: "\u{1e}")
        return "\(changesGeneration)\u{0}\(indexFingerprint)\u{0}\(changes.count)\u{0}\(changeTokens)"
    }
}

struct ReviewChangesTabView: View {
    let worktree: Worktree
    let tabState: ReviewChangesTabState
    let appState: AppState
    var loader: ReviewChangesLoader = ReviewChangesLoader()

    @Environment(\.theme) private var theme
    @State private var session: ReviewChangesLoadedSession?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedFileID: ReviewChangesFileID?
    @State private var railCollapsed = false
    @State private var programmaticScroll = ReviewChangesProgrammaticScrollController()
    @State private var activeLoadKey: String?
    @State private var activeLoadID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.color("line"))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
        .task(id: loadKey) {
            await loadSession()
        }
    }

    private var loadKey: String {
        ReviewChangesLoadKey.build(
            tabID: tabState.id,
            worktreePath: worktree.path,
            rightPaneState: appState.rightPaneStore.activeState(worktreeId: worktree.id)
        )
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            stateView(title: "Loading changes...", detail: nil, color: theme.color("fg-dim"))
        } else if let loadError {
            stateView(title: "Could not load review changes", detail: loadError, color: theme.color("del"))
        } else if let session, session.files.isEmpty {
            stateView(title: "No changes to review", detail: "This worktree has no staged or unstaged file diffs.", color: theme.color("fg-dim"))
        } else if let session {
            reviewSurface(session)
        } else {
            stateView(title: "No changes loaded", detail: nil, color: theme.color("fg-dim"))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Review Changes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            if let summary = session?.summary, summary.fileCount > 0 {
                Text("\(summary.fileCount) files")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("fg-dim"))
                Text("+\(summary.totalAdditions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.color("add"))
                Text("-\(summary.totalDeletions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.color("del"))
            }
            Spacer()
            layoutSwitcher
            toolbarButton(
                systemName: diffPreferences.wrapLines.wrappedValue ? "text.justify.left" : "text.alignleft",
                tooltip: "Wrap lines",
                isActive: diffPreferences.wrapLines.wrappedValue
            ) {
                diffPreferences.wrapLines.wrappedValue.toggle()
            }
            toolbarButton(
                systemName: "paragraphsign",
                tooltip: "Show whitespace",
                isActive: diffPreferences.showWhitespace.wrappedValue
            ) {
                diffPreferences.showWhitespace.wrappedValue.toggle()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.color("bg-2"))
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
        let active = diffPreferences.layoutMode.wrappedValue == mode
        return Button {
            diffPreferences.layoutMode.wrappedValue = mode
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
                .frame(width: 26, height: 24)
                .background(isActive ? theme.color("accent-soft") : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func reviewSurface(_ session: ReviewChangesLoadedSession) -> some View {
        let selectedBinding = Binding<ReviewChangesFileID>(
            get: { selectedFileID ?? session.summary.files[0].id },
            set: { selectedFileID = $0 }
        )

        return ScrollViewReader { scrollProxy in
            HStack(spacing: 0) {
                ReviewChangesRail(
                    session: session.summary,
                    selectedFileID: selectedBinding,
                    collapsed: $railCollapsed,
                    onSelectFile: { id in
                        scrollToFile(id, proxy: scrollProxy)
                    }
                )
                mainReviewStream(session)
            }
        }
    }

    private func mainReviewStream(_ session: ReviewChangesLoadedSession) -> some View {
        GeometryReader { viewport in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.files) { file in
                        ReviewChangesFileSection(
                            file: file,
                            layoutMode: diffPreferences.layoutMode,
                            wrapLines: diffPreferences.wrapLines,
                            showWhitespace: diffPreferences.showWhitespace,
                            codeFontFamily: appState.config.code.fontFamily,
                            codeFontSize: CGFloat(appState.config.code.fontSize)
                        )
                        .id(file.summary.id.rawValue)
                        .background(sectionFrameReader(for: file.summary.id))
                    }
                }
                .padding(16)
            }
            .coordinateSpace(name: Self.scrollCoordinateSpace)
            .onPreferenceChange(ReviewChangesSectionFramePreferenceKey.self) { frames in
                updateSelectedFileFromScroll(frames: frames, viewportHeight: viewport.size.height)
            }
        }
        .background(theme.color("bg-1"))
    }

    private func sectionFrameReader(for id: ReviewChangesFileID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ReviewChangesSectionFramePreferenceKey.self,
                value: [
                    ReviewChangesSectionFrame(
                        id: id,
                        minY: proxy.frame(in: .named(Self.scrollCoordinateSpace)).minY,
                        maxY: proxy.frame(in: .named(Self.scrollCoordinateSpace)).maxY
                    ),
                ]
            )
        }
    }

    private func stateView(title: String, detail: String?, color: Color) -> some View {
        VStack(spacing: 8) {
            if isLoading {
                Spinner()
                    .frame(width: 18, height: 18)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func loadSession() async {
        let requestedLoadToken = ReviewChangesLoadToken.next(key: loadKey)
        activeLoadKey = requestedLoadToken.key
        activeLoadID = requestedLoadToken.id
        isLoading = true
        loadError = nil
        session = nil
        defer {
            if requestedLoadToken.isActive(activeKey: activeLoadKey, activeID: activeLoadID) {
                isLoading = false
                activeLoadKey = nil
            }
        }

        do {
            let loaded = try await loader.load(worktreePath: worktree.path)
            guard
                requestedLoadToken.isActive(activeKey: activeLoadKey, activeID: activeLoadID),
                !Task.isCancelled
            else { return }
            session = loaded
            selectedFileID = selectedFileID.flatMap { selected in
                loaded.summary.files.contains { $0.id == selected } ? selected : loaded.summary.files.first?.id
            } ?? loaded.summary.files.first?.id
        } catch is CancellationError {
        } catch {
            guard
                requestedLoadToken.isActive(activeKey: activeLoadKey, activeID: activeLoadID),
                !Task.isCancelled
            else { return }
            loadError = error.localizedDescription
        }
    }

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(appState: appState)
    }

    private func scrollToFile(_ id: ReviewChangesFileID, proxy: ScrollViewProxy) {
        let token = programmaticScroll.beginProgrammaticScroll(to: id)
        selectedFileID = id
        withAnimation(.easeInOut(duration: 0.16)) {
            proxy.scrollTo(id.rawValue, anchor: .top)
        }
        finishProgrammaticScroll(token)
    }

    private func updateSelectedFileFromScroll(frames: [ReviewChangesSectionFrame], viewportHeight: CGFloat) {
        if let updated = ReviewChangesActiveFileSelection.updatedSelection(
            current: selectedFileID,
            frames: frames,
            viewportHeight: viewportHeight,
            programmaticScroll: programmaticScroll
        ) {
            selectedFileID = updated
        }
    }
    private func finishProgrammaticScroll(_ token: ReviewChangesProgrammaticScrollController.Token) {
        Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            await MainActor.run {
                programmaticScroll.finishProgrammaticScroll(token)
            }
        }
    }

    private static let scrollCoordinateSpace = "review-changes-scroll"
}

private struct ReviewChangesSectionFramePreferenceKey: PreferenceKey {
    static let defaultValue: [ReviewChangesSectionFrame] = []

    static func reduce(value: inout [ReviewChangesSectionFrame], nextValue: () -> [ReviewChangesSectionFrame]) {
        value.append(contentsOf: nextValue())
    }
}
