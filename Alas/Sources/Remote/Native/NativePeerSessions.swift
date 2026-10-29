import Foundation
import Observation

/// Native, app-scoped consumer of the existing federated session feed.
@MainActor @Observable
final class NativePeerSessions {
    private let federation: FederatedSessionsProvider
    private let peers: @MainActor () -> [RemoteHelloPeer]
    private let comparisonMode: @MainActor () -> AppConfig.Changes.ChangesComparisonMode?
    /// Whether a peer holds a worktree create for its repo hook instead of
    /// deciding it there.
    private let supportsRepoHookApproval: @MainActor (_ serverId: String) -> Bool
    /// Asks this Mac's user about a hook a peer holds a create for.
    private let decideRepoHook: @MainActor (_ serverId: String, PeerRepoHook, RepoHookApprovalContext) async
        -> RepoHookApprovalDecision
    /// Peer consoles. Selecting one clears the selected session and vice
    /// versa, so the center pane shows exactly one peer surface.
    let consoles: NativePeerConsoles?
    /// Peers' worktrees over the host channel, for peers that serve it.
    let hosts: NativePeerHosts?
    @ObservationIgnored private var downstream: FederatedDownstream?
    @ObservationIgnored private var promptCompletion: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var pendingPromptExpectedIndex: Int?
    private(set) var isFetchingOlderMessages = false
    private(set) var pendingPrompt: PendingPrompt?
    /// Queue items matching the pending prompt at send time, so only a new
    /// item (not a re-pushed older duplicate) confirms the send.
    @ObservationIgnored private var pendingPromptPriorQueueIds: Set<String> = []

    @ObservationIgnored private var suspendedPrompts: [String: SuspendedPrompt] = [:]
    @ObservationIgnored private var composerErrors: [String: String] = [:]

    private struct SuspendedPrompt {
        let prompt: PendingPrompt
        let expectedIndex: Int?
        let priorQueueIds: Set<String>
        var replayEpoch: Int?
        var needsResubscribe = false
        let completion: (@MainActor (Bool) -> Void)?
        /// The session's latest agent issue, for the rejection's reason.
        var agentIssue: RemoteAgentIssue?

        func isConfirmed(by message: RemoteServerMessage) -> Bool {
            switch message {
            case .queueState(_, let items):
                return items.contains { prompt.matches($0) && !priorQueueIds.contains($0.id) }
            case .transcriptSnapshot(_, _, _, let rows, _, _, _, _, _),
                 .transcriptDelta(_, _, _, let rows, _, _, _):
                guard let expectedIndex else { return false }
                return rows.contains { prompt.matches($0) && $0.index >= expectedIndex }
            default: return false
            }
        }
    }

    /// A sent prompt awaiting the host's confirmation, as the host will
    /// echo it back in a queue item or a transcript user row.
    struct PendingPrompt: Equatable {
        let text: String
        let attachments: [NativePeerAttachment]
        let composerDraft: ACPComposerDraft
        let composerRevision: Int
        let epoch: Int?
        var mentions: [RemoteMention] = []

        func matches(_ item: RemoteQueuedPrompt) -> Bool {
            item.text == text && item.imageCount == attachments.count && item.resourceCount == mentions.count
        }

        /// The host lists images, then mentions, under the user's text.
        func matches(_ row: RemoteWireMessage) -> Bool {
            row.kind == "user" && row.text == RemoteSessionGateway.userRowText(
                text: text,
                attachmentNames: attachments.map(\.name),
                resourceNames: mentions.map { String($0.name.prefix(RemoteMentions.maxNameLength)) })
        }
    }

    private(set) var snapshot = NativePeerSidebarSnapshot(groups: [], attentionRows: []) {
        didSet { if hasGroups != !snapshot.groups.isEmpty { hasGroups.toggle() } }
    }
    /// Whether any peer is listed. Views that only need this read it instead
    /// of `snapshot`, which changes on every streamed session update.
    private(set) var hasGroups = false
    /// The peer worktree shown in the center pane. Set with no selected tab
    /// when the worktree has none open.
    private(set) var selectedWorktree: NativePeerWorktreeSelection?
    /// The selected worktree's tabs as of the last snapshot, so a tab the
    /// host closes can be replaced by its neighbour.
    @ObservationIgnored private var selectedWorktreeTabs: [NativePeerTab] = []
    /// The tab last used in each worktree during this app run.
    @ObservationIgnored private var lastTabs: [NativePeerWorktreeSelection: NativePeerTab] = [:]
    /// The attached tab: only this session is subscribed, only this console
    /// has a viewer.
    private(set) var selectedSessionId: String?
    private(set) var transcript: NativePeerTranscript?
    @ObservationIgnored private var composerStates: [String: ACPComposerState] = [:]

    func composerState(for sessionId: String) -> ACPComposerState {
        // Federated session IDs already include their peer's identity.
        let key = sessionId
        if let state = composerStates[key] { return state }
        let state = ACPComposerState()
        composerStates[key] = state
        return state
    }

    var draft = "" {
        didSet {
            guard let selectedSessionId else { return }
            let composer = composerState(for: selectedSessionId)
            let current = composer.draft
            guard current.plainText != draft else { return }
            if !current.isEmpty, draft.hasPrefix(current.plainText) {
                let suffix = String(draft.dropFirst(current.plainText.count))
                composer.replaceDraft(.init(segments: current.segments + [.text(suffix)]))
            } else {
                composer.replaceDraft(.init(segments: draft.isEmpty ? [] : [.text(draft)]))
            }
        }
    }
    /// Images staged for the next prompt. Kept, like the draft, until the
    /// host confirms the send.
    private(set) var attachments: [NativePeerAttachment] = []
    /// Mentions picked for the next prompt. One whose `@name` the user
    /// deletes from the draft is left out of the send.
    private(set) var mentions: [RemoteMention] = []
    /// The host's answer to the latest `searchMentions`.
    private(set) var mentionCandidates: [RemoteMention] = []
    /// The query `mentionCandidates` answers. It trails the typed query
    /// until the host replies, and a pick must wait for it to catch up.
    private(set) var mentionCandidatesQuery: String?
    /// The query whose answer `mentionCandidates` waits for; older answers
    /// are dropped.
    @ObservationIgnored private var mentionQuery: String?
    /// Queue Edit text the host restored after the user left that session,
    /// put back into the draft when the session is selected again.
    @ObservationIgnored private var restoredDrafts: [String: String] = [:]
    private(set) var deliveryError: String?
    static let peerUnavailableMessage = FederatedSessionsProvider.peerUnavailableMessage
    private(set) var newSession: NativePeerNewSession?
    /// Session tabs the host was asked to close. Each stays in the strip
    /// until the host's session list drops it, or the host refuses.
    private(set) var closingSessionIds: Set<String> = []
    /// Why the host refused the last tab close, until dismissed. Separate
    /// from `sessionTabError`, which the Agent rail shows for opens.
    var tabCloseError: String?
    /// A session the peer just created or opened for us, selected once the
    /// peer's session list reports it as an open tab.
    @ObservationIgnored private var pendingSessionId: String?
    /// Why the peer refused to open a tab.
    private(set) var sessionTabError: String?
    /// Open requests awaiting the peer's reply, per session. Replies arrive
    /// in request order, so only the last one answers the current attempt.
    @ObservationIgnored private var tabOpensInFlight: [String: Int] = [:]
    private(set) var workspace = NativePeerWorkspace()
    /// Host files' editor buffers, created as their editor first shows.
    @ObservationIgnored private var hostFileBuffers: [NativePeerHostFile: EditorBuffer] = [:] {
        didSet { hostFileBufferRevision &+= 1 }
    }
    /// Observable stand-in for `hostFileBuffers`' membership, which changes while views render.
    private var hostFileBufferRevision = 0
    /// Why a host refused to follow a file it served: the file opens read-only.
    private var hostFileRefusals: [NativePeerHostFile: String] = [:]
    /// A host review opened over the center pane, as a document is.
    private(set) var openedReview: NativePeerReviewSelection?
    /// A host commit opened in the commit editor over the center pane.
    private(set) var openedCommitEditor: NativePeerCommitEditorSelection?
    /// A checkpoint the transcript asked to restore, until the right pane takes it.
    private(set) var pendingCheckpointRestore: CheckpointID?
    /// The selected row's worktree summary when changes were last requested.
    /// Peers re-send it with every session list, so a change here is the
    /// cue that the agent touched the worktree.
    @ObservationIgnored private var workspaceSummary: RemoteWorktreeSummary?
    /// The selected group's host record when changes were last requested: a
    /// change to it is the cue to re-read an idle worktree.
    @ObservationIgnored private var workspaceHostSnapshot: WorktreeSnapshot?
    /// Bumped whenever the workspace is reset, so a host-channel answer to a
    /// read sent before then is dropped.
    @ObservationIgnored private var workspaceEpoch = 0
    /// Whether a root `listFiles` request is currently awaiting a reply.
    /// `workspace.beginRootLoad()` only distinguishes "never loaded" from
    /// "loaded"; once loaded it permits sending on every call, so this is
    /// the only thing that stops a second refresh from racing the first
    /// past the peer's in-flight request dedup, which would silently drop it.
    @ObservationIgnored private var fileTreeRequestInFlight = false
    /// Set when a summary change asks for the root file tree while one is
    /// already in flight — either blocked by `beginRootLoad()` returning
    /// false (never loaded yet) or by `fileTreeRequestInFlight` (already
    /// loaded, refreshing). Without this the reply that eventually lands
    /// would look current even though a later edit already invalidated it.
    /// Cleared once the retry it queues has been sent.
    @ObservationIgnored private var fileTreeRequestOutdated = false
    /// Same pair as `fileTreeRequestInFlight`/`fileTreeRequestOutdated`, for
    /// `listChanges`: `requestChanges()` has no equivalent to
    /// `beginRootLoad()`'s loaded/not-loaded gate, so without this every
    /// summary change would fire its own request and the peer's in-flight
    /// dedup would silently drop all but the first.
    @ObservationIgnored private var changesRequestInFlight = false
    @ObservationIgnored private var changesRequestOutdated = false
    /// Documents (by their own identity, not just "the open one") with a
    /// `readFile`/`fileDiff` request currently outstanding. Keyed per
    /// document, not a single flag, because switching away from a document
    /// before its reply arrives and then back to it (A→B→A) leaves that
    /// original request outstanding on the peer under the same dedup key a
    /// fresh one would use — a single scalar can't tell "opening A is a
    /// brand-new request" from "opening A again means waiting on the one
    /// still out there."
    @ObservationIgnored private var documentRequestsInFlight: Set<NativePeerWorkspace.Document> = []
    /// Set when the *currently open* document's request is skipped because
    /// one is already in `documentRequestsInFlight`. Cleared once the retry
    /// it queues has been sent.
    @ObservationIgnored private var documentRequestOutdated = false

