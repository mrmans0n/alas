import AlasRemoteKit
import Foundation
import Observation

enum Load<T> {
    case idle, loading, loaded(T), failed(String)
}

struct DiffKey: Hashable {
    let path: String
    let stage: String?
    /// The commit whose change to `path` this is; nil for the working tree.
    var sha: String? = nil
}

struct CommitFilesReply {
    let files: [RemoteChangedFile]
    let truncated: Bool
}

struct ChangeListReply {
    let comparisonRef: String?
    let metricsAvailable: Bool
    let files: [RemoteChangedFile]
    let staged: [RemoteChangedFile]
    let unstaged: [RemoteChangedFile]
    let commits: [RemoteCommit]
    let truncated: Bool
    let commitsTruncated: Bool

    /// `changedFiles` in changes-view.js: the branch files, else staged and unstaged once each.
    var changedFiles: [RemoteChangedFile] {
        files.isEmpty ? Array(Dictionary(grouping: staged + unstaged, by: \.path).values.compactMap(\.first)) : files
    }
}

struct DiffReply {
    let hunks: [RemoteDiffHunk]
    let truncated: Bool
    let metadataNote: String?
}

struct FileReply {
    let text: String
    let truncated: Bool
}

/// What one session's Changes and Files tabs show. Lives next to its `TranscriptSession` so a tab
/// switch or a reconnect keeps the open diff and tree. Replies are applied only for this session
/// and, for a diff, only for the key still open.
@MainActor @Observable
final class SessionWorkspace {
    private(set) var changes: Load<ChangeListReply> = .idle
    private(set) var diff: (key: DiffKey, Load<DiffReply>)?
    /// The commit whose files are open, pushed from the Commits section.
    private(set) var commit: (commit: RemoteCommit, Load<CommitFilesReply>)?
    private(set) var tree = RemoteFileTree()
    private(set) var file: (path: String, Load<FileReply>)?
    /// The screen that pushed the open diff or file. The session can be open in several tabs at once;
    /// only that screen's stack shows it.
    private(set) var pushedBy: UUID?
    /// Directories the host cut short, and the last listing failure.
    private(set) var truncatedDirs: Set<String> = []
    private(set) var treeError: String?
    var error: String?

    let hostID: UUID
    let sessionId: String
    @ObservationIgnored private let hub: HostHub
    @ObservationIgnored private var listener: ListenerToken?
    @ObservationIgnored private var streaming = "idle"
    /// An idle refresh that arrived while a diff was open; it runs when the diff closes.
    @ObservationIgnored private var refreshDeferred = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watchGeneration = 0
    @ObservationIgnored private var hostWasOnline = false
    @ObservationIgnored private var holders = 0
    @ObservationIgnored private var treeRequested = false
    /// The git action in flight; one at a time, as the Mac's worktree gate allows.
    private(set) var gitRunning: RemoteGitChange?
    /// Host requests awaiting their answer, by request id.
    @ObservationIgnored private var hostWaiters: [Int: CheckedContinuation<Result<OpaqueHostMessage, RemoteGitFailure>, Never>] = [:]
    /// The session's PR shepherd, once the host's session list said; nil without one.
    private(set) var shepherd: RemoteShepherd?
    private(set) var shepherdLoaded = false
    private(set) var shepherdRunning: RemoteShepherdAction?
    /// The worktree's pull request, once the host reported one.
    private(set) var pullRequest: RemotePullRequest?
    @ObservationIgnored private var reviewStatusId: Int?
    /// The worktree's run scripts, once listed.
    private(set) var runScripts: [RemoteRunScript] = []
    @ObservationIgnored private var runScriptsId: Int?
    @ObservationIgnored private var shepherdListId: Int?

    init(hub: HostHub, hostID: UUID, sessionId: String) {
        self.hub = hub
        self.hostID = hostID
        self.sessionId = sessionId
    }

    /// True while a view `owner` pushed (a diff or a file) is open.
    func hasPushedChild(_ owner: UUID) -> Bool { pushedBy == owner && (diff != nil || file != nil || commit != nil) }

    // MARK: Lifecycle

    /// Listens while any screen showing the session holds the token; the last release stops.
    /// The first holder asks again for whatever is open, since replies sent while nobody listened
    /// were dropped and the host may have reconnected meanwhile.
    func activate() -> ListenerToken {
        holders += 1
        if holders == 1 {
            listener = hub.addListener(hostID) { [weak self] in self?.receive($0) }
            hostWasOnline = hub.state(of: hostID) == .online
            if hostWasOnline { replay() }
            watchGeneration += 1
            watchHost(generation: watchGeneration)
            pollShepherd(generation: watchGeneration)
        }
        return ListenerToken { [weak self] in
            guard let self else { return }
            holders -= 1
            if holders == 0 { deactivate() }
        }
    }

