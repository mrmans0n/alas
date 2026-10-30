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
    /// The git target's stashes, as the host lists them; nil while it serves none.
    @State private var stashes: [GitStash]?
    /// Each open stash's files, by ref.
    @State private var stashFiles: [String: NativePeerWorkspace.Load<[GitStashFile]>] = [:]
    @State private var pendingStashDrop: PendingStashDrop?
    /// Bumped by each stash list read, so only the latest one lands.
    @State private var stashReadGeneration = 0
    /// The worktree "Stash Changes…" was chosen for, while its sheet shows.
    @State private var stashChangesTarget: (serverId: String, worktree: PeerHostWorktree)?
    /// The commit chosen to cherry-pick (`.cherryPick`) or revert (`.revert`), while its confirmation shows.
    @State private var pendingCommitAction: (kind: HostOperationKind, commit: RemoteCommit)?
    /// The git target's checkpoints, as the host lists them; nil while it serves none.
    @State private var checkpoints: CheckpointCatalogSnapshot?
    @State private var checkpointsExpanded = true
    /// Each expanded checkpoint's manifest, and the page of its files shown, by id.
    @State private var checkpointManifests: [CheckpointID: NativePeerWorkspace.Load<WorktreeCheckpointManifest>] = [:]
    @State private var checkpointPages: [CheckpointID: Int] = [:]
    /// Bumped by each checkpoint list read, so only the latest one lands.
    @State private var checkpointReadGeneration = 0
    /// While a checkpoint is taken, previewed or restored.
    @State private var checkpointInFlight = false
    @State private var creatingCheckpoint = false
    @State private var checkpointCreateError: String?
    @State private var checkpointRestorePreview: CheckpointRestorePreview?
    @State private var checkpointRestoreError: String?
    @State private var pendingCheckpointDeletion: WorktreeCheckpointSummary?
    /// Whether the branch picker merges into the git target or rebases it, while it shows.
    @State private var integrateKind: IntegrateKind?
    @State private var integrateBranch = ""
    /// The git target's project branches for the picker; nil while the host has not answered.
    @State private var integrateBranches: NativePeerNewSession.Branches?

    var body: some View {
        // Split so each part type-checks in reasonable time.
        checkpointPrompts(prompts(commitPrompts(changePrompts(content))))
    }

    @ViewBuilder
    private var content: some View {
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
            pendingStashDrop = nil
            pendingCommitAction = nil
            pendingCheckpointDeletion = nil
            integrateKind = nil
        }
        .onChange(of: state.config.changes.comparisonMode) { _, _ in
            client.reloadWorkspace()
        }
        .onChange(of: gitTargetKey, initial: true) { _, _ in
            // The previous worktree's pill and reviews must not stand in until the new read.
            reviewLoop.showHostSnapshot(nil)
            reviews = []
            stashes = nil
            stashFiles = [:]
            checkpoints = nil
            checkpointManifests = [:]
            checkpointPages = [:]
            creatingCheckpoint = false
            checkpointRestorePreview = nil
            client.hosts?.followGit(gitTarget?.worktree, serverId: gitTarget?.serverId)
        }
        .onDisappear { client.hosts?.followGit(nil, serverId: nil) }
        // Once per follow sent: the host repeats no unchanged status to a new subscription.
        .task(id: client.hosts?.gitFollowKey) { await readReviewStatus() }
        .onChange(of: liveReviewStatus) { _, status in reviewLoop.showHostSnapshot(status) }
        .task(id: reviewsKey) { await readReviews() }
        .task(id: stashesKey) { await readStashes() }
        // A pop or apply changes the list as well. A refresh keeps the loaded
        // changes until the new ones land, so an unchanged list fires nothing:
        // stash actions and the toolbar's refresh read the stashes themselves.
        .onChange(of: client.workspace.changes) { _, changes in
            if case .loaded = changes {
                Task { await readStashes() }
                Task { await readCheckpoints() }
            }
        }
    }

    /// The discard and stash-drop confirmations.
    private func changePrompts(_ content: some View) -> some View {
        content
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
        .alert(
            PendingStashDrop.alertTitle(for: pendingStashDrop ?? .placeholder),
            isPresented: Binding(
                get: { pendingStashDrop != nil },
                set: { if !$0 { pendingStashDrop = nil } }
            ),
            presenting: pendingStashDrop,
            actions: { pending in
                Button("Drop", role: .destructive) {
                    pendingStashDrop = nil
                    if let gitTarget { runStashChange(.dropStash(HostStashRef(pending.stash)), on: gitTarget) }
                }
                Button("Cancel", role: .cancel) { pendingStashDrop = nil }
            },
            message: { pending in
                Text(PendingStashDrop.alertMessage(for: pending))
            }
        )
    }

    /// The cherry-pick and revert confirmations.
    private func commitPrompts(_ content: some View) -> some View {
        content
        // The local copy: RightPaneView's cherry-pick alert and CommitRow's revert dialog.
        .alert(
            "Cherry-pick commit?",
            isPresented: Binding(
                get: { pendingCommitAction?.kind == .cherryPick },
                set: { if !$0 { pendingCommitAction = nil } }
            ),
            presenting: pendingCommitAction?.commit,
            actions: { commit in
                Button("Cherry-pick \(commit.revision.prefix(7))") { confirmCommitAction(.cherryPick(sha: commit.revision)) }
                Button("Cancel", role: .cancel) { pendingCommitAction = nil }
            },
            message: { _ in
                Text("Apply this commit to the current branch.")
            }
        )
        .confirmationDialog(
            "Revert commit?",
            isPresented: Binding(
                get: { pendingCommitAction?.kind == .revert },
                set: { if !$0 { pendingCommitAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingCommitAction?.commit,
            actions: { commit in
                Button("Revert \(String(commit.revision.prefix(7)))", role: .destructive) {
                    confirmCommitAction(.revert(sha: commit.revision))
                }
                Button("Cancel", role: .cancel) { pendingCommitAction = nil }
            },
            message: { _ in
                Text("Create a new commit that reverses this commit.")
            }
        )
    }

    /// The commit and stash sheets.
    private func prompts(_ content: some View) -> some View {
        content
        .sheet(isPresented: Binding(
            get: { commitTarget != nil },
            set: { if !$0 { commitTarget = nil } }
        )) {
            if let commitTarget, let hosts = client.hosts {
                commitSheet(commitTarget, hosts: hosts)
            }
        }
        .sheet(isPresented: Binding(
            get: { stashChangesTarget != nil },
            set: { if !$0 { stashChangesTarget = nil } }
        )) {
            if let target = stashChangesTarget {
                StashChangesSheet(
                    onStash: { message, includeUntracked in
                        stashChangesTarget = nil
                        runStashChange(.stash(message: message, includeUntracked: includeUntracked), on: target)
                    },
                    onCancel: { stashChangesTarget = nil }
                )
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
                    if client.hosts?.servesCheckpoints(serverId: gitTarget.serverId) == true {
                        Button("Create Checkpoint…") { beginCheckpointCreation() }
                    }
                    if client.hosts?.servesIntegrate(serverId: gitTarget.serverId) == true {
                        Button("Merge branch into this worktree…") { openIntegratePicker(.merge, on: gitTarget) }
                        Button("Rebase this worktree onto…") { openIntegratePicker(.rebase, on: gitTarget) }
                    }
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
                .popover(isPresented: Binding(
                    get: { integrateKind != nil },
                    set: { if !$0 { integrateKind = nil } }
                ), arrowEdge: .bottom) {
                    integratePicker(gitTarget)
                }
            }
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ToolbarBtn(icon: "arrow.clockwise", tooltip: "Refresh from peer") {
                client.reloadWorkspace()
                runRefreshGeneration += 1
                Task { await readReviewStatus() }
                Task { await readStashes() }
                Task { await readCheckpoints() }
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
                    // A rename's history follows its old path, as locally.
                    onFileHistory: fileHistoryAction.map { history in { history($0.renameFrom ?? $0.path) } },
                    git: gitActions
                )
                .id(client.selectedSessionId ?? client.selectedWorktree?.worktreeId)
                .frame(maxHeight: .infinity, alignment: .top)
                // Outside the changes view, so they show with no changes too.
                if let gitTarget, reviewsKey != nil {
                    reviewsSection(gitTarget)
                }
                if let gitTarget, let catalog = checkpoints, !catalog.summaries.isEmpty {
                    checkpointsSection(gitTarget, catalog: catalog)
                }
                if let gitTarget, reviewLoop.snapshot != nil {
                    ReviewLoopDrawer(
                        state: reviewLoop,
                        canOpenAgentHandoff: false,
                        onAction: { handleReviewAction($0) },
                        servedActions: client.hosts?.servesProviderReviews(serverId: gitTarget.serverId) == true
                            ? ReviewReadinessActionKind.peerServed.union([.inspectReviewEvidence])
                            : ReviewReadinessActionKind.peerServed
                    )
                }
            }
        }
    }

    private var gitActions: NativePeerChangesView.Git? {
        guard let gitTarget else { return nil }
        let servesOperations = client.hosts?.servesOperations(serverId: gitTarget.serverId) == true
        return NativePeerChangesView.Git(
            onStage: { runGit(.stage(paths: $0.map(\.path)), on: gitTarget) },
            onUnstage: { runGit(.unstage(paths: $0.map(\.path)), on: gitTarget) },
            onDiscard: { pendingDiscard = $0 },
            onCommit: { commitTarget = gitTarget },
            stashes: stashes,
            stashFiles: stashFiles,
            onStashChanges: { stashChangesTarget = gitTarget },
            onToggleStash: { toggleStash($0, on: gitTarget) },
            onApplyStash: { runStashChange(.applyStash(HostStashRef($0)), on: gitTarget) },
            onPopStash: { runStashChange(.popStash(HostStashRef($0)), on: gitTarget) },
            onDropStash: { pendingStashDrop = PendingStashDrop(stash: $0) },
            servesOperations: servesOperations,
            editsFiles: client.hostFileTarget != nil,
            onContinue: { runGit(.continueOperation(kind: HostOperationKind($0)), on: gitTarget) },
            onSkip: { runGit(.skipOperation(kind: HostOperationKind($0)), on: gitTarget) },
            onAbort: { runGit(.abortOperation(kind: HostOperationKind($0)), on: gitTarget) },
            onUseOurs: { runGit(.useOurs(path: $0.path), on: gitTarget) },
            onUseTheirs: { runGit(.useTheirs(path: $0.path), on: gitTarget) },
            onKeepDeleted: { runGit(.keepDeleted(path: $0.path), on: gitTarget) },
            onMarkResolved: { runGit(.markResolved(path: $0.path), on: gitTarget) },
            onCherryPick: servesOperations ? { pendingCommitAction = (kind: .cherryPick, commit: $0) } : nil,
            onRevert: servesOperations ? { pendingCommitAction = (kind: .revert, commit: $0) } : nil,
            onEditCommit: client.hosts?.servesCommitEdit(serverId: gitTarget.serverId) == true
                ? { commit in
                    guard let sha = commit.sha else { return }
                    client.openCommitEditor(NativePeerCommitEditorSelection(
                        serverId: gitTarget.serverId, worktree: gitTarget.worktree, sha: sha,
                        comparisonMode: state.config.changes.comparisonMode
                    ))
                }
                : nil
        )
    }

    /// The local `BranchOpsMenu` picker, over the host project's branches less the worktree's own.
    private func integratePicker(_ target: (serverId: String, worktree: PeerHostWorktree)) -> some View {
        let isMerge = integrateKind == .merge
        let ownBranch = target.worktree.snapshot.worktree.branch
        var names: [String] = []
        var failure: String?
        switch integrateBranches {
        case .loaded(let all, _): names = all.filter { $0 != ownBranch }
        case .failed(let message): failure = message
        case nil: break
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(isMerge ? "Merge into current" : "Rebase current onto").font(.system(size: 12, weight: .semibold))
            BranchPicker(
                selection: $integrateBranch,
                branches: names,
                isLoading: integrateBranches == nil,
                errorMessage: failure
            )
            .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { integrateKind = nil }
                Button(isMerge ? "Merge" : "Rebase") {
                    let branch = integrateBranch
                    guard !branch.isEmpty else { return }
                    integrateKind = nil
                    runGit(isMerge ? .merge(branch: branch) : .rebase(onto: branch), on: target)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(integrateBranch.isEmpty)
            }
        }
        .padding(12)
    }

    private func openIntegratePicker(_ kind: IntegrateKind, on target: (serverId: String, worktree: PeerHostWorktree)) {
        integrateBranch = ""
        integrateBranches = nil
        integrateKind = kind
        let key = gitTargetKey
        client.requestBranches(projectId: target.worktree.snapshot.worktree.projectId, serverId: target.serverId) {
            // A later open, or another worktree, owns the picker now.
            guard gitTargetKey == key, integrateKind == kind, integrateBranches == nil else { return }
            integrateBranches = $0
        }
    }

    /// Runs the confirmed cherry-pick or revert.
    private func confirmCommitAction(_ change: HostWorktreeChange) {
        pendingCommitAction = nil
        if let gitTarget { runGit(change, on: gitTarget) }
    }

    /// Runs a stash `change`, then lists the stashes again.
    private func runStashChange(_ change: HostWorktreeChange, on target: (serverId: String, worktree: PeerHostWorktree)) {
        runGit(change, on: target) { Task { await readStashes() } }
    }

    /// Opens or closes `stash`'s files; an open stash is read on the host.
    private func toggleStash(_ stash: GitStash, on target: (serverId: String, worktree: PeerHostWorktree)) {
        guard stashFiles.removeValue(forKey: stash.ref) == nil, let hosts = client.hosts else { return }
        stashFiles[stash.ref] = .loading
        let key = gitTargetKey
        Task { @MainActor in
            let result = await hosts.stashFiles(stash, in: target.worktree, serverId: target.serverId)
            // Closed, or listed again as another stash, since it was asked for.
            guard gitTargetKey == key, stashFiles[stash.ref] != nil,
                  stashes?.first(where: { $0.ref == stash.ref })?.sha == stash.sha
            else { return }
            let load: NativePeerWorkspace.Load<[GitStashFile]> = switch result {
            case .success(let files): .loaded(files)
            case .failure(let error): .failed(error.message)
            }
            stashFiles[stash.ref] = load
        }
    }

    /// Changes when the git target's stashes should be listed again: a new
    /// target, the host serving stashes, or a reconnect.
    private var stashesKey: String? {
        guard let gitTarget, let gitTargetKey, let hosts = client.hosts,
              hosts.servesStash(serverId: gitTarget.serverId)
        else { return nil }
        return "\(gitTargetKey)#\(hosts.subscriptions[gitTarget.serverId] ?? 0)"
    }

    /// The git target's stashes. A refusal or no answer keeps the last list;
    /// an open stash whose ref now names another stash closes, as
    /// `RightPaneState.reconcileStashCaches` does. Only the latest read lands.
    private func readStashes() async {
        stashReadGeneration += 1
        let generation = stashReadGeneration
        guard stashesKey != nil, let gitTarget, let hosts = client.hosts else {
            stashes = nil
            stashFiles = [:]
            return
        }
        let key = gitTargetKey
        let listed = await hosts.stashes(in: gitTarget.worktree, serverId: gitTarget.serverId)
        guard !Task.isCancelled, generation == stashReadGeneration, gitTargetKey == key, let listed else { return }
        // The host's list is network input: a repeated ref must not trap.
        let previous = Dictionary((stashes ?? []).map { ($0.ref, $0.sha) }, uniquingKeysWith: { first, _ in first })
        let stable = Set(listed.filter { previous[$0.ref] == $0.sha }.map(\.ref))
        stashFiles = stashFiles.filter { stable.contains($0.key) }
        stashes = listed
        followOpenStashDiff(listed)
    }

    /// An open stash diff follows its stash as refs shift after a push, pop
    /// or drop, and closes once the stash is gone.
    private func followOpenStashDiff(_ listed: [GitStash]) {
        guard case .stashDiff(let path, let shown)? = client.workspace.document else { return }
        if let stash = listed.first(where: { $0.sha == shown.sha }) {
            if stash.ref != shown.ref { client.open(.stashDiff(path: path, stash: HostStashRef(stash))) }
        } else {
            client.closeDocument()
        }
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
        case .inspectReviewEvidence:
            if let number = reviewLoop.snapshot?.reviewRequest?.number { startProviderReview(number, on: gitTarget) }
        default:
            break // `peerServed` offers no other action.
        }
    }

    /// Opens or reuses the host's review of `number` and shows it; an error lands in `gitError`.
    private func startProviderReview(_ number: Int, on target: (serverId: String, worktree: PeerHostWorktree)) {
        guard let hosts = client.hosts else { return }
        gitError = nil
        let key = gitTargetKey
        Task { @MainActor in
            let result = await hosts.openProviderReview(number: number, in: target.worktree, serverId: target.serverId)
            // The selection moved on: the answer belongs to another worktree.
            guard gitTargetKey == key else { return }
            switch result {
            case .success(let review):
                client.openReview(review.summary.sessionID, serverId: target.serverId, worktree: target.worktree)
            case .failure(let error):
                gitError = error.message
            }
        }
    }

    /// The git target's pull or merge request, while the host serves its
    /// review and lists none of it yet.
    private func unlistedReviewRequest(serverId: String) -> ReviewRequest? {
        guard client.hosts?.servesProviderReviews(serverId: serverId) == true,
              let request = reviewLoop.snapshot?.reviewRequest
        else { return nil }
        let listed = reviews.contains {
            if case .reviewRequest(_, _, _, let number, _) = $0.record.target.payload { number == request.number } else { false }
        }
        return listed ? nil : request
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
            // Bounded, so a long review history scrolls instead of crowding
            // out the changes.
            ScrollView {
                VStack(spacing: 0) { reviewRows(target, localChanges: localChanges, listsLocalChanges: listsLocalChanges) }
            }
            .frame(maxHeight: 180)
        }
    }

    @ViewBuilder
    private func reviewRows(
        _ target: (serverId: String, worktree: PeerHostWorktree), localChanges: String, listsLocalChanges: Bool
    ) -> some View {
        if let request = unlistedReviewRequest(serverId: target.serverId) {
            let title = "Review \(request.provider.reviewRequestLabel) \(request.provider.reviewRequestNumberPrefix)\(request.number)"
            reviewRow(title: title, subtitle: nil, verdict: nil, openCount: 0) {
                startProviderReview(request.number, on: target)
            }
        }
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
    /// target, the host serving reviews, its `reviewsChanged`, or a reconnect.
    private var reviewsKey: String? {
        guard let gitTarget, let gitTargetKey, let hosts = client.hosts,
              hosts.servesReviews(serverId: gitTarget.serverId)
        else { return nil }
        let revision = hosts.reviewRevisions[gitTarget.serverId]?[gitTarget.worktree.snapshot.worktree.id] ?? 0
        let subscription = hosts.subscriptions[gitTarget.serverId] ?? 0
        return "\(gitTargetKey)#\(revision)#\(subscription)"
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

    /// The checkpoint list's reads, its create and restore sheets, and the delete confirmation.
    private func checkpointPrompts(_ content: some View) -> some View {
        content
        .task(id: checkpointsKey) { await readCheckpoints() }
        // "Restore files to before this request" in the peer transcript.
        .onChange(of: client.pendingCheckpointRestore) { _, requested in
            guard requested != nil, let id = client.takeCheckpointRestore() else { return }
            openTranscriptCheckpointRestore(id)
        }
        .sheet(isPresented: $creatingCheckpoint) {
            if let gitTarget {
                CreateCheckpointSheet(error: checkpointCreateError, disabled: checkpointInFlight) { label in
                    await createCheckpoint(label: label, on: gitTarget)
                }
            }
        }
        .sheet(item: $checkpointRestorePreview) { preview in
            if let gitTarget {
                RestoreCheckpointSheet(
                    preview: preview,
                    error: checkpointRestoreError,
                    inFlight: checkpointInFlight,
                    refresh: { await previewCheckpointRestore(preview.checkpointID, groupIDs: $0, on: gitTarget) },
                    restore: { await restoreCheckpoint(preview, groupIDs: $0, on: gitTarget) },
                    cancel: { checkpointRestorePreview = nil }
                )
            }
        }
        // The local copy: RightPaneView's checkpoint deletion dialog.
        .alert(
            "Delete checkpoint \(pendingCheckpointDeletion?.label ?? "")?",
            isPresented: Binding(
                get: { pendingCheckpointDeletion != nil },
                set: { if !$0 { pendingCheckpointDeletion = nil } }
            ),
            presenting: pendingCheckpointDeletion,
            actions: { checkpoint in
                Button("Delete", role: .destructive) {
                    pendingCheckpointDeletion = nil
                    if let gitTarget { runCheckpointChange(.deleteCheckpoint(id: checkpoint.id), on: gitTarget) }
                }
                Button("Cancel", role: .cancel) { pendingCheckpointDeletion = nil }
            },
            message: { _ in
                Text("This removes the checkpoint only. Your worktree is unchanged.")
            }
        )
    }

    @ViewBuilder
    private func checkpointsSection(
        _ target: (serverId: String, worktree: PeerHostWorktree), catalog: CheckpointCatalogSnapshot
    ) -> some View {
        SectionHeader(
            role: .checkpoints,
            title: "Checkpoints",
            count: catalog.summaries.count,
            expanded: checkpointsExpanded,
            onToggle: { checkpointsExpanded.toggle() }
        ) {
            Button {
                beginCheckpointCreation()
            } label: {
                Icon(name: "plus", size: 11, color: theme.color("fg-muted"))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(checkpointInFlight)
            .accessibilityLabel("Create checkpoint")
        }
        if checkpointsExpanded {
            // Bounded, as the reviews are.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(catalog.summaries) { checkpointCard($0, on: target) }
                    CheckpointFooterRow(storageUsage: catalog.byteCount)
                }
            }
            .frame(maxHeight: 240)
        }
    }

    private func checkpointCard(
        _ checkpoint: WorktreeCheckpointSummary, on target: (serverId: String, worktree: PeerHostWorktree)
    ) -> some View {
        let load = checkpointManifests[checkpoint.id]
        var manifest: WorktreeCheckpointManifest?
        var manifestError: String?
        if case .loaded(let loaded)? = load { manifest = loaded }
        if case .failed(let message)? = load { manifestError = message }
        let page = checkpointPages[checkpoint.id] ?? 0
        return CheckpointCard(
            checkpoint: checkpoint,
            expanded: load != nil,
            manifest: manifest,
            manifestLoading: load == .loading,
            manifestError: manifestError,
            mutationsDisabled: checkpointInFlight,
            blockedReason: nil,
            fileListPageIndex: page,
            onToggle: { toggleCheckpoint(checkpoint.id, on: target) },
            onPreviousFilePage: { checkpointPages[checkpoint.id] = max(0, page - 1) },
            onNextFilePage: { checkpointPages[checkpoint.id] = page + 1 },
            onRestore: { openCheckpointRestore(checkpoint.id, on: target) },
            onDelete: { pendingCheckpointDeletion = checkpoint },
            onInspect: { client.open(.checkpointDiff(path: $0.primaryPath, checkpointID: checkpoint.id)) }
        )
    }

    /// Changes when the git target's checkpoints should be listed again: a new
    /// target, the host serving checkpoints, or a reconnect.
    private var checkpointsKey: String? {
        guard let gitTarget, let gitTargetKey, let hosts = client.hosts,
              hosts.servesCheckpoints(serverId: gitTarget.serverId)
        else { return nil }
        return "\(gitTargetKey)#\(hosts.subscriptions[gitTarget.serverId] ?? 0)"
    }

    /// The git target's checkpoints. A refusal or no answer keeps the last
    /// list; an open checkpoint diff closes once its checkpoint is gone. Only
    /// the latest read lands.
    private func readCheckpoints() async {
        checkpointReadGeneration += 1
        let generation = checkpointReadGeneration
        guard checkpointsKey != nil, let gitTarget, let hosts = client.hosts else {
            checkpoints = nil
            checkpointManifests = [:]
            checkpointPages = [:]
            return
        }
        let key = gitTargetKey
        let listed = await hosts.checkpoints(in: gitTarget.worktree, serverId: gitTarget.serverId)
        guard !Task.isCancelled, generation == checkpointReadGeneration, gitTargetKey == key, let listed else { return }
        let ids = Set(listed.summaries.map(\.id))
        checkpointManifests = checkpointManifests.filter { ids.contains($0.key) }
        checkpointPages = checkpointPages.filter { ids.contains($0.key) }
        checkpoints = listed
        if case .checkpointDiff(_, let shown)? = client.workspace.document, !ids.contains(shown) {
            client.closeDocument()
        }
    }

    /// Opens or closes checkpoint `id`'s files; an open checkpoint is read on the host.
    private func toggleCheckpoint(_ id: CheckpointID, on target: (serverId: String, worktree: PeerHostWorktree)) {
        guard checkpointManifests.removeValue(forKey: id) == nil, let hosts = client.hosts else { return }
        checkpointManifests[id] = .loading
        let key = gitTargetKey
        Task { @MainActor in
            let result = await hosts.checkpointManifest(id, in: target.worktree, serverId: target.serverId)
            // Closed since it was asked for.
            guard gitTargetKey == key, checkpointManifests[id] != nil else { return }
            let load: NativePeerWorkspace.Load<WorktreeCheckpointManifest> = switch result {
            case .success(let manifest): .loaded(manifest)
            case .failure(let error): .failed(error.message)
            }
            checkpointManifests[id] = load
        }
    }

    private func beginCheckpointCreation() {
        checkpointCreateError = nil
        creatingCheckpoint = true
    }

    /// The new checkpoint, listed again; nil with `checkpointCreateError` set when it failed.
    private func createCheckpoint(
        label: String, on target: (serverId: String, worktree: PeerHostWorktree)
    ) async -> WorktreeCheckpointManifest? {
        guard let hosts = client.hosts, !checkpointInFlight else { return nil }
        checkpointInFlight = true
        checkpointCreateError = nil
        let key = gitTargetKey
        let result = await hosts.createCheckpoint(label: label, in: target.worktree, serverId: target.serverId)
        checkpointInFlight = false
        // The selection moved on: the answer belongs to another worktree.
        guard gitTargetKey == key else { return nil }
        Task { await readCheckpoints() }
        switch result {
        case .success(let manifest):
            return manifest
        case .failure(let error):
            checkpointCreateError = error.message
            return nil
        }
    }

    /// The transcript's restore: shows Changes, where the sheet's context and
    /// any refusal are visible, then opens the restore as the card does.
    private func openTranscriptCheckpointRestore(_ id: CheckpointID) {
        guard let gitTarget, client.hosts?.servesCheckpoints(serverId: gitTarget.serverId) == true else { return }
        let tabs = self.tabs
        // Not `resolve`: it collapses the pane when Changes is already shown.
        handle(collapsed ? .expand(.changes) : .select(.changes), tabs: tabs)
        guard !checkpointInFlight else {
            gitError = "A checkpoint action is already running."
            return
        }
        openCheckpointRestore(id, on: gitTarget)
    }

    /// Reads what restoring checkpoint `id` would change and shows it in the restore sheet.
    private func openCheckpointRestore(_ id: CheckpointID, on target: (serverId: String, worktree: PeerHostWorktree)) {
        gitError = nil
        checkpointRestoreError = nil
        let key = gitTargetKey
        Task { @MainActor in
            await previewCheckpointRestore(id, groupIDs: nil, on: target)
            // Before the sheet shows, its error lands in the rail.
            if gitTargetKey == key, checkpointRestorePreview == nil { gitError = checkpointRestoreError }
        }
    }

    /// Reads the restore preview again for `groupIDs`; a failure shows in the restore sheet.
    private func previewCheckpointRestore(
        _ id: CheckpointID, groupIDs: Set<UUID>?, on target: (serverId: String, worktree: PeerHostWorktree)
    ) async {
        guard let hosts = client.hosts, !checkpointInFlight else { return }
        checkpointInFlight = true
        let key = gitTargetKey
        let result = await hosts.checkpointRestorePreview(id, groupIDs: groupIDs, in: target.worktree, serverId: target.serverId)
        checkpointInFlight = false
        guard gitTargetKey == key else { return }
        switch result {
        case .success(let preview):
            checkpointRestoreError = nil
            checkpointRestorePreview = preview
        case .failure(let error):
            checkpointRestoreError = error.message
        }
    }

    /// Restores `groupIDs` as `preview` showed them; true once restored.
    private func restoreCheckpoint(
        _ preview: CheckpointRestorePreview, groupIDs: Set<UUID>, on target: (serverId: String, worktree: PeerHostWorktree)
    ) async -> Bool {
        guard let hosts = client.hosts, !checkpointInFlight else { return false }
        let unsaved = client.unsavedHostFilePaths(serverId: target.serverId, worktreeID: target.worktree.snapshot.worktree.id)
        if let refusal = NativePeerSessions.restoreRefusal(unsavedPaths: unsaved) {
            checkpointRestoreError = refusal
            return false
        }
        checkpointInFlight = true
        let key = gitTargetKey
        let change = HostWorktreeChange.restoreCheckpoint(
            id: preview.checkpointID, groupIDs: groupIDs, fingerprint: preview.currentFingerprint
        )
        let error = await hosts.mutate(change, in: target.worktree, serverId: target.serverId)
        checkpointInFlight = false
        guard gitTargetKey == key else { return false }
        client.reloadWorkspace()
        // The restore took a recovery checkpoint first.
        Task { await readCheckpoints() }
        checkpointRestoreError = error
        if error == nil { checkpointRestorePreview = nil }
        return error == nil
    }

    /// Runs a checkpoint `change`, then lists the checkpoints again.
    private func runCheckpointChange(_ change: HostWorktreeChange, on target: (serverId: String, worktree: PeerHostWorktree)) {
        runGit(change, on: target) { Task { await readCheckpoints() } }
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
                    onInterrupt: { client.stop(sessionId: $0) },
                    onFollowUp: nil,
                    onDelegate: nil
                ),
                controllableSessionIDs: client.selectedWorktreePeer?.state.carriesSessions == true
                    ? Set((client.selectedWorktreeGroup?.sessions ?? []).filter(\.isActive).map(\.id))
                    : [],
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
                    onFileHistory: fileHistoryAction.map { history in { history($0.path) } },
                    onCreateFile: { createHostFile(in: $0) },
                    onCreateFolder: { createHostFolder(in: $0) },
                    shouldAutoLoadChildren: { client.workspace.shouldLoadChildren(path: $0, childrenState: $1) },
                    onLoadChildren: { client.loadFileTreeChildren(path: $0) },
                    showIgnored: false,
                    revealPath: nil,
                    revealTick: 0,
                    onClearReveal: {},
                    bookmarkOpenPaths: $bookmarkOpenPaths,
                    readOnly: true,
                    createsOnPeer: client.hostFileTarget != nil
                )
            }
        }
    }

    /// Asks for a name and makes an empty file in `directory` on the host, then opens it.
    private func createHostFile(in directory: String) {
        guard let target = client.hostFileTarget, let hosts = client.hosts,
              let name = state.promptForChildName(title: "New File", defaultValue: "untitled.txt")
        else { return }
        let path = AppState.childPath(name: name, directoryPath: directory)
        Task {
            do {
                _ = try await hosts.writeFile(path, text: "", expected: nil, in: target.worktree, serverId: target.serverId)
            } catch RemoteFileAccessError.saveConflict {
                state.showFileActionError(title: "New File Failed", message: "\(path) already exists on the host.")
                return
            } catch {
                state.showFileActionError(title: "New File Failed", message: error.localizedDescription)
                return
            }
            // Another worktree selected meanwhile: opening `path` there would show a different file.
            guard let current = client.hostFileTarget, current.serverId == target.serverId,
                  current.worktree.snapshot.worktree.id == target.worktree.snapshot.worktree.id
            else { return }
            // A root reload also re-lists every expanded folder; a loaded folder alone won't list again.
            client.reloadWorkspace()
            client.open(.file(path: path))
        }
    }

    /// Asks for a name and makes a folder in `directory` on the host.
    private func createHostFolder(in directory: String) {
        guard let target = client.hostFileTarget, let hosts = client.hosts,
              let name = state.promptForChildName(title: "New Folder", defaultValue: "New Folder")
        else { return }
        let path = AppState.childPath(name: name, directoryPath: directory)
        Task {
            if let error = await hosts.createFolder(path, in: target.worktree, serverId: target.serverId) {
                state.showFileActionError(title: "New Folder Failed", message: error)
                return
            }
            client.reloadWorkspace()
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
    private var gitTarget: (serverId: String, worktree: PeerHostWorktree)? { client.hostGitTarget }

    /// Opens a path's history; nil, disabling File History, on a host that doesn't serve it.
    private var fileHistoryAction: ((String) -> Void)? {
        client.hostHistoryTarget == nil ? nil : { client.openFileHistory(path: $0) }
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

private enum IntegrateKind {
    case merge, rebase
}