    init(
        federation: FederatedSessionsProvider,
        peers: @escaping @MainActor () -> [RemoteHelloPeer],
        comparisonMode: @escaping @MainActor () -> AppConfig.Changes.ChangesComparisonMode? = { nil },
        consoles: NativePeerConsoles? = nil,
        hosts: NativePeerHosts? = nil,
        supportsRepoHookApproval: @escaping @MainActor (_ serverId: String) -> Bool = { _ in false },
        decideRepoHook: @escaping @MainActor (_ serverId: String, PeerRepoHook, RepoHookApprovalContext) async
            -> RepoHookApprovalDecision = { _, _, _ in .skip }
    ) {
        self.federation = federation
        self.peers = peers
        self.comparisonMode = comparisonMode
        self.supportsRepoHookApproval = supportsRepoHookApproval
        self.decideRepoHook = decideRepoHook
        self.consoles = consoles
        self.hosts = hosts
        consoles?.onListChanged = { [weak self] in self?.rebuildSnapshot() }
        consoles?.onOpened = { [weak self] in self?.selectConsole(serverId: $0, consoleId: $1) }
        hosts?.onChange = { [weak self] in self?.rebuildSnapshot() }
        hosts?.onRunsChanged = { [weak consoles] in consoles?.refresh(serverId: $0) }
    }

    /// Only the sidebar model: console lists change nothing a selected
    /// session depends on, so the rest of `refresh()` is not needed.
    private func rebuildSnapshot() {
        guard downstream != nil else { return }
        snapshot = .build(
            peers: peers(), rows: federation.peerSessionSummaries,
            consoles: consoles?.consoles ?? [:], projects: federation.peerProjects,
            hostWorktrees: hosts?.worktrees ?? [:]
        )
        let openSessionIds = Set(snapshot.groups.flatMap(\.sessions).filter(\.isActive).map(\.id))
        closingSessionIds.formIntersection(openSessionIds)
        reconcileSelectedTab()
        guard selectedTab == nil else { return }
        if !canReadWorkspace {
            // The host channel is not ready (yet, or any more): read the
            // worktree again once it is.
            workspaceHostSnapshot = nil
        } else if selectedWorktreeGroup?.host?.snapshot != workspaceHostSnapshot {
            // Ready again, or the host changed the worktree. `requestChanges`
            // records the snapshot, so this reloads once per change.
            reloadWorkspace()
        }
    }

    var selectedTab: NativePeerTab? {
        if let selectedSessionId { return .session(selectedSessionId) }
        return consoles?.viewer.map { .console($0.consoleId) }
    }

    /// Whether a peer worktree or tab covers the center pane. The local
    /// selection stays set underneath but is not what the user sees.
    var coversCenterPane: Bool { selectedWorktree != nil || selectedTab != nil }

    private func worktrees(on serverId: String) -> [NativePeerWorktreeGroup] {
        snapshot.groups.first { $0.serverId == serverId }?.repos(ordering: .manual).flatMap(\.worktrees) ?? []
    }

    private func worktree(_ selection: NativePeerWorktreeSelection) -> NativePeerWorktreeGroup? {
        worktrees(on: selection.serverId).first { $0.id == selection.worktreeId }
    }

    /// Opens the tab last used in the worktree, else its first tab, else
    /// nothing: the center pane shows the worktree's empty state.
    func selectWorktree(_ selection: NativePeerWorktreeSelection) {
        guard let worktree = worktree(selection) else { return }
        openedReview = nil
        openedCommitEditor = nil
        let tabs = worktree.tabs
        if let tab = lastTabs[selection].flatMap({ tabs.contains($0) ? $0 : nil }) ?? tabs.first {
            selectTab(tab, in: selection)
        } else {
            clearSelection()
            selectedWorktree = selection
            reloadWorkspace()
        }
    }

    /// Selects the worktree the host knows as `worktreeID`, as a worktree
    /// notice's click does. Nothing happens once the host no longer lists it,
    /// or while it is already selected: re-selecting its tab would toggle it.
    func selectHostWorktree(serverId: String, worktreeID: String) {
        guard let group = worktrees(on: serverId).first(where: { $0.peerWorktreeId == worktreeID }) else { return }
        let selection = NativePeerWorktreeSelection(serverId: serverId, worktreeId: group.id)
        guard selectedWorktree != selection else { return }
        selectWorktree(selection)
    }

    func selectTab(_ tab: NativePeerTab, in selection: NativePeerWorktreeSelection) {
        switch tab {
        case .session(let id): select(id)
        case .console(let id): selectConsole(serverId: selection.serverId, consoleId: id)
        }
    }

    /// Points the worktree selection at whichever worktree holds `tab`.
    private func noteSelected(_ tab: NativePeerTab, serverId: String) {
        let worktree = worktrees(on: serverId).first { group in
            switch tab {
            case .session(let id): group.sessions.contains { $0.id == id }
            case .console(let id): group.consoles.contains { $0.consoleId == id }
            }
        }
        guard let worktree else { return }
        let selection = NativePeerWorktreeSelection(serverId: serverId, worktreeId: worktree.id)
        selectedWorktree = selection
        selectedWorktreeTabs = worktree.tabs
        if selectedWorktreeTabs.contains(tab) { lastTabs[selection] = tab }
    }

    /// Follows the host closing tabs in the selected worktree.
    private func reconcileSelectedTab() {
        guard let selection = selectedWorktree,
              snapshot.groups.first(where: { $0.serverId == selection.serverId })?.state.carriesSessions == true
        else { return }
        let selected = selectedTab
        // Until the peer's console list arrives, its consoles are unknown, not closed.
        if case .console = selected, consoles?.consoles[selection.serverId] == nil { return }
        let current: [NativePeerTab]
        if let worktree = worktree(selection) {
            current = worktree.tabs
        } else if case .console = selected {
            // The console list is known (checked above), so its last console closed.
            current = []
        } else if selected == nil, hosts?.worktrees[selection.serverId] != nil {
            // The host lists every worktree: an idle one it no longer lists
            // was removed or archived.
            selectedWorktree = nil
            selectedWorktreeTabs = []
            return
        } else {
            // Missing session rows mean the peer's list dropped, not that its
            // tabs closed; `refresh()` marks the selection unavailable.
            return
        }
        let previous = selectedWorktreeTabs
        selectedWorktreeTabs = current
        let next = NativePeerWorktreeGroup.reconciledTab(selected, previous: previous, current: selectedWorktreeTabs)
        guard next != selected else { return }
        if let next {
            selectTab(next, in: selection)
        } else {
            clearSelection()
            selectedWorktree = selection
        }
    }

    var selectedWorktreeGroup: NativePeerWorktreeGroup? {
        selectedWorktree.flatMap(worktree)
    }

    /// Whether Changes and Files can load: a session is selected, or the
    /// selected worktree has no tab open and its host serves worktree reads.
    var canReadWorkspace: Bool { selectedSessionId != nil || hostReadTarget != nil }

    /// The worktree Changes and Files show.
    var workspaceWorktreePath: String? {
        (selectedRow?.worktree ?? selectedWorktreeGroup?.worktree)?.path
    }

    /// The selected worktree on a host that serves its git actions. A folder
    /// project or an archived worktree has none.
    var hostGitTarget: (serverId: String, worktree: PeerHostWorktree)? {
        guard let selectedWorktree, let group = selectedWorktreeGroup, !group.isFolder, let host = group.host,
              !host.snapshot.isArchived, hosts?.servesGit(serverId: selectedWorktree.serverId) == true
        else { return nil }
        return (selectedWorktree.serverId, host)
    }

    /// The selected worktree on a host that edits its files: folder projects included, archived ones not.
    var hostFileTarget: (serverId: String, worktree: PeerHostWorktree)? {
        guard let selectedWorktree, let host = selectedWorktreeGroup?.host, !host.snapshot.isArchived,
              hosts?.servesFiles(serverId: selectedWorktree.serverId) == true
        else { return nil }
        return (selectedWorktree.serverId, host)
    }

    /// The open `.file` document on `hostFileTarget`, while documents show and no review or commit covers them.
    private var hostFileDocument: NativePeerHostFile? {
        guard canReadWorkspace, openedReview == nil, openedCommitEditor == nil, let target = hostFileTarget,
              case .file(let path)? = workspace.document
        else { return nil }
        return NativePeerHostFile(serverId: target.serverId, worktree: target.worktree, path: path)
    }