    private func deactivate() {
        listener = nil
        watchGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func watchHost(generation: Int) {
        guard generation == watchGeneration else { return }
        let online = withObservationTracking {
            hub.state(of: hostID) == .online
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchHost(generation: generation) }
        }
        defer { hostWasOnline = online }
        if online, !hostWasOnline { replay() }
    }

    /// Asks again for whatever is open; the host forgot everything it was asked while away.
    private func replay() {
        if case .idle = changes {} else { refreshChanges() }
        if let commit { send(.listCommitFiles(sessionId: sessionId, sha: commit.commit.revision)) }
        if let diff { requestDiff(diff.key) }
        if treeRequested { loadTree() }
        refreshShepherd()
        refreshRunScripts()
        if let file {
            self.file = (file.path, .loading)
            send(.readFile(sessionId: sessionId, path: file.path))
        }
    }

    // MARK: Changes

    func refreshChanges() {
        if case .loaded = changes {} else { changes = .loading }
        send(.listChanges(sessionId: sessionId))
        refreshPullRequest()
    }

    /// Asks the host to read the worktree's pull request again; its answer replaces `pullRequest`.
    private func refreshPullRequest() {
        guard canUseGit, let target = gitTarget, hub.state(of: hostID) == .online else { return }
        let id = hub.nextHostRequestId()
        reviewStatusId = id
        send(.host(RemoteGitRequest.reviewStatus(id: id, projectID: target.projectID, path: target.worktree.path)))
    }

    func openDiff(_ path: String, stage: String?, sha: String? = nil, by owner: UUID) {
        pushedBy = owner
        let key = DiffKey(path: path, stage: stage, sha: sha)
        diff = (key, .loading)
        requestDiff(key)
    }

    private func requestDiff(_ key: DiffKey) {
        if let sha = key.sha {
            send(.commitFileDiff(sessionId: sessionId, sha: sha, path: key.path))
        } else {
            send(.fileDiff(sessionId: sessionId, path: key.path, stage: key.stage))
        }
    }

    func openCommit(_ commit: RemoteCommit, by owner: UUID) {
        pushedBy = owner
        self.commit = (commit, .loading)
        send(.listCommitFiles(sessionId: sessionId, sha: commit.revision))
    }

    func closeCommit() {
        commit = nil
        if diff?.key.sha != nil { closeDiff() }
    }

    func closeDiff() {
        diff = nil
        if refreshDeferred { scheduleRefresh() }
    }

