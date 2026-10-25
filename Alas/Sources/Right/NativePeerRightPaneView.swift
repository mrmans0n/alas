import SwiftUI

/// The right pane for a selected peer worktree: its changes and files, and
/// its sessions. Changes are read-only unless the host serves git actions;
/// Run is offered by hosts that serve their scripts; schedules only make
/// sense on this Mac and are not offered.
struct NativePeerRightPaneView: View {
    @Bindable var state: AppState
    @Bindable var client: NativePeerSessions
    var collapsed: Bool = false

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeTab: RightPaneTab = .changes
    @State private var openPaths: Set<String> = []
    @State private var bookmarkOpenPaths: Set<String> = []
    @State private var railBodyWidth: Double = 0
    @State private var runRefreshGeneration = 0
    /// The git target's review status, as the host reads it.
    @State private var reviewLoop = ReviewLoopState(worktreePath: URL(fileURLWithPath: "/"), baseBranch: "")
    @State private var gitError: String?
    @State private var pendingDiscard: PendingDiscard?
    @State private var commitTarget: (serverId: String, worktree: PeerHostWorktree)?
    @State private var pullInFlight = false
    /// The git target's draft reviews, as the host lists them.
    @State private var reviews: [HostReviewSummary] = []
    @State private var reviewsExpanded = true