    /// The open `.file` document, once the host served it as text with a version, on `hostFileTarget`. A dirty
    /// buffer keeps it after the file is gone, so its deleted-on-disk banner and Keep mine stay reachable.
    var openedHostFile: NativePeerHostFile? {
        guard let file = hostFileDocument, hostFileRefusals[file] == nil,
              workspace.documentVersion != nil || hostFileBuffers[file]?.dirty == true
        else { return nil }
        return file
    }

    /// Why the open `.file` document, loaded as text on a host that edits files, stays read-only.
    var hostFileReadOnlyNote: String? {
        guard let file = hostFileDocument, case .loaded(.text(_, _)) = workspace.documentContent else { return nil }
        if let refusal = hostFileRefusals[file] { return "Read-only: \(refusal)" }
        return workspace.documentVersion == nil ? "Read-only: the host doesn't save this file from a paired Mac." : nil
    }

    /// Created on first use, watching; kept while dirty after its view closes. Nil without a host channel.
    func hostFileBuffer(for file: NativePeerHostFile) -> EditorBuffer? {
        if let buffer = hostFileBuffers[file] { return buffer }
        guard let hosts else { return nil }
        let buffer = EditorBuffer(
            hostWorktreeRoot: URL(fileURLWithPath: file.worktree.snapshot.worktree.path.path),
            relativePath: file.path,
            backend: hosts.hostFileBackend(in: file.worktree, serverId: file.serverId) { [weak self] refusal in
                self?.hostFileRefusals[file] = refusal
            }
        )
        buffer.startWatching()
        hostFileBuffers[file] = buffer
        return buffer
    }

    /// Closes and forgets `file`'s buffer unless it is dirty.
    // ponytail: dirty host buffers live until the app quits (which asks about them), with no hot-exit.
    func releaseHostFileBuffer(_ file: NativePeerHostFile) {
        guard let buffer = hostFileBuffers[file], !buffer.dirty else { return }
        hostFileBuffers[file] = nil
        buffer.close(persistDirtySnapshot: false)
    }

    /// Whether any host file has edits not saved yet; observes typing, for command enablement.
    var hasUnsavedHostFiles: Bool {
        _ = hostFileBufferRevision
        var result = false
        for buffer in hostFileBuffers.values {
            _ = buffer.editGeneration
            if buffer.dirty { result = true }
        }
        return result
    }

    /// Closes the buffers kept only for their unsaved edits once those are saved (Save All).
    func releaseSavedHiddenHostFileBuffers() {
        for file in hostFileBuffers.keys where file != hostFileDocument {
            releaseHostFileBuffer(file)
        }
    }

    /// Host files with edits not saved yet, with their host's name.
    var unsavedHostFiles: [(file: NativePeerHostFile, hostName: String, buffer: EditorBuffer)] {
        hostFileBuffers.filter { $0.value.dirty }.map { file, buffer in
            (file: file, hostName: snapshot.groups.first { $0.serverId == file.serverId }?.name ?? file.serverId, buffer: buffer)
        }
    }

    /// Dirty host buffers of `worktreeID` on `serverId`, by path, sorted.
    func unsavedHostFilePaths(serverId: String, worktreeID: String) -> [String] {
        hostFileBuffers.filter { file, buffer in
            buffer.dirty && file.serverId == serverId && file.worktree.snapshot.worktree.id == worktreeID
        }.map(\.key.path).sorted()
    }

    /// "Save or discard unsaved edits to <paths> before restoring.", or nil when `paths` is empty.
    static func restoreRefusal(unsavedPaths paths: [String]) -> String? {
        paths.isEmpty ? nil : "Save or discard unsaved edits to \(paths.joined(separator: ", ")) before restoring."
    }

    func saveOpenedHostFile() {
        guard let file = openedHostFile, let buffer = hostFileBuffers[file] else { return }
        Task { try? await buffer.saveRecordingErrorAwaitingRemote() }
    }

    func revertOpenedHostFile() {
        guard let file = openedHostFile else { return }
        hostFileBuffers[file]?.revert()
    }

    /// The selected worktree on a host that serves file bytes, whether or not a tab is open: only the host
    /// channel carries them.
    var hostBytesTarget: (serverId: String, worktree: PeerHostWorktree)? {
        guard let selectedWorktree, let host = selectedWorktreeGroup?.host,
              hosts?.servesFileBytes(serverId: selectedWorktree.serverId) == true
        else { return nil }
        return (selectedWorktree.serverId, host)
    }

    /// The selected tab-less worktree, read over its host's channel.
    private var hostReadTarget: (serverId: String, worktree: PeerHostWorktree)? {
        guard selectedTab == nil, let selectedWorktree, let host = selectedWorktreeGroup?.host,
              hosts?.canRead(serverId: selectedWorktree.serverId) == true
        else { return nil }
        return (selectedWorktree.serverId, host)
    }

    var selectedWorktreePeer: NativePeerGroup? {
        guard let selectedWorktree else { return nil }
        return snapshot.groups.first { $0.serverId == selectedWorktree.serverId }
    }

    /// Whether the peer serves `openSessionTab`, so a history session can be
    /// opened from here.
    func canOpenSessionTabs(serverId: String) -> Bool {
        federation.peerSupports(PeerSessionTabsCapability.v1, serverId: serverId)
    }

    /// Selects an open session's tab, or asks the peer to open a history
    /// session and selects it once the peer lists it as open.
    func openSession(_ sessionId: String) {
        guard let downstream,
              let row = snapshot.groups.lazy.flatMap(\.sessions).first(where: { $0.id == sessionId })
        else { return }
        sessionTabError = nil
        if row.isActive {
            // `select` skips `clearSelection` for the session already shown.
            pendingSessionId = nil
            select(sessionId)
            return
        }
        pendingSessionId = sessionId
        // Counted first: a peer without the capability is refused inside `route`.
        tabOpensInFlight[sessionId, default: 0] += 1
        if !federation.route(.openSessionTab(sessionId: sessionId), from: downstream) {
            tabOpensInFlight[sessionId, default: 1] -= 1
            pendingSessionId = nil
            sessionTabError = Self.peerUnavailableMessage
        }
    }

    var selectedRow: RemoteSessionSummary? {
        guard let selectedSessionId else { return nil }
        return snapshot.groups.flatMap(\.sessions).first { $0.id == selectedSessionId }
    }

    var isPromptPending: Bool { pendingPrompt != nil }

    /// The selected session's shepherd pill on its host.
    var selectedShepherd: HostSessionShepherd? {
        guard let selectedSessionId,
              let id = RemoteFederatedSessionID.parse(selectedSessionId, peers: Set(snapshot.groups.map(\.serverId)))
        else { return nil }
        return hosts?.shepherds[id.serverId]?[id.sessionId]
    }

    var selectedPeer: NativePeerGroup? {
        guard let selectedSessionId else { return nil }
        return snapshot.groups.first { selectedSessionId.hasPrefix($0.serverId + ":") }
    }

    func start() {
        guard downstream == nil else { return }
        let client = FederatedDownstream(
            send: { [weak self] message in self?.receive(message) },
            sessionListChanged: { [weak self] in self?.refresh() }
        )
        downstream = client
        federation.attach(client)
        consoles?.start()
        refresh()
        _ = federation.route(.listSessions, from: client)
    }

    func stop() {
        if let downstream {
            if let selectedSessionId {
                _ = federation.route(.unsubscribe(sessionId: selectedSessionId), from: downstream)
            }
            federation.detach(downstream)
        }
        downstream = nil
        consoles?.stop()
        hosts?.stop()
        for buffer in hostFileBuffers.values { buffer.close(persistDirtySnapshot: false) }
        hostFileBuffers = [:]
        hostFileRefusals = [:]
        selectedWorktree = nil
        selectedWorktreeTabs = []
        openedReview = nil
        openedCommitEditor = nil
        selectedSessionId = nil
        transcript = nil
        snapshot = .init(groups: [], attentionRows: [])
        draft = ""
        attachments = []
        resetMentions()
        restoredDrafts = [:]
        composerStates = [:]
        suspendedPrompts = [:]
        composerErrors = [:]
        pendingPrompt = nil
        promptCompletion = nil
        pendingPromptExpectedIndex = nil
        isFetchingOlderMessages = false
        deliveryError = nil
        sessionTabError = nil
        tabOpensInFlight = [:]
        newSession = nil
        pendingSessionId = nil
        closingSessionIds = []
        tabCloseError = nil
        workspace = NativePeerWorkspace()
        workspaceSummary = nil
        workspaceHostSnapshot = nil
        workspaceEpoch += 1
        fileTreeRequestOutdated = false
        changesRequestInFlight = false
        changesRequestOutdated = false
        documentRequestsInFlight = []
        documentRequestOutdated = false
        fileTreeRequestInFlight = false
    }

    private func resubscribeSuspendedPrompts() {
        guard let downstream else { return }
        for sessionId in Array(suspendedPrompts.keys) {
            guard suspendedPrompts[sessionId]?.needsResubscribe == true,
                  snapshot.groups.contains(where: { group in
                      group.state.carriesSessions && group.sessions.contains { $0.id == sessionId && $0.isActive }
                  }) else { continue }
            suspendedPrompts[sessionId]?.needsResubscribe = false
            if !federation.route(.subscribe(sessionId: sessionId), from: downstream) {
                suspendedPrompts[sessionId]?.needsResubscribe = true
            }
        }
    }