    /// Refreshes the list and the file tree when the agent goes idle, once their tab has been opened.
    func noteStreaming(_ state: String) {
        defer { streaming = state }
        guard state == "idle", streaming != "idle" else { return }
        // A Ship turn that ends has usually opened the pull request.
        refreshShepherd()
        if treeRequested { loadTree() }
        if case .idle = changes { return }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard diff == nil else {
            refreshDeferred = true
            return
        }
        refreshDeferred = false
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refreshChanges()
        }
    }

    // MARK: Files (Task 5)

    func loadTree() {
        treeRequested = true
        send(.listFiles(sessionId: sessionId, path: nil, comparisonMode: nil))
    }

    func toggle(_ dir: String) {
        if tree.expanded.remove(dir) != nil { return }
        tree.expanded.insert(dir)
        // Always re-lists: a collapsed directory misses the refreshes, so its cached listing shows only until the reply.
        send(.listFiles(sessionId: sessionId, path: dir, comparisonMode: nil))
    }

    func openFile(_ path: String, by owner: UUID) {
        pushedBy = owner
        file = (path, .loading)
        send(.readFile(sessionId: sessionId, path: path))
    }

    func closeFile() {
        file = nil
    }

    // MARK: Replies

    // MARK: Git

    /// The session's own worktree on its host, which git actions name. A session a gateway relays
    /// lives on another Mac, whose worktrees this connection can't name; nor can it name one in an
    /// SSH project, whose summary carries a display path (`host:/repo`), not the stored one.
    private var gitTarget: (projectID: String, worktree: RemoteWorktreeSummary)? {
        guard let summary = hub.sessions(of: hostID).first(where: { $0.id == sessionId }), summary.serverId == nil,
              let projectID = summary.projectId, let worktree = summary.worktree, worktree.path.hasPrefix("/") else { return nil }
        return (projectID, worktree)
    }

    var canUseGit: Bool {
        gitTarget != nil && (hub.supports(HostProtocolCapability.worktreesGitPhoneV1, on: hostID)
            || hub.supports(HostProtocolCapability.worktreesGitV1, on: hostID))
    }

    /// Whether the open working-tree diff's hunks can be staged, unstaged or discarded one by one.
    var canChangeHunks: Bool {
        guard let key = diff?.key, key.sha == nil, key.stage != nil, gitTarget != nil else { return false }
        return hub.supports(HostProtocolCapability.worktreesHunksPhoneV1, on: hostID)
            || hub.supports(HostProtocolCapability.worktreesHunksV1, on: hostID) && hub.supports(HostProtocolCapability.worktreesGitV1, on: hostID)
    }

    /// Applies `action` to `hunk`, the `index`th of the open diff, then reads that diff again.
    /// Returns the host's refusal, or nil.
    func changeHunk(_ action: RemoteHunkAction, index: Int, _ hunk: RemoteDiffHunk) async -> String? {
        guard let key = diff?.key, key.sha == nil else { return "This diff can't be changed from here." }
        defer { if diff?.key == key { requestDiff(key) } }
        return await git(.hunk(path: key.path, index: index, header: hunk.header, linesHash: hunk.linesHash, action: action))
    }

    /// Runs `change` on the session's worktree and refreshes the change list. Returns the host's
    /// refusal, worded for the user, or nil once it succeeded.
    func git(_ change: RemoteGitChange) async -> String? {
        guard gitRunning == nil, let target = gitTarget else { return "This worktree can't be changed from here." }
        gitRunning = change
        defer {
            gitRunning = nil
            refreshChanges()
        }
        return await hostRequest {
            RemoteGitRequest.message(id: $0, projectID: target.projectID, path: target.worktree.path,
                                     branch: target.worktree.branch, change: change)
        }
    }

    /// What the host suggests a message for the staged change from; nil when it couldn't say.
    func commitMessageInput() async -> CommitMessageSuggestionInput? {
        guard canUseGit, let target = gitTarget,
              case .success(let reply) = await hostReply(timeout: .seconds(30), {
                  RemoteGitRequest.commitMessageInput(id: $0, projectID: target.projectID, path: target.worktree.path)
              }) else { return nil }
        return RemoteGitRequest.commitMessageInput(in: reply)
    }

    // MARK: Lifecycle

    /// The branch the session's worktree is on, when the host lets the phone rename it.
    var renamableBranch: String? {
        hub.supports(HostProtocolCapability.worktreesRenameBranchV1, on: hostID) ? gitTarget?.worktree.branch : nil
    }

    /// Renames the worktree's branch `from`, the one the user saw, so the host refuses a checkout
    /// switched since; then refreshes the changes. Returns the host's refusal, or nil.
    func renameBranch(from: String, to branch: String) async -> String? {
        guard let target = gitTarget else { return "This worktree can't be changed from here." }
        defer { refreshChanges() }
        return await hostRequest {
            RemoteGitRequest.renameBranch(id: $0, projectID: target.projectID, path: target.worktree.path,
                                          from: from, to: branch)
        }
    }

    /// A session this host runs itself; one a gateway relays lives on another Mac.
    var canArchive: Bool {
        hub.sessions(of: hostID).first { $0.id == sessionId }?.serverId == nil
            && hub.supports(HostProtocolCapability.sessionsV1, on: hostID)
    }

    /// Returns the host's refusal, worded for the user, or nil once the session is archived.
    func archiveSession() async -> String? {
        await hostRequest { RemoteGitRequest.archiveSession(id: $0, sessionID: self.sessionId) }
    }

    enum WorktreeRemoval { case archive, delete }

    /// The worktree as the user saw it when they asked, which every retry names again.
    struct RemovalTarget {
        let projectID: String
        let worktree: RemoteWorktreeSummary
    }

    /// The session's worktree, when removable: not the main checkout or a folder, and one the host
    /// can tell apart from a replacement.
    var removalTarget: RemovalTarget? {
        guard let target = gitTarget, target.worktree.isMain != true, target.worktree.isFolder != true,
              target.worktree.lineageID != nil, hub.supports(HostProtocolCapability.worktreesLifecycleV1, on: hostID)
        else { return nil }
        return RemovalTarget(projectID: target.projectID, worktree: target.worktree)
    }

    /// Archives or deletes `target`; a delete also deletes its branch once merged. Returns the
    /// host's refusal, which the user may overrule by asking again with `force` or `discard`.
    func removeWorktree(_ removal: WorktreeRemoval, of target: RemovalTarget, force: Bool, discard: Bool) async -> RemoteGitFailure? {
        let worktree = target.worktree
        // The host stops the worktree's sessions and terminals first, which can take minutes.
        return await hostFailure(timeout: .seconds(600)) { id in
            switch removal {
            case .archive:
                RemoteGitRequest.archiveWorktree(id: id, projectID: target.projectID, path: worktree.path,
                                                 lineageID: worktree.lineageID, branch: worktree.branch, discardUnsavedEdits: discard)
            case .delete:
                RemoteGitRequest.deleteWorktree(id: id, projectID: target.projectID, path: worktree.path, lineageID: worktree.lineageID,
                                                branch: worktree.branch, force: force, deleteBranchIfMerged: true,
                                                discardUnsavedEdits: discard)
            }
        }
    }

    // MARK: Runs

    /// A worktree this host lists, on a host that lists its run scripts.
    var canRun: Bool { gitTarget != nil && hub.supports(HostProtocolCapability.runsScriptsV1, on: hostID) }

    func refreshRunScripts() {
        guard canRun, let target = gitTarget, hub.state(of: hostID) == .online else { return }
        let id = hub.nextHostRequestId()
        runScriptsId = id
        send(.host(RemoteGitRequest.listRunScripts(id: id, projectID: target.projectID, path: target.worktree.path)))
    }

    /// Returns the host's refusal, worded for the user, or nil once it took the action.
    func run(_ action: RemoteRunAction, _ script: RemoteRunScript) async -> String? {
        guard let target = gitTarget else { return "This worktree can't run scripts from here." }
        return await hostRequest {
            RemoteGitRequest.run(id: $0, action, scriptKey: script.key, projectID: target.projectID, path: target.worktree.path)
        }
    }

    // MARK: Shepherd

    /// A session this host runs itself, on a host that lets the phone shepherd it.
    var canShepherd: Bool {
        hub.sessions(of: hostID).first { $0.id == sessionId }?.serverId == nil
            && hub.supports(HostProtocolCapability.shepherdsPhoneV1, on: hostID)
    }

    /// Asks the host for its session list, which carries the shepherd.
    func refreshShepherd() {
        guard canShepherd, hub.state(of: hostID) == .online else { return }
        let id = hub.nextHostRequestId()
        shepherdListId = id
        send(.host(RemoteShepherdRequest.list(id: id)))
    }

    /// ponytail: polls while the session is open, since the host pushes the phone no shepherd
    /// changes; an event subscription replaces it if the list gets heavy.
    private func pollShepherd(generation: Int) {
        Task { @MainActor [weak self] in
            // The first list goes out with the replay; this one keeps it fresh.
            while true {
                try? await Task.sleep(for: .seconds(20))
                guard let self, generation == self.watchGeneration else { return }
                self.refreshShepherd()
            }
        }
    }

    /// Ships, resumes, stops or switches the session's shepherd. Returns the host's refusal,
    /// worded for the user, or nil once it took it.
    func shepherd(_ action: RemoteShepherdAction) async -> String? {
        guard shepherdRunning == nil, canShepherd else { return "This session can't be shipped from here." }
        shepherdRunning = action
        defer {
            shepherdRunning = nil
            refreshShepherd()
        }
        return await hostRequest { RemoteShepherdRequest.act(id: $0, sessionID: self.sessionId, action: action) }
    }

    /// Sends the request `make` builds and waits for the host's answer, even if the screen that
    /// asked has gone. Returns the refusal, worded for the user, or nil once it succeeded.
    private func hostRequest(_ make: (Int) -> OpaqueHostMessage) async -> String? {
        await hostFailure(make)?.message
    }

    /// `hostRequest`, keeping whether the user may overrule the refusal.
    private func hostFailure(timeout: Duration = .seconds(120), _ make: (Int) -> OpaqueHostMessage) async -> RemoteGitFailure? {
        if case .failure(let failure) = await hostReply(timeout: timeout, make) { return failure }
        return nil
    }

    /// The host's answer to the request `make` builds, or why there was none.
    private func hostReply(timeout: Duration = .seconds(120),
                           _ make: (Int) -> OpaqueHostMessage) async -> Result<OpaqueHostMessage, RemoteGitFailure> {
        // A send while the link is down goes nowhere, and the reply would never come.
        guard hub.state(of: hostID) == .online else {
            let name = hub.hosts.first { $0.id == hostID }?.name ?? "the machine"
            return .failure(RemoteGitFailure("Not connected to \(name). Try again once it's back online."))
        }
        let id = hub.nextHostRequestId()
        let hold = activate()
        defer { hold.cancel() }
        send(.host(make(id)))
        // ponytail: a fixed wait; a push to a slow remote that outlasts it reads as lost.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finishHostRequest(id, .failure(RemoteGitFailure("The machine didn't answer. Check the session there.")))
        }
        return await withCheckedContinuation { hostWaiters[id] = $0 }
    }

    private func finishHostRequest(_ id: Int, _ result: Result<OpaqueHostMessage, RemoteGitFailure>) {
        hostWaiters.removeValue(forKey: id)?.resume(returning: result)
    }

    private func send(_ message: PhoneClientMessage) {
        hub.send(message, to: hostID)
    }

    private func receive(_ message: PhoneServerMessage) {
        switch message {
        case .host(let reply):
            if let id = runScriptsId, let found = RemoteGitRequest.runScripts(replying: id, in: reply) {
                runScripts = found
                return
            }
            if let id = reviewStatusId, let found = RemoteGitRequest.pullRequest(replying: id, in: reply) {
                pullRequest = found
                return
            }
            if let id = shepherdListId, let found = RemoteShepherdRequest.shepherd(of: sessionId, replying: id, in: reply) {
                shepherd = found
                shepherdLoaded = true
                return
            }
            for id in hostWaiters.keys {
                if let result = RemoteGitRequest.reply(to: id, in: reply) { return finishHostRequest(id, result.map { reply }) }
            }
        case .changeList(let id, let ref, let metrics, let files, let staged, let unstaged, let commits,
                         let truncated, let commitsTruncated, _, _) where id == sessionId:
            changes = .loaded(ChangeListReply(
                comparisonRef: ref, metricsAvailable: metrics, files: files, staged: staged, unstaged: unstaged,
                commits: commits, truncated: truncated, commitsTruncated: commitsTruncated))
        case .changeListFailed(let id, let reason, let message) where id == sessionId:
            changes = .failed(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil))
        case .fileDiffResult(let id, let path, let stage, let hunks, let truncated, let note) where id == sessionId:
            guard diff?.key == DiffKey(path: path, stage: stage) else { return }
            diff = (DiffKey(path: path, stage: stage), .loaded(DiffReply(hunks: hunks, truncated: truncated, metadataNote: note)))
        case .fileDiffFailed(let id, let path, let stage, let reason, let message) where id == sessionId:
            guard diff?.key == DiffKey(path: path, stage: stage) else { return }
            diff = (DiffKey(path: path, stage: stage), .failed(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)))
        case .commitFiles(let id, let sha, let files, let truncated) where id == sessionId:
            guard let open = commit?.commit, open.revision == sha else { return }
            commit = (open, .loaded(CommitFilesReply(files: files, truncated: truncated)))
        case .commitFilesFailed(let id, let sha, let reason, let message) where id == sessionId:
            guard let open = commit?.commit, open.revision == sha else { return }
            commit = (open, .failed(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)))
        case .commitDiffResult(let id, let sha, let path, let hunks, let truncated, let note) where id == sessionId:
            let key = DiffKey(path: path, stage: nil, sha: sha)
            guard diff?.key == key else { return }
            diff = (key, .loaded(DiffReply(hunks: hunks, truncated: truncated, metadataNote: note)))
        case .commitDiffFailed(let id, let sha, let path, let reason, let message) where id == sessionId:
            let key = DiffKey(path: path, stage: nil, sha: sha)
            guard diff?.key == key else { return }
            diff = (key, .failed(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)))
        case .fileTree(let id, let path, let nodes, let truncated) where id == sessionId:
            tree.apply(path: path, nodes: nodes)
            treeError = nil
            if truncated { truncatedDirs.insert(path ?? "") } else { truncatedDirs.remove(path ?? "") }
            if path == nil { for dir in tree.pathsToRefresh() { send(.listFiles(sessionId: sessionId, path: dir, comparisonMode: nil)) } }
        case .fileTreeFailed(let id, let path, let reason, let message) where id == sessionId:
            // A directory that failed to list must not stay open and empty.
            if let path, tree.children[path] == nil { tree.expanded.remove(path) }
            treeError = RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)
        case .fileContents(let id, let path, let text, let truncated, _) where id == sessionId:
            guard file?.path == path else { return }
            file = (path, .loaded(FileReply(text: text, truncated: truncated)))
        case .fileUnavailable(let id, let path, let reason, let byteSize, let message) where id == sessionId:
            guard file?.path == path else { return }
            file = (path, .failed(RemoteChangesRules.accessMessage(reason, message: message, byteSize: byteSize)))
        default:
            break
        }
    }
}