    var body: some View {
        let tabs = self.tabs
        let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
        ZStack {
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            HStack(spacing: 0) {
                if !collapsed {
                    VStack(spacing: 0) {
                        toolbar
                        tabContent(shownTab(in: tabs))
                            .scrollIndicators(.hidden)
                    }
                    // Short content (a one-line message) must not let the
                    // stack shrink and float to the vertical center.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { railBodyWidth = $0 }
                    .transition(PaneCollapseMotion.transition(
                        edge: .trailing,
                        width: railBodyWidth,
                        reduceMotion: reduceMotion
                    ))
                }
                RightPaneRail(
                    activeTab: shownTab(in: tabs),
                    collapsed: collapsed,
                    changesCount: changesCount,
                    activeRunCount: activeRunCount,
                    tabs: tabs,
                    onAction: { handle($0, tabs: tabs) }
                )
            }
            .sidebarChromeTheme(textContrast: override.textContrast)
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasSelectRightPaneTab)) { notification in
            guard let raw = notification.object as? String,
                  let tab = RightPaneTab(rawValue: raw),
                  tabs.contains(tab)
            else { return }
            handle(RightPaneRailAction.resolve(tapped: tab, active: shownTab(in: tabs), collapsed: collapsed), tabs: tabs)
        }
        .onChange(of: client.selectedWorktree) { _, _ in
            openPaths = []
            gitError = nil
            pendingDiscard = nil
        }
        .onChange(of: state.config.changes.comparisonMode) { _, _ in
            client.reloadWorkspace()
        }
        .onChange(of: gitTargetKey, initial: true) { _, _ in
            // The previous worktree's pill and reviews must not stand in until the new read.
            reviewLoop.showHostSnapshot(nil)
            reviews = []
            client.hosts?.followGit(gitTarget?.worktree, serverId: gitTarget?.serverId)
        }
        .onDisappear { client.hosts?.followGit(nil, serverId: nil) }
        // Once per follow sent: the host repeats no unchanged status to a new subscription.
        .task(id: client.hosts?.gitFollowKey) { await readReviewStatus() }
        .onChange(of: liveReviewStatus) { _, status in reviewLoop.showHostSnapshot(status) }
        .task(id: reviewsKey) { await readReviews() }
        .alert(
            PendingDiscard.alertTitle(for: pendingDiscard ?? .placeholder),
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            presenting: pendingDiscard,
            actions: { pending in
                Button("Discard", role: .destructive) {
                    pendingDiscard = nil
                    if let gitTarget { runGit(.discard(paths: pending.paths), on: gitTarget) }
                }
                Button("Cancel", role: .cancel) { pendingDiscard = nil }
            },
            message: { pending in
                Text(PendingDiscard.alertMessage(for: pending))
            }
        )
        .sheet(isPresented: Binding(
            get: { commitTarget != nil },
            set: { if !$0 { commitTarget = nil } }
        )) {
            if let commitTarget, let hosts = client.hosts {
                commitSheet(commitTarget, hosts: hosts)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Icon(name: "branch", size: 10, color: theme.color("fg-muted"))
            // The peer's name already shows in the center pane's tab bar.
            Text(client.selectedWorktreeGroup?.worktree?.branch ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let gitTarget, let local = behindUpstream {
                BehindChip(
                    count: local.upstreamAheadCommitCount,
                    role: .upstream,
                    inFlight: pullInFlight,
                    onTap: { pull(gitTarget) },
                    ref: local.upstreamRemoteName.map { "\($0)/\(local.upstreamBranchName ?? local.branchName)" }
                )
            }
            if let gitTarget {
                Menu {
                    // Here as well as in the Working tree header, so a message-only amend
                    // is reachable with nothing staged or changed.
                    Button("Commit…") { commitTarget = gitTarget }
                    Divider()
                    Button("Fetch now") { runGit(.fetch, on: gitTarget) }
                } label: {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.color("fg-muted"))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Branch operations")
            }
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ToolbarBtn(icon: "arrow.clockwise", tooltip: "Refresh from peer") {
                client.reloadWorkspace()
                runRefreshGeneration += 1
                Task { await readReviewStatus() }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func tabContent(_ shownTab: RightPaneTab) -> some View {
        if shownTab == .agent {
            agentTab
        } else if shownTab == .run, let runTarget, let hosts = client.hosts {
            // Runs come from the host channel, so they need no session.
            NativePeerRunTabView(
                hosts: hosts,
                serverId: runTarget.serverId,
                worktree: runTarget.worktree,
                hostName: client.selectedWorktreePeer?.name ?? "The host",
                refreshGeneration: runRefreshGeneration,
                consoleIds: Set(client.consoles?.consoles[runTarget.serverId]?.map(\.consoleId) ?? []),
                openConsole: { client.selectConsole(serverId: runTarget.serverId, consoleId: $0) }
            )
        } else if !client.canReadWorkspace {
            // Changes and files are served per session, or per worktree by a
            // host that reads worktrees.
            NativePeerRailMessage(text: "Select a session to see this worktree's changes and files.")
        } else if shownTab == .files {
            filesTab
        } else {
            VStack(spacing: 0) {
                if let gitError {
                    NativePeerRailMessage(text: gitError)
                }
                NativePeerChangesView(
                    changes: client.workspace.changes,
                    worktreePath: URL(fileURLWithPath: client.workspaceWorktreePath ?? "/"),
                    commitFiles: client.workspace.commitFiles,
                    onLoadCommitFiles: { client.loadCommitFiles(sha: $0) },
                    onOpen: { client.open($0) },
                    git: gitActions
                )
                .id(client.selectedSessionId ?? client.selectedWorktree?.worktreeId)
                .frame(maxHeight: .infinity, alignment: .top)
                // Outside the changes view, so they show with no changes too.
                if let gitTarget, reviewsKey != nil {
                    reviewsSection(gitTarget)
                }
                if gitTarget != nil, reviewLoop.snapshot != nil {
                    ReviewLoopDrawer(
                        state: reviewLoop,
                        canOpenAgentHandoff: false,
                        onAction: { handleReviewAction($0) },
                        servedActions: ReviewReadinessActionKind.peerServed
                    )
                }
            }
        }
    }

    private var gitActions: NativePeerChangesView.Git? {
        guard let gitTarget else { return nil }
        return NativePeerChangesView.Git(
            onStage: { runGit(.stage(paths: $0.map(\.path)), on: gitTarget) },
            onUnstage: { runGit(.unstage(paths: $0.map(\.path)), on: gitTarget) },
            onDiscard: { pendingDiscard = $0 },
            onCommit: { commitTarget = gitTarget }
        )
    }

    /// Runs `change` on the host, shows its error in the rail, and reads the
    /// changes again either way.
    private func runGit(
        _ change: HostWorktreeChange,
        on target: (serverId: String, worktree: PeerHostWorktree),
        then done: @escaping @MainActor () -> Void = {}
    ) {
        guard let hosts = client.hosts else { return }
        gitError = nil
        let key = gitTargetKey
        Task { @MainActor in
            let error = await hosts.mutate(change, in: target.worktree, serverId: target.serverId)
            // The selection moved on: the answer belongs to another worktree.
            if gitTargetKey == key {
                gitError = error
                client.reloadWorkspace()
            }
            done()
        }
    }

    private func pull(_ target: (serverId: String, worktree: PeerHostWorktree)) {
        guard !pullInFlight else { return }
        pullInFlight = true
        runGit(.pull, on: target) { pullInFlight = false }
    }

    private func handleReviewAction(_ kind: ReviewReadinessActionKind) {
        guard let gitTarget else { return }
        switch kind {
        case .refresh:
            guard reviewLoop.beginAction(kind) else { return }
            Task { @MainActor in
                await readReviewStatus()
                reviewLoop.endAction(kind)
            }
        case .pushBranch, .forcePushBranch:
            guard reviewLoop.beginAction(kind) else { return }
            runGit(.push(forceWithLease: kind == .forcePushBranch), on: gitTarget) { reviewLoop.endAction(kind) }
        case .openReviewRequest:
            if let url = reviewLoop.snapshot?.reviewRequest?.url { NSWorkspace.shared.open(url) }
        default:
            break // `peerServed` offers no other action.
        }
    }

    /// The host's reviews, led by its local changes until they are listed,
    /// so a review of them can be started from here as in the Changes tab.
    @ViewBuilder
    private func reviewsSection(_ target: (serverId: String, worktree: PeerHostWorktree)) -> some View {
        let worktree = target.worktree.snapshot.worktree
        let localChanges = ReviewDraftSessionID.localChanges(
            worktreeID: worktree.id, worktreePath: worktree.path, scope: .all
        ).rawValue
        let listsLocalChanges = reviews.contains { $0.sessionID == localChanges }
        SectionHeader(
            role: .reviews,
            title: "Reviews",
            count: reviews.count,
            expanded: reviewsExpanded,
            onToggle: { reviewsExpanded.toggle() }
        ) { EmptyView() }
        if reviewsExpanded {
            if !listsLocalChanges {
                reviewRow(title: "Review local changes", subtitle: nil, verdict: nil, openCount: 0) {
                    client.openReview(localChanges, serverId: target.serverId, worktree: target.worktree)
                }
            }
            ForEach(reviews, id: \.sessionID) { review in
                reviewRow(
                    title: review.record.target.title,
                    subtitle: review.record.target.sourceDescription,
                    verdict: review.record.verdict?.verdict,
                    openCount: review.openCommentCount
                ) {
                    client.openReview(review.sessionID, serverId: target.serverId, worktree: target.worktree)
                }
            }
        }
    }

    private func reviewRow(
        title: String, subtitle: String?, verdict: ReviewVerdict?, openCount: Int, open: @escaping () -> Void
    ) -> some View {
        Button(action: open) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg"))
                    if let subtitle {
                        Text(subtitle).foregroundColor(theme.color("fg-faint"))
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 4)
                if let verdict {
                    Text(verdict.peerLabel).foregroundColor(theme.color("fg-dim"))
                }
                if openCount > 0 {
                    Text("\(openCount) open").foregroundColor(theme.color("accent"))
                }
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// Changes when the git target's reviews should be listed again: a new
    /// target, the host serving reviews, or its `reviewsChanged`.
    private var reviewsKey: String? {
        guard let gitTarget, let gitTargetKey, let hosts = client.hosts,
              hosts.servesReviews(serverId: gitTarget.serverId)
        else { return nil }
        let revision = hosts.reviewRevisions[gitTarget.serverId]?[gitTarget.worktree.snapshot.worktree.id] ?? 0
        return "\(gitTargetKey)#\(revision)"
    }

    /// The git target's reviews. A refusal or no answer keeps the last list.
    private func readReviews() async {
        guard reviewsKey != nil, let gitTarget, let hosts = client.hosts else {
            reviews = []
            return
        }
        let key = gitTargetKey
        let listed = await hosts.reviews(in: gitTarget.worktree, serverId: gitTarget.serverId)
        guard !Task.isCancelled, gitTargetKey == key else { return }
        if let listed { reviews = listed }
    }

    /// The git target's review status, read again on the host. A refusal
    /// reads as no status.
    private func readReviewStatus() async {
        guard let gitTarget, let hosts = client.hosts else {
            reviewLoop.showHostSnapshot(nil)
            return
        }
        // Not followed yet: the follow's key change reads it once sent.
        guard hosts.gitFollowKey != nil else { return }
        let key = gitTargetKey
        let status = await hosts.reviewStatus(in: gitTarget.worktree, serverId: gitTarget.serverId)
        // A manual refresh is unstructured: a late reply must not land on another worktree.
        guard !Task.isCancelled, gitTargetKey == key else { return }
        reviewLoop.showHostSnapshot(status)
    }

    private func commitSheet(
        _ target: (serverId: String, worktree: PeerHostWorktree), hosts: NativePeerHosts
    ) -> some View {
        let worktree = target.worktree.snapshot.worktree
        // The host sends what the message is suggested from; this Mac's model writes it.
        var suggest: (@MainActor () async -> CommitMessageSuggestion?)?
        if state.commitMessageSuggestionAvailable {
            suggest = {
                guard let input = await hosts.commitMessageInput(in: target.worktree, serverId: target.serverId) else {
                    return nil
                }
                return await state.makeCommitMessageSuggester().suggest(for: input)
            }
        }
        return NativePeerCommitSheet(
            subtitle: "\(worktree.branch) on \(client.selectedWorktreePeer?.name ?? "the host")",
            hasStaged: hasStagedChanges,
            suggest: suggest,
            commit: { subject, body, amend in
                let error = await hosts.mutate(
                    .commit(subject: subject, body: body, amend: amend), in: target.worktree, serverId: target.serverId
                )
                client.reloadWorkspace()
                return error
            },
            onDismiss: { commitTarget = nil }
        )
    }

    private var agentTab: some View {
        let canOpen = client.selectedWorktree.map { client.canOpenSessionTabs(serverId: $0.serverId) } ?? false
        return VStack(spacing: 0) {
            if let error = client.sessionTabError {
                NativePeerRailMessage(text: error)
            }
            AgentTabView(
                rollup: AgentSidebarRollupBuilder.peer(client.selectedWorktreeGroup?.sessions ?? []),
                agentLookup: { agentID in
                    state.agent(id: agentID == AgentKind.cursor.rawValue ? "cursor-agent" : agentID)
                },
                actions: AgentSidebarActions(
                    onFocus: { rowID in
                        if case .acp(let sessionID) = rowID { client.openSession(sessionID) }
                    },
                    onInterrupt: { _ in },
                    onFollowUp: { _, _ in },
                    onDelegate: nil
                ),
                followUps: .constant([:]),
                disabledReason: { row in
                    row.state == .detached && !canOpen
                        ? "\(client.selectedWorktreePeer?.name ?? "This Mac") needs a newer Alas to open past sessions."
                        : nil
                }
            )
            .id(client.selectedWorktree)
        }
    }

    @ViewBuilder
    private var filesTab: some View {
        switch client.workspace.fileTree {
        case .idle, .loading:
            RightPaneLoadingSkeletonView(activeTab: .files)
        case .failed(let message):
            NativePeerRailMessage(text: message)
        case .loaded(let nodes):
            VStack(spacing: 0) {
                if client.workspace.fileTreeTruncated {
                    NativePeerRailMessage(text: "The peer shortened one or more directory listings.")
                }
                FilesTabView(
                    nodes: nodes,
                    fileTreeGeneration: 0,
                    fileTreeRefreshRevision: client.workspace.fileTreeRevision,
                    // Only used to build copied full paths; the path is the peer's.
                    worktreePath: URL(fileURLWithPath: client.workspaceWorktreePath ?? "/"),
                    openPaths: $openPaths,
                    onSelectFile: { client.open(.file(path: $0.path)) },
                    onFileHistory: { _ in },
                    onCreateFile: { _ in },
                    onCreateFolder: { _ in },
                    shouldAutoLoadChildren: { client.workspace.shouldLoadChildren(path: $0, childrenState: $1) },
                    onLoadChildren: { client.loadFileTreeChildren(path: $0) },
                    showIgnored: false,
                    revealPath: nil,
                    revealTick: 0,
                    onClearReveal: {},
                    bookmarkOpenPaths: $bookmarkOpenPaths,
                    readOnly: true
                )
            }
        }
    }

    /// A folder project has no Changes tab, so it shows Files in its place.
    private var isFolder: Bool { client.selectedWorktreeGroup?.isFolder == true }
    /// The selected worktree on a host that serves its Run tab.
    private var runTarget: (serverId: String, worktree: PeerHostWorktree)? {
        guard let selection = client.selectedWorktree, let host = client.selectedWorktreeGroup?.host,
              client.hosts?.servesRuns(serverId: selection.serverId) == true
        else { return nil }
        return (selection.serverId, host)
    }

    /// The selected worktree on a host that serves its git actions.
    private var gitTarget: (serverId: String, worktree: PeerHostWorktree)? {
        guard !isFolder, let selection = client.selectedWorktree, let host = client.selectedWorktreeGroup?.host,
              !host.snapshot.isArchived, client.hosts?.servesGit(serverId: selection.serverId) == true
        else { return nil }
        return (selection.serverId, host)
    }

    private var gitTargetKey: String? {
        gitTarget.map { "\($0.serverId)/\($0.worktree.snapshot.worktree.id)" }
    }

    private var hasStagedChanges: Bool {
        if case .loaded(let changes) = client.workspace.changes { return !changes.staged.isEmpty }
        return false
    }

    /// The git target's status as the host's events last sent it.
    private var liveReviewStatus: ReviewLoopSnapshot? {
        gitTarget.flatMap { client.hosts?.reviewStatuses[$0.serverId]?[$0.worktree.snapshot.worktree.id] }
    }

    /// The host's branch when it is behind its upstream, as `showBehindUpstreamChip`.
    private var behindUpstream: ReviewLoopLocalState? {
        guard gitTarget != nil, let local = reviewLoop.snapshot?.local, local.hasUpstream,
              local.upstreamAheadCommitCount > 0, !local.branchName.isEmpty
        else { return nil }
        return local
    }

    private var tabs: [RightPaneTab] { RightPaneTab.peerAvailable(isFolder: isFolder, servesRuns: runTarget != nil) }

    /// Keeps the folder rule (Files in place of Changes) and drops a Run tab
    /// the host no longer serves.
    private func shownTab(in tabs: [RightPaneTab]) -> RightPaneTab {
        tabs.contains(activeTab) ? activeTab : tabs[0]
    }

    private var activeRunCount: Int {
        guard let runTarget else { return 0 }
        let worktreeID = runTarget.worktree.snapshot.worktree.id
        return client.hosts?.runs[runTarget.serverId]?.count(where: { $0.worktreeID == worktreeID && $0.status.isActive }) ?? 0
    }

    private var changesCount: Int {
        if case .loaded(let changes) = client.workspace.changes { return changes.branchFiles.count }
        return client.selectedWorktreeGroup?.worktree?.changedFileCount ?? 0
    }

    private func handle(_ action: RightPaneRailAction, tabs: [RightPaneTab]) {
        let outcome = RightPaneRailModel.apply(
            action,
            currentTab: shownTab(in: tabs),
            currentVisible: state.config.rightPaneVisible
        )
        activeTab = outcome.tab
        if state.config.rightPaneVisible != outcome.visible {
            state.config.rightPaneVisible = outcome.visible
            state.saveConfig()
        }
    }
}