    func refresh() {
        guard downstream != nil else { return }
        rebuildSnapshot()
        resubscribeSuspendedPrompts()
        let online = Set(snapshot.groups.filter(\.state.carriesSessions).map(\.serverId))
        consoles?.peersChanged(online: online)
        hosts?.peersChanged(online: online)
        reconcileNewSession()
        if let pending = pendingSessionId,
           snapshot.groups.contains(where: { $0.sessions.contains { $0.id == pending && $0.isActive } }) {
            pendingSessionId = nil
            select(pending)
            return
        }
        guard selectedSessionId != nil else { return }
        guard let group = selectedPeer else {
            clearSelection()
            return
        }
        if !group.state.carriesSessions || selectedRow == nil {
            transcript?.markUnavailable()
            isFetchingOlderMessages = false
            workspace.markUnavailable()
        } else if transcript?.isClosed == true, let selectedSessionId, let downstream {
            // The provider discarded subscriptions when this peer went away.
            // Its new transcript may also have a lower epoch after a restart.
            transcript = NativePeerTranscript(sessionId: selectedSessionId)
            // Keep delivery markers: the re-subscription replays the host's
            // transcript and queue and can still confirm a routed prompt.
            isFetchingOlderMessages = false
            _ = federation.route(.subscribe(sessionId: selectedSessionId), from: downstream)
            // Preserved across the reset below: losing it would silently
            // drop the center pane back to the transcript on every
            // reconnect, discarding whatever the user had open.
            let openDocument = workspace.document
            workspace = NativePeerWorkspace()
            // Whatever was in flight before the peer went away will never
            // get a reply now — without this, reloadWorkspace() below would
            // find both still "in flight" and gate its own fresh requests.
            changesRequestInFlight = false
            changesRequestOutdated = false
            fileTreeRequestInFlight = false
            fileTreeRequestOutdated = false
            documentRequestsInFlight = []
            documentRequestOutdated = false
            reloadWorkspace()
            if let openDocument { open(openDocument) }
        } else if selectedRow?.worktree != workspaceSummary {
            // The summary only signals that the peer's worktree changed, not
            // which files — a rename or delete only shows up by re-listing.
            reloadWorkspace()
        }
    }

    func select(_ sessionId: String) {
        guard let downstream,
              let peer = snapshot.groups.first(where: { group in
                  group.state.carriesSessions && group.sessions.contains { $0.id == sessionId }
              }) else { return }
        if selectedSessionId == sessionId {
            workspace.closeDocument()
            openedReview = nil
            openedCommitEditor = nil
            refresh()
            return
        }
        clearSelection()
        noteSelected(.session(sessionId), serverId: peer.serverId)
        selectedSessionId = sessionId
        let saved = composerState(for: sessionId).draft.plainText
        draft = restoredDrafts.removeValue(forKey: sessionId).map { Self.appending($0, to: saved) } ?? saved
        let suspended = suspendedPrompts.removeValue(forKey: sessionId)
        pendingPrompt = suspended?.prompt
        pendingPromptExpectedIndex = suspended?.expectedIndex
        pendingPromptPriorQueueIds = suspended?.priorQueueIds ?? []
        promptCompletion = suspended?.completion
        deliveryError = composerErrors.removeValue(forKey: sessionId)
        attachments = suspended?.prompt.attachments ?? []
        resetMentions()
        mentions = suspended?.prompt.mentions ?? []
        transcript = NativePeerTranscript(sessionId: sessionId)
        _ = federation.route(.subscribe(sessionId: sessionId), from: downstream)
        reloadWorkspace()
    }

    func selectConsole(serverId: String, consoleId: String) {
        if let viewer = consoles?.viewer, viewer.serverId == serverId, viewer.consoleId == consoleId,
           !viewer.isEnded { return }
        clearSelection()
        noteSelected(.console(consoleId), serverId: serverId)
        consoles?.select(serverId: serverId, consoleId: consoleId)
    }

    func clearSelection() {
        selectedWorktree = nil
        openedReview = nil
        openedCommitEditor = nil
        pendingCheckpointRestore = nil
        selectedWorktreeTabs = []
        consoles?.clearSelection()
        if let selectedSessionId, let pendingPrompt {
            suspendedPrompts[selectedSessionId] = SuspendedPrompt(
                prompt: pendingPrompt, expectedIndex: pendingPromptExpectedIndex,
                priorQueueIds: pendingPromptPriorQueueIds, replayEpoch: transcript?.epoch ?? pendingPrompt.epoch,
                needsResubscribe: transcript?.isClosed != false,
                completion: promptCompletion, agentIssue: transcript?.config?.agentIssue)
        }
        if let selectedSessionId, let downstream, pendingPrompt == nil {
            _ = federation.route(.unsubscribe(sessionId: selectedSessionId), from: downstream)
        }
        selectedSessionId = nil
        // Any explicit navigation away (another peer session, a local
        // worktree) outranks auto-selecting a session created earlier.
        pendingSessionId = nil
        transcript = nil
        draft = ""
        attachments = []
        resetMentions()
        pendingPrompt = nil
        promptCompletion = nil
        pendingPromptExpectedIndex = nil
        isFetchingOlderMessages = false
        deliveryError = nil
        sessionTabError = nil
        workspace = NativePeerWorkspace()
        workspaceSummary = nil
        workspaceHostSnapshot = nil
        workspaceEpoch += 1
        fileTreeRequestOutdated = false
        changesRequestInFlight = false
        changesRequestOutdated = false
        documentRequestsInFlight = []
        documentRequestOutdated = false
        fileTreeRequestInFlight = false
    }

    /// The shared rich editor stages chips locally; only their wire payloads
    /// are installed here after the whole prompt has passed validation.
    func sendComposerPrompt(
        images: [NativePeerAttachment], mentions: [RemoteMention], intent: ACPSubmitIntent,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> Bool {
        guard !isPromptPending else { return false }
        attachments = images
        self.mentions = mentions
        promptCompletion = completion
        sendPrompt(intent: intent)
        if !isPromptPending { promptCompletion = nil }
        return isPromptPending
    }

    func sendPrompt(intent: ACPSubmitIntent = .auto) {
        guard pendingPrompt == nil else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let mentions = NativePeerComposerState.liveMentions(mentions, in: text)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let pending = PendingPrompt(
            text: text, attachments: attachments,
            composerDraft: selectedSessionId.map { composerState(for: $0).draft } ?? .empty,
            composerRevision: selectedSessionId.map { composerState(for: $0).revision } ?? 0,
            epoch: transcript?.epoch, mentions: mentions)
        pendingPrompt = pending
        pendingPromptExpectedIndex = transcript?.totalCount ?? 0
        pendingPromptPriorQueueIds = Set((transcript?.queue ?? []).filter(pending.matches).map(\.id))
        let wireIntent = intent == .steer ? "steer" : "auto"
        let wireAttachments = attachments.map(\.wire)
        if drive({
            .sendPrompt(sessionId: $0, text: text, attachments: wireAttachments, intent: wireIntent, mentions: mentions)
        }) {
            deliveryError = nil
        } else {
            pendingPrompt = nil
            promptCompletion = nil
            pendingPromptExpectedIndex = nil
            deliveryError = Self.peerUnavailableMessage + " Your draft was kept."
        }
    }

    /// Whether `serverId` closes session tabs on request. Older hosts drop
    /// the request, so their tabs get no close button.
    func canCloseSessionTabs(on serverId: String) -> Bool {
        snapshot.groups.first { $0.serverId == serverId }?.state.carriesSessions == true
            && canOpenSessionTabs(serverId: serverId)
    }

    /// Asks the host to close a session tab. The tab is marked closing until
    /// the host's next session list drops it; selection then moves on as
    /// for any tab the host closes.
    func closeSessionTab(_ sessionId: String) {
        guard let downstream, !closingSessionIds.contains(sessionId) else { return }
        closingSessionIds.insert(sessionId)
        if !federation.route(.closeSessionTab(sessionId: sessionId), from: downstream) {
            closingSessionIds.remove(sessionId)
            tabCloseError = Self.peerUnavailableMessage
        }
    }

    /// Renames a session on the host; its next session list carries the
    /// title. No lease is needed, as for a close.
    func renameSession(_ sessionId: String, title: String) {
        guard let downstream else { return }
        // ponytail: a route failure (the peer went offline) is dropped and the
        // tab keeps its title; surface an error if that ever confuses anyone.
        _ = federation.route(.renameSession(sessionId: sessionId, title: title), from: downstream)
    }

    /// Whether `sessionId`'s whole conversation is here to export: only the
    /// selected session's transcript is, once no older page is left to fetch.
    func canExportTranscript(of sessionId: String) -> Bool {
        guard let transcript, transcript.sessionId == sessionId else { return false }
        return transcript.epoch != nil && transcript.olderPageBeforeIndex == nil
    }

    /// The conversation as the local Copy and Save Session as Markdown write it.
    func transcriptMarkdown(of sessionId: String, title: String, agentName: String?) -> String? {
        guard canExportTranscript(of: sessionId), let transcript else { return nil }
        let userNotice = RemoteWireMessage.oversizedNotice(kind: "user")
        let agentNotice = RemoteWireMessage.oversizedNotice(kind: "agent")
        let messages = transcript.messages.compactMap { message -> ACPMessage? in
            let text = message.text ?? ""
            switch message.kind {
            case "user": return ACPMessage.user(id: UUID(), messageId: nil, text: text, attachments: [])
            case "agent": return ACPMessage.agent(id: UUID(), messageId: nil, StreamingText(text))
            // A turn too large to forward keeps its place, with the notice
            // that replaced it as its body.
            case "systemNotice" where text == userNotice:
                return ACPMessage.user(id: UUID(), messageId: nil, text: text, attachments: [])
            case "systemNotice" where text == agentNotice:
                return ACPMessage.agent(id: UUID(), messageId: nil, StreamingText(text))
            default: return nil
            }
        }
        return ACPTranscriptMarkdown.document(title: title, agentName: agentName, messages: messages)
    }

    func selectChip(_ spec: ChipSpec, itemId: String) {
        let sent = drive { id in
            switch spec.source {
            case .model: .setModel(sessionId: id, modelId: itemId)
            case .mode: .setMode(sessionId: id, modeId: itemId)
            case .configOption(let configId):
                .setConfigOption(sessionId: id, configId: configId, value: .string(itemId))
            }
        }
        if sent {
            transcript?.applyOptimistic(spec, itemId: itemId)
        } else {
            deliveryError = Self.peerUnavailableMessage
        }
    }

    func setConfigValue(configId: String, value: ACPConfigValue) {
        let sent = drive { .setConfigOption(sessionId: $0, configId: configId, value: value) }
        if sent {
            if case .boolean(let flag) = value { transcript?.applyOptimistic(configId: configId, value: flag) }
        } else {
            deliveryError = Self.peerUnavailableMessage
        }
    }

    func toggleAutoRun() {
        let enabled = !(transcript?.config?.autoRunEnabled ?? false)
        if drive({ .setAutoRun(sessionId: $0, enabled: enabled) }) {
            transcript?.applyOptimisticAutoRun(enabled)
        } else {
            deliveryError = Self.peerUnavailableMessage
        }
    }

    func queueForceSend(_ itemId: String) { drive { .queueForceSend(sessionId: $0, itemId: itemId) } }
    func queueRemove(_ itemId: String) { drive { .queueRemove(sessionId: $0, itemId: itemId) } }
    func queueRetry(_ itemId: String) { drive { .queueRetry(sessionId: $0, itemId: itemId) } }
    func queueEdit(_ itemId: String) { drive { .queueEdit(sessionId: $0, itemId: itemId) } }
    func queueClear() { drive { .queueClear(sessionId: $0) } }
    func queueMove(_ itemId: String, to targetItemId: String) {
        drive { .queueMove(sessionId: $0, itemId: itemId, targetItemId: targetItemId) }
    }
    func queuePromote(_ itemId: String) { drive { .queuePromote(sessionId: $0, itemId: itemId) } }

    /// Stages an image for the next prompt. Returns why it was refused, or
    /// nil once it is staged.
    @discardableResult
    func addAttachment(_ data: Data, name: String?) -> String? {
        if let refusal = NativePeerComposerState.attachmentRefusal(data, staged: attachments.map(\.data)) {
            return refusal
        }
        guard let mimeType = ACPImageStaging.sniffMIME(data) else { return nil }
        attachments.append(NativePeerAttachment(name: name, mimeType: mimeType, data: data))
        return nil
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Asks the host for `@` candidates; nil closes the picker.
    func searchMentions(_ query: String?) {
        guard query != mentionQuery else { return }
        mentionQuery = query
        // The shown candidates stay until the answer replaces them, so the
        // list doesn't flicker empty on every keystroke.
        let asked = query.map { query in
            transcript?.config?.supportsMentions == true
                && routeWhileOnline { .searchMentions(sessionId: $0, query: query) }
        } ?? false
        if !asked {
            mentionCandidates = []
            mentionCandidatesQuery = nil
        }
    }

    /// Stages a picked mention. `text` is the draft without the token being
    /// completed: staged mentions whose markers it lacks are dropped first,
    /// so a deleted pick can't claim the new marker. Returns why the pick
    /// was refused, or nil once it is staged.
    @discardableResult
    func addMention(_ mention: RemoteMention, in text: String) -> String? {
        mentions = NativePeerComposerState.liveMentions(mentions, in: text)
        guard !mentions.contains(where: { $0.kind == mention.kind && $0.value == mention.value }) else { return nil }
        // The host refuses a prompt over its cap; say so before the send.
        guard mentions.count < RemoteSessionGateway.maxMentionCount else {
            return NativePeerComposerState.tooManyMentions
        }
        mentions.append(mention)
        return nil
    }

    private func resetMentions() {
        mentions = []
        mentionCandidates = []
        mentionCandidatesQuery = nil
        mentionQuery = nil
    }

    func stopSelected() { routeWhileOnline { .stop(sessionId: $0) } }

    /// Stops `sessionId`'s turn on its host, whether or not it is selected.
    func stop(sessionId: String) {
        guard let downstream,
              snapshot.groups.first(where: { sessionId.hasPrefix($0.serverId + ":") })?.state.carriesSessions == true
        else { return }
        _ = federation.route(.stop(sessionId: sessionId), from: downstream)
    }
    func takeOver() { routeWhileOnline { .takeOver(sessionId: $0) } }

    func beginNewSession(peer: NativePeerGroup, repo: NativePeerRepoGroup) {
        guard downstream != nil, peer.state.carriesSessions else { return }
        pendingSessionId = nil
        newSession = NativePeerNewSession(
            serverId: peer.serverId, peerName: peer.name, projectId: repo.projectId, repoName: repo.name
        )
        requestNewSessionOptions()
    }

    /// The peer and repo a new session in `selection` belongs to. Nil while
    /// the peer is offline or for a worktree outside any of its projects.
    func newSessionTarget(in selection: NativePeerWorktreeSelection) -> (peer: NativePeerGroup, repo: NativePeerRepoGroup)? {
        guard let peer = snapshot.groups.first(where: { $0.serverId == selection.serverId }),
              peer.state.carriesSessions,
              let repo = peer.repos(ordering: .manual).first(where: { repo in
                  repo.worktrees.contains { $0.id == selection.worktreeId }
              }),
              repo.projectId != nil
        else { return nil }
        return (peer, repo)
    }

    /// Opens the new-session sheet on the selected worktree's repo, which
    /// preselects that worktree.
    func beginNewSession(in selection: NativePeerWorktreeSelection) {
        guard let target = newSessionTarget(in: selection) else { return }
        beginNewSession(peer: target.peer, repo: target.repo)
    }

    func createNewSession(worktreeId: String, agentId: String, modelId: String?, effortId: String?) {
        guard let request = newSession, request.phase != .creating, let downstream else { return }
        newSession?.phase = .creating
        let token = request.id
        let sent = federation.request(
            .createSession(worktreeId: worktreeId, agentId: agentId, modelId: modelId, effortId: effortId),
            toPeer: request.serverId, from: downstream
        ) { [weak self] reply in self?.applyNewSessionReply(reply, token: token) }
        if !sent { newSession?.phase = .failed(Self.peerUnavailableMessage) }
    }

    /// Asks the peer to create a worktree from `base` and start the session
    /// in it, as one request.
    func createNewWorktreeSession(base: String, branch: String, agentId: String, modelId: String?, effortId: String?) {
        guard let request = newSession, request.phase != .creating, let projectId = request.projectId,
              downstream != nil else { return }
        newSession?.phase = .creating
        requestWorktreeSession(
            consent: supportsRepoHookApproval(request.serverId) ? .ask : nil, token: request.id
        ) { consent in
            .createWorktreeSession(
                projectId: projectId, base: base, branch: branch, agentId: agentId,
                modelId: modelId, effortId: effortId, repoHook: consent)
        }
    }

    /// Sends `create` with `consent`. A hook the peer holds it for is put to
    /// this Mac's user, and the same create sent again with the answer.
    private func requestWorktreeSession(
        consent: RepoHookConsent?, token: UUID,
        _ create: @escaping @Sendable (RepoHookConsent?) -> RemoteClientMessage
    ) {
        guard let request = newSession, request.id == token else { return }
        guard let downstream else {
            newSession?.phase = .failed(Self.peerUnavailableMessage)
            return
        }
        let sent = federation.request(create(consent), toPeer: request.serverId, from: downstream) { [weak self] reply in
            guard case .worktreeSessionNeedsRepoHookApproval(let hook) = reply else {
                self?.applyNewSessionReply(reply, token: token)
                return
            }
            self?.answerRepoHook(hook, token: token, create)
        }
        if !sent { newSession?.phase = .failed(Self.peerUnavailableMessage) }
    }

    private func answerRepoHook(
        _ hook: PeerRepoHook, token: UUID,
        _ create: @escaping @Sendable (RepoHookConsent?) -> RemoteClientMessage
    ) {
        guard let serverId = newSession?.serverId, newSession?.id == token else { return }
        Task { [weak self] in
            guard let decision = await self?.decideRepoHook(serverId, hook, .peerWorktreeCreate),
                  let self, newSession?.id == token, newSession?.phase == .creating else { return }
            switch decision {
            case .approve: requestWorktreeSession(consent: .approve(hash: hook.hash), token: token, create)
            case .skip: requestWorktreeSession(consent: .skip, token: token, create)
            case .retry, .cancel: newSession?.phase = .editing
            }
        }
    }

    func cancelNewSession() {
        newSession = nil
    }

    /// Asks `serverId` for a project's branches, as the new-session sheet does.
    /// No reply comes if the peer drops before answering.
    func requestBranches(
        projectId: String, serverId: String, reply: @escaping @MainActor (NativePeerNewSession.Branches) -> Void
    ) {
        let sent = downstream.map { downstream in
            federation.request(.listBranches(projectId: projectId), toPeer: serverId, from: downstream) { message in
                switch message {
                case .branchList(let id, let names, let preferredBase) where id == projectId:
                    reply(.loaded(names: names, preferredBase: preferredBase))
                case .branchListFailed(let id, let failure) where id == projectId:
                    reply(.failed(failure))
                default:
                    break
                }
            }
        } ?? false
        if !sent { reply(.failed(Self.peerUnavailableMessage)) }
    }

    /// The selected worktree, when it belongs to the sheet's peer.
    var newSessionDefaultWorktreeId: String? {
        guard let request = newSession, let selectedWorktree, selectedWorktree.serverId == request.serverId
        else { return nil }
        return worktree(selectedWorktree)?.peerWorktreeId
    }

    private func requestNewSessionOptions() {
        guard let request = newSession, let downstream else { return }
        let token = request.id
        var messages: [RemoteClientMessage] = [.listWorktrees, .listAgents]
        if let projectId = request.projectId { messages.append(.listBranches(projectId: projectId)) }
        let sent = messages.allSatisfy { message in
            federation.request(message, toPeer: request.serverId, from: downstream) { [weak self] reply in
                self?.applyNewSessionReply(reply, token: token)
            }
        }
        if !sent { newSession?.phase = .failed(Self.peerUnavailableMessage) }
    }

    private func applyNewSessionReply(_ reply: RemoteServerMessage, token: UUID) {
        guard let request = newSession, request.id == token else { return }
        switch reply {
        case .worktreeList(let all):
            newSession?.worktrees = NativePeerNewSession.worktrees(
                all, projectId: request.projectId, repoName: request.repoName
            )
        case .agentList(let agents):
            newSession?.agents = agents
        case .branchList(let projectId, let names, let preferredBase) where projectId == request.projectId:
            newSession?.branches = .loaded(names: names, preferredBase: preferredBase)
        case .branchListFailed(let projectId, let message) where projectId == request.projectId:
            newSession?.branches = .failed(message)
        case .createSessionFailed(let message):
            newSession?.phase = .failed(message)
        case .worktreeSessionCreationFailed(_, let message, let worktreeId):
            newSession?.phase = .failed(message)
            // The worktree exists without its session: list it, so the sheet
            // can offer it instead of creating a second one.
            guard let worktreeId, let downstream else { return }
            newSession?.recoveredWorktreeId = worktreeId
            _ = federation.request(.listWorktrees, toPeer: request.serverId, from: downstream) { [weak self] reply in
                self?.applyNewSessionReply(reply, token: token)
            }
        case .sessionCreated(let summary), .worktreeSessionCreated(let summary):
            newSession = nil
            pendingSessionId = summary.id
            refresh()
        default:
            break
        }
    }

    /// Fails the open sheet while its peer is away, and reloads its options
    /// when the peer is back.
    private func reconcileNewSession() {
        guard let request = newSession else { return }
        let online = snapshot.groups.first { $0.serverId == request.serverId }?.state.carriesSessions == true
        let unavailable = NativePeerNewSession.Phase.failed(Self.peerUnavailableMessage)
        if !online, request.phase != unavailable {
            newSession?.phase = unavailable
        } else if online, request.phase == unavailable {
            newSession?.phase = .editing
            requestNewSessionOptions()
        }
    }

    /// Re-asks the peer for the selected session's changes and file tree.
    /// Replies land through `receive`.
    func reloadWorkspace() {
        // Nothing to read yet: no retry to queue either.
        guard canReadWorkspace else { return }
        // A request already in flight (e.g. the user hit refresh while the
        // initial load was still out) skips its send; queue a retry so the
        // eventual reply doesn't stand in as current.
        if !requestChanges() { changesRequestOutdated = true }
        if !loadFileTree() { fileTreeRequestOutdated = true }
        // An open diff or file is otherwise left showing its old snapshot —
        // neither a summary change nor the toolbar's manual refresh touches
        // it, since both only route through this method.
        if let document = workspace.document, !open(document) {
            documentRequestOutdated = true
        }
    }

    @discardableResult
    func requestChanges() -> Bool {
        guard canReadWorkspace else { return false }
        // A session's own summary, as `refresh()` compares it; the group's
        // only for an idle worktree.
        workspaceSummary = selectedSessionId != nil ? selectedRow?.worktree : selectedWorktreeGroup?.worktree
        workspaceHostSnapshot = selectedWorktreeGroup?.host?.snapshot
        // A folder project has no git, so there are no changes to ask for.
        guard workspaceSummary?.isFolder != true, !changesRequestInFlight else { return false }
        changesRequestInFlight = true
        workspace.beginChangesLoad()
        let mode = comparisonMode()
        if !routeWorkspaceRead(.changes(comparisonMode: mode), session: {
            .listChanges(sessionId: $0, comparisonMode: mode)
        }) {
            changesRequestInFlight = false
            workspace.markUnavailable()
            return false
        }
        return true
    }

    @discardableResult
    func loadFileTree() -> Bool {
        guard canReadWorkspace, workspace.beginRootLoad() else { return false }
        guard !fileTreeRequestInFlight else { return false }
        fileTreeRequestInFlight = true
        let mode = comparisonMode()
        if !routeWorkspaceRead(.files(path: nil, comparisonMode: mode), session: {
            .listFiles(sessionId: $0, path: nil, comparisonMode: mode)
        }) {
            fileTreeRequestInFlight = false
            workspace.markUnavailable()
            return false
        }
        return true
    }

    func loadFileTreeChildren(path: String) {
        guard canReadWorkspace, workspace.beginChildrenLoad(path: path) else { return }
        let mode = comparisonMode()
        if !routeWorkspaceRead(.files(path: path, comparisonMode: mode), session: {
            .listFiles(sessionId: $0, path: path, comparisonMode: mode)
        }) {
            workspace.markUnavailable()
        }
    }

    func loadCommitFiles(sha: String) {
        guard canReadWorkspace, workspace.beginCommitFilesLoad(sha: sha) else { return }
        if !routeWorkspaceRead(.commitFiles(sha: sha), session: { .listCommitFiles(sessionId: $0, sha: sha) }) {
            workspace.markUnavailable()
        }
    }

    /// Opens `document`, or — when it's already the open one — refreshes it.
    /// A refresh is gated the same way changes/file-tree refreshes are: a
    /// request already in flight for this same document skips the send, and
    /// `reloadWorkspace()` queues a retry. Opening a genuinely different
    /// document always proceeds; whatever was in flight for the previous one
    /// no longer matters.
    @discardableResult
    func open(_ document: NativePeerWorkspace.Document) -> Bool {
        guard canReadWorkspace else { return false }
        openedReview = nil
        openedCommitEditor = nil
        if document != workspace.document {
            documentRequestOutdated = false
            hostFileRefusals = [:]
        }
        let bytesTarget = hostBytesTarget
        workspace.beginDocument(document, previewsFiles: bytesTarget != nil)
        guard !documentRequestsInFlight.contains(document) else {
            // A request for this exact document is already outstanding —
            // whether it's the one already open (a refresh) or one just
            // returned to (A→B→A, sharing the peer's still-outstanding
            // request key) — so don't resend a duplicate the peer would
            // drop; queue a retry for when that reply lands instead.
            documentRequestOutdated = true
            return false
        }
        documentRequestsInFlight.insert(document)
        let sent = switch document {
        case .diff(let path, let stage):
            routeWorkspaceRead(.fileDiff(path: path, stage: stage?.rawValue, comparisonMode: comparisonMode())) {
                .fileDiff(
                    sessionId: $0,
                    path: path,
                    stage: stage?.rawValue,
                    comparisonMode: comparisonMode()
                )
            }
        case .commitDiff(let path, let sha):
            routeWorkspaceRead(.commitDiff(sha: sha, path: path)) { .commitFileDiff(sessionId: $0, sha: sha, path: path) }
        case .file(let path):
            if ImageFileType.isSupported(relativePath: path), let target = bytesTarget {
                routeHostRead(.fileBytes(path: path, revision: nil), to: target)
            } else {
                routeWorkspaceRead(.file(path: path)) { .readFile(sessionId: $0, path: path) }
            }
        case .stashDiff, .checkpointDiff:
            readHostDiff(document)
        }
        if !sent {
            documentRequestsInFlight.remove(document)
            workspace.markUnavailable()
            return false
        }
        return true
    }

    func closeDocument() {
        workspace.closeDocument()
        hostFileRefusals = [:]
    }

    /// Reads a stash or checkpoint file's diff over the selected worktree's
    /// host channel, whether or not a session is selected: only the host
    /// serves stashes and checkpoints.
    private func readHostDiff(_ document: NativePeerWorkspace.Document) -> Bool {
        guard let hosts, let selection = selectedWorktree, let host = selectedWorktreeGroup?.host else { return false }
        let serverId = selection.serverId
        let read: @MainActor () async -> Result<HostDiff, NativePeerReviewGitClientError>
        switch document {
        case .stashDiff(let path, let stash) where hosts.servesStash(serverId: serverId):
            read = { await hosts.stashDiff(stash, path: path, in: host, serverId: serverId) }
        case .checkpointDiff(let path, let id) where hosts.servesCheckpoints(serverId: serverId):
            read = { await hosts.checkpointDiff(id, path: path, in: host, serverId: serverId) }
        default:
            return false
        }
        let epoch = workspaceEpoch
        Task { [weak self] in
            let result = await read()
            guard let self, workspaceEpoch == epoch else { return }
            documentRequestsInFlight.remove(document)
            workspace.finishDocument(document, with: result)
            if documentRequestOutdated, workspace.document == document {
                documentRequestOutdated = false
                open(document)
            }
        }
        return true
    }

    func openReview(_ sessionID: String, serverId: String, worktree: PeerHostWorktree) {
        workspace.closeDocument()
        openedCommitEditor = nil
        openedReview = NativePeerReviewSelection(serverId: serverId, worktree: worktree, sessionID: sessionID)
    }

    /// Selects the host worktree, then opens its review `sessionID`, as a
    /// review notice's click does. Nothing opens once the host no longer lists the worktree.
    func openHostReview(serverId: String, worktreeID: String, sessionID: String) {
        selectHostWorktree(serverId: serverId, worktreeID: worktreeID)
        guard let host = worktrees(on: serverId).first(where: { $0.peerWorktreeId == worktreeID })?.host else { return }
        openReview(sessionID, serverId: serverId, worktree: host)
    }

    func closeReview() {
        openedReview = nil
    }

    func openCommitEditor(_ selection: NativePeerCommitEditorSelection) {
        workspace.closeDocument()
        openedReview = nil
        openedCommitEditor = selection
    }

    func closeCommitEditor() {
        openedCommitEditor = nil
    }

    func requestCheckpointRestore(_ id: CheckpointID) {
        pendingCheckpointRestore = id
    }

    func takeCheckpointRestore() -> CheckpointID? {
        defer { pendingCheckpointRestore = nil }
        return pendingCheckpointRestore
    }

    @discardableResult
    func fetchOlder() -> Bool {
        guard !isFetchingOlderMessages,
              let before = transcript?.olderPageBeforeIndex
        else { return false }
        isFetchingOlderMessages = true
        guard routeWhileOnline({
            .fetchOlder(
                sessionId: $0, beforeIndex: before, limit: RemoteTranscriptSync.tailWindow
            )
        }) else {
            isFetchingOlderMessages = false
            return false
        }
        return true
    }

    func decidePermission(requestId: Int, optionId: String) {
        guard transcript?.pendingPermission?.requestId == requestId else { return }
        routeDrive { .permissionDecision(sessionId: $0, requestId: requestId,
                                          optionId: optionId, persistScope: nil) }
    }

    func answerQuestion(requestId: Int, answers: [RemoteQuestionAnswer]) {
        guard transcript?.pendingQuestion?.requestId == requestId else { return }
        routeDrive { .questionAnswer(sessionId: $0, requestId: requestId, answers: answers) }
    }

    func respondToPlan(requestId: JSONRPCID, action: String, reason: String? = nil) {
        guard transcript?.pendingPlan?.requestId == requestId else { return }
        let responseReason: String?
        if action == "reject" {
            let trimmed = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            responseReason = trimmed
        } else {
            responseReason = reason
        }
        routeDrive { .planResponse(sessionId: $0, requestId: requestId, action: action, reason: responseReason) }
    }

    func respondToElicitation(requestId: String, action: String,
                               content: [String: ACPElicitationValue]? = nil) {
        guard let pending = transcript?.pendingElicitation,
              pending.requestId == requestId,
              pending.mode != "url" || action != "accept"
        else { return }
        sendElicitationResponse(requestId: requestId, action: action, content: content)
    }

    func openElicitationURL(
        requestId: String,
        openURL: @MainActor (URL, @escaping @MainActor (Bool) -> Void) -> Void,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let pending = transcript?.pendingElicitation,
              pending.requestId == requestId,
              pending.mode == "url",
              let rawURL = pending.url,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            completion(false)
            return
        }

        openURL(url) { [weak self] didOpen in
            guard didOpen else {
                completion(false)
                return
            }
            self?.sendElicitationResponse(requestId: requestId, action: "accept", content: [:])
            completion(true)
        }
    }

    private func sendElicitationResponse(requestId: String, action: String,
                                          content: [String: ACPElicitationValue]?) {
        guard transcript?.pendingElicitation?.requestId == requestId else { return }
        routeDrive { .elicitationResponse(sessionId: $0, requestId: requestId,
                                           action: action, content: content) }
    }

    /// Drives the selected session, taking the writer lease first when this
    /// Mac doesn't hold it. Both frames ride the same ordered connection, so
    /// the host handles `takeOver` before the verb.
    @discardableResult
    private func drive(_ makeMessage: (String) -> RemoteClientMessage) -> Bool {
        guard let transcript, transcript.epoch != nil, !transcript.isClosed else { return false }
        if !transcript.canDrive, !routeWhileOnline({ .takeOver(sessionId: $0) }) { return false }
        return routeWhileOnline(makeMessage)
    }

    private func routeDrive(_ makeMessage: (String) -> RemoteClientMessage) {
        guard transcript?.canDrive == true else { return }
        routeWhileOnline(makeMessage)
    }

    @discardableResult
    private func routeWhileOnline(_ makeMessage: (String) -> RemoteClientMessage) -> Bool {
        guard let selectedSessionId, let downstream,
              selectedPeer?.state.carriesSessions == true else { return false }
        return federation.route(makeMessage(selectedSessionId), from: downstream)
    }

    /// Sends a Changes or Files read: the session's own request while a
    /// session is selected, else `read` of the selected worktree over its
    /// host's channel. An answer after the selection moved is dropped.
    private func routeWorkspaceRead(_ read: HostWorktreeRead, session: (String) -> RemoteClientMessage) -> Bool {
        if selectedSessionId != nil { return routeWhileOnline(session) }
        guard let target = hostReadTarget else { return false }
        return routeHostRead(read, to: target)
    }

    /// Sends `read` over `target`'s host channel and applies the answer, as a workspace reply.
    private func routeHostRead(_ read: HostWorktreeRead, to target: (serverId: String, worktree: PeerHostWorktree)) -> Bool {
        guard let hosts else { return false }
        let epoch = workspaceEpoch
        let worktreeId = target.worktree.snapshot.worktree.id
        Task { [weak self] in
            let reply = await hosts.read(read, in: target.worktree, serverId: target.serverId)
            // The selection moved since: the answer is no longer wanted. A
            // lost host channel is not a selection change, so its failure
            // still clears this read's in-flight marker below.
            guard let self, workspaceEpoch == epoch else { return }
            // Unanswered, refused, or cut off by a disconnect: fail just this
            // read, as a failure reply would.
            let answer = reply.flatMap { $0.sessionId == worktreeId ? $0 : nil } ?? Self.unserved(read, worktreeId: worktreeId)
            _ = applyWorkspaceReply(answer)
        }
        return true
    }

    /// The failure reply standing in for a host-channel read with no answer.
    private static func unserved(_ read: HostWorktreeRead, worktreeId id: String) -> RemoteServerMessage {
        switch read {
        case .changes: .changeListFailed(sessionId: id, reason: .unknown, message: nil)
        case .fileDiff(let path, let stage, _):
            .fileDiffFailed(sessionId: id, path: path, stage: stage, reason: .unknown, message: nil)
        case .files(let path, _): .fileTreeFailed(sessionId: id, path: path, reason: .unknown, message: nil)
        case .commitFiles(let sha): .commitFilesFailed(sessionId: id, sha: sha, reason: .unknown, message: nil)
        case .commitDiff(let sha, let path):
            .commitDiffFailed(sessionId: id, sha: sha, path: path, reason: .unknown, message: nil)
        case .rangeFiles(let base, let head, let threeDot):
            .commitFilesFailed(
                sessionId: id, sha: HostWorktreeRead.rangeSpec(base: base, head: head, threeDot: threeDot),
                reason: .unknown, message: nil)
        case .rangeDiff(let base, let head, let threeDot, let path, _):
            .commitDiffFailed(
                sessionId: id, sha: HostWorktreeRead.rangeSpec(base: base, head: head, threeDot: threeDot), path: path,
                reason: .unknown, message: nil)
        case .file(let path), .fileBytes(let path, _):
            .fileUnavailable(sessionId: id, path: path, reason: .unknown, byteSize: nil, message: nil)
        }
    }

    private static func appending(_ text: String, to draft: String) -> String {
        draft.isEmpty ? text : draft + "\n" + text
    }

    nonisolated static let genericPromptRejectedMessage = "Prompt was not delivered. Your draft was kept."

    /// The host refuses prompts while its agent cannot run; say why.
    nonisolated static func promptRejectedMessage(_ reason: String?) -> String {
        guard let reason else { return genericPromptRejectedMessage }
        return "Prompt was not delivered: \(reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))). Your draft was kept."
    }

    /// What the composer's error line shows. A generic rejection gives way
    /// to one that says why once the session reports its agent issue, which
    /// can arrive after the rejection.
    nonisolated static func composerMessage(deliveryError: String?, notice: String?, agentIssue: RemoteAgentIssue?) -> String? {
        if deliveryError == genericPromptRejectedMessage, let agentIssue {
            return promptRejectedMessage(agentIssue.message)
        }
        return deliveryError ?? notice ?? agentIssue?.message
    }

    private static let unconfirmedDeliveryMessage = "Peer session changed before delivery could be confirmed. Your draft was kept."

    /// Pending sends keep their subscription until delivery settles, even
    /// when another session is selected. Re-selection also replays the queue.
    private func handleSuspendedPrompt(_ message: RemoteServerMessage) -> Bool {
        guard let sessionId = message.sessionId, sessionId != selectedSessionId,
              var suspended = suspendedPrompts[sessionId] else { return false }
        switch message {
        case .transcriptSnapshot(_, _, _, _, _, _, let epoch, _, _),
             .transcriptDelta(_, _, _, _, let epoch, _, _):
            suspended.replayEpoch = epoch
        case .sessionClosed:
            suspended.needsResubscribe = true
        case .sessionConfig(let config):
            suspended.agentIssue = config.agentIssue
        default: break
        }
        let rejected: Bool = if case .promptRejected = message { true } else { false }
        let rejectionReason: String? = if case .promptRejected(_, let reason) = message { reason } else { nil }
        let confirmed = suspended.isConfirmed(by: message)
        let superseded: Bool
        if case .queueState = message, let epoch = suspended.replayEpoch, let sentEpoch = suspended.prompt.epoch {
            superseded = epoch != sentEpoch
        } else {
            superseded = false
        }
        guard rejected || confirmed || superseded else {
            suspendedPrompts[sessionId] = suspended
            return false
        }
        suspendedPrompts.removeValue(forKey: sessionId)
        if confirmed {
            let composer = composerState(for: sessionId)
            if composer.revision == suspended.prompt.composerRevision,
               composer.draft == suspended.prompt.composerDraft { composer.replaceDraft(.empty) }
        } else {
            composerErrors[sessionId] = superseded
                ? Self.unconfirmedDeliveryMessage : Self.promptRejectedMessage(rejectionReason ?? suspended.agentIssue?.message)
        }
        if let downstream { _ = federation.route(.unsubscribe(sessionId: sessionId), from: downstream) }
        if confirmed {
            suspended.completion?(true)
        } else {
            restoreRejectedPrompt(suspended.prompt, sessionId: sessionId, completion: suspended.completion)
        }
        return true
    }

    private func restoreRejectedPrompt(
        _ submitted: PendingPrompt, sessionId: String, completion: (@MainActor (Bool) -> Void)?
    ) {
        let composer = composerState(for: sessionId)
        let nextDraft = composer.revision == submitted.composerRevision ? ACPComposerDraft.empty : composer.draft
        let restored = submitted.composerDraft.appending(nextDraft)
        // Settle the mounted editor first; its callback may restore the submitted
        // snapshot. The session owner then preserves both durable drafts.
        completion?(false)
        composer.replaceDraft(restored)
        if selectedSessionId == sessionId { draft = restored.plainText }
    }

    private func rejectPendingPrompt(message: String) {
        let completion = promptCompletion
        let submitted = pendingPrompt
        pendingPrompt = nil
        promptCompletion = nil
        pendingPromptExpectedIndex = nil
        deliveryError = message
        if let submitted, let selectedSessionId {
            restoreRejectedPrompt(submitted, sessionId: selectedSessionId, completion: completion)
        }
    }

    private func receive(_ message: RemoteServerMessage) {
        // Tab actions answer for any session, not just the selected one. A
        // reply to a request the user has since moved on from, or retried,
        // is dropped.
        switch message {
        case .sessionTabActionSucceeded(let sessionId), .sessionTabActionFailed(let sessionId, _):
            // Opens target history sessions and closes open tabs, so a
            // session never has both in flight: no open pending means a close.
            guard tabOpensInFlight[sessionId] != nil else {
                if case .sessionTabActionFailed(_, let text) = message, closingSessionIds.remove(sessionId) != nil {
                    tabCloseError = text
                }
                return
            }
            let remaining = (tabOpensInFlight[sessionId] ?? 1) - 1
            tabOpensInFlight[sessionId] = remaining > 0 ? remaining : nil
            if case .sessionTabActionFailed(_, let text) = message, remaining <= 0, pendingSessionId == sessionId {
                pendingSessionId = nil
                sessionTabError = text
            }
            return
        case .queueEditRestored(let sessionId, _, let text):
            // The edit was requested from the session it names; the reply
            // can land after the user switched away.
            let submitted = sessionId == selectedSessionId ? pendingPrompt : suspendedPrompts[sessionId]?.prompt
            let composer = composerState(for: sessionId)
            // An accepted submit clears the visible editor before its durable
            // snapshot is confirmed. Queue Edit belongs to the next draft.
            if let submitted, composer.revision == submitted.composerRevision,
               composer.draft == submitted.composerDraft {
                composer.replaceDraft(.empty)
                if sessionId == selectedSessionId { draft = "" }
            }
            if sessionId == selectedSessionId {
                draft = Self.appending(text, to: draft)
            } else {
                restoredDrafts[sessionId] = Self.appending(text, to: restoredDrafts[sessionId] ?? "")
            }
            return
        default:
            break
        }
        if handleSuspendedPrompt(message) { return }
        guard let selectedSessionId, message.sessionId == selectedSessionId else { return }
        switch message {
        case .transcriptSnapshot, .transcriptPage:
            isFetchingOlderMessages = false
        default:
            break
        }
        if case .mentionCandidates(_, let query, let candidates) = message {
            if query == mentionQuery {
                mentionCandidates = candidates
                mentionCandidatesQuery = query
            }
            return
        }
        if case .promptRejected(_, let reason) = message {
            rejectPendingPrompt(message: Self.promptRejectedMessage(reason ?? transcript?.config?.agentIssue?.message))
            return
        }
        if applyWorkspaceReply(message) { return }
        let needsResubscribe = transcript?.apply(message) == true
        if needsResubscribe, let downstream,
           !federation.route(.subscribe(sessionId: selectedSessionId), from: downstream) {
            transcript?.resetResubscribeRequest()
        }
        let promptConfirmationRows: [RemoteWireMessage]
        switch message {
        case .transcriptSnapshot(_, _, _, let rows, _, _, let epoch, let revision, _)
            where transcript?.epoch == epoch && transcript?.revision == revision:
            promptConfirmationRows = rows
        case .transcriptDelta(_, _, _, let upserts, let epoch, let revision, _)
            where transcript?.epoch == epoch && transcript?.revision == revision:
            promptConfirmationRows = upserts
        default:
            promptConfirmationRows = []
        }
        if case .queueState(_, let items) = message, let pendingPrompt,
           items.contains(where: { pendingPrompt.matches($0) && !pendingPromptPriorQueueIds.contains($0.id) }) {
            confirm(pendingPrompt)
            return
        }
        if let pendingPrompt, let expectedIndex = pendingPromptExpectedIndex,
           promptConfirmationRows.contains(where: { pendingPrompt.matches($0) && $0.index >= expectedIndex }) {
            confirm(pendingPrompt)
            return
        }
        if case .queueState = message, let pendingPrompt,
           let epoch = transcript?.epoch, epoch != pendingPrompt.epoch {
            // Wait for both the transcript and queue replay before deciding
            // that an older epoch can no longer acknowledge its prompt.
            rejectPendingPrompt(message: Self.unconfirmedDeliveryMessage)
        }
    }

    /// Folds a Changes or Files reply into the workspace, clearing its
    /// in-flight marker and sending a retry queued while it was out. False
    /// for every other message.
    private func applyWorkspaceReply(_ message: RemoteServerMessage) -> Bool {
        let isChangesReply: Bool = switch message {
        case .changeList, .changeListFailed: true
        default: false
        }
        if isChangesReply { changesRequestInFlight = false }
        let isRootFileTreeReply: Bool = switch message {
        case .fileTree(_, let path, _, _), .fileTreeFailed(_, let path, _, _): path == nil
        default: false
        }
        if isRootFileTreeReply { fileTreeRequestInFlight = false }
        // The document this reply is about, regardless of what's currently
        // open — an A→B→A round trip leaves A's original request in flight
        // under a peer dedup key a fresh one would collide with, so its
        // reply must clear A's entry even while B (or nothing) is showing.
        let replyDocument: NativePeerWorkspace.Document? = switch message {
        case .fileDiffResult(_, let path, let stage, _, _, _), .fileDiffFailed(_, let path, let stage, _, _):
            .diff(path: path, stage: stage.flatMap(ChangeStage.init(rawValue:)))
        case .commitDiffResult(_, let sha, let path, _, _, _), .commitDiffFailed(_, let sha, let path, _, _):
            .commitDiff(path: path, sha: sha)
        case .fileContents(_, let path, _, _, _), .fileUnavailable(_, let path, _, _, _), .fileBytes(_, let path, _, _):
            .file(path: path)
        default: nil
        }
        if let replyDocument { documentRequestsInFlight.remove(replyDocument) }
        let isDocumentReply = replyDocument != nil && replyDocument == workspace.document
        let handled = workspace.apply(message)
        if isChangesReply, changesRequestOutdated {
            changesRequestOutdated = false
            requestChanges()
        }
        if isRootFileTreeReply, fileTreeRequestOutdated {
            fileTreeRequestOutdated = false
            loadFileTree()
        }
        if isDocumentReply, documentRequestOutdated, let document = workspace.document {
            documentRequestOutdated = false
            open(document)
        }
        return handled
    }

    /// Clears what was sent from the composer, leaving anything the user
    /// changed since.
    private func confirm(_ sent: PendingPrompt) {
        let completion = promptCompletion
        let unchanged = selectedSessionId.map {
            let composer = composerState(for: $0)
            return composer.revision == sent.composerRevision && composer.draft == sent.composerDraft
        } ?? true
        if unchanged, let selectedSessionId { composerState(for: selectedSessionId).replaceDraft(.empty) }
        if unchanged, draft.trimmingCharacters(in: .whitespacesAndNewlines) == sent.text { draft = "" }
        if attachments == sent.attachments { attachments = [] }
        mentions = NativePeerComposerState.liveMentions(mentions, in: draft)
        pendingPrompt = nil
        promptCompletion = nil
        pendingPromptExpectedIndex = nil
        completion?(true)
    }
}

/// An image staged in the peer composer.
struct NativePeerAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String?
    let mimeType: String
    let data: Data

    var wire: RemoteAttachment {
        RemoteAttachment(name: name, mimeType: mimeType, dataBase64: data.base64EncodedString())
    }
}
