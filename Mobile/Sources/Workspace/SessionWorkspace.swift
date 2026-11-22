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

/// Replies being waited for, by what they answer.
private typealias Waiters<K: Hashable, R> = [K: [CheckedContinuation<Result<R, RemoteGitFailure>, Never>]]

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
/// switch or a reconnect keeps the open review and tree. Replies are applied only for this session.
@MainActor @Observable
final class SessionWorkspace {
    private(set) var changes: Load<ChangeListReply> = .idle
    /// What Branch Changes and Commits compare against; nil follows the Mac's setting. Shared by every workspace.
    var comparisonMode: ChangesComparisonMode? {
        get { ChangesComparison.shared.mode }
        set {
            guard newValue != ChangesComparison.shared.mode else { return }
            ChangesComparison.shared.mode = newValue
            refreshIfComparisonChanged()
        }
    }
    /// The mode the loaded changes were asked with.
    @ObservationIgnored private var changesMode: ChangesComparisonMode?
    @ObservationIgnored private var changesFlight = RemoteSingleFlight()

    /// Notes the change list answered; true when a newer refresh was waiting and went out instead.
    private func changeListLanded() -> Bool {
        guard changesFlight.landed() else { return false }
        refreshChanges()
        return true
    }

    /// Reloads the changes when another workspace changed the mode.
    func refreshIfComparisonChanged() {
        if case .idle = changes { return }
        guard changesMode != comparisonMode else { return }
        refreshChanges()
    }
    /// Counts the host coming back online; an open review refreshes on it, since what it loaded may be stale.
    private(set) var reconnects = 0
    /// The review pushed from the Changes tab, a commit's files or a file's history.
    private(set) var review: (source: ReviewSource, focus: ReviewEntryID?)?
    @ObservationIgnored private var diffWaiters: Waiters<DiffKey, DiffReply> = [:]
    @ObservationIgnored private var commitFilesWaiters: Waiters<String, CommitFilesReply> = [:]
    /// Keyed by nothing: every wait for the change list takes the next one.
    @ObservationIgnored private var changesWaiters: Waiters<Bool, ChangeListReply> = [:]
    /// Each pending wait's request deadline, by its waiters' key path and key.
    @ObservationIgnored private var waitTimers: [[AnyHashable]: Task<Void, Never>] = [:]
    /// The commit whose files are open, pushed from the Commits section.
    private(set) var commit: (commit: RemoteCommit, Load<CommitFilesReply>)?
    private(set) var tree = RemoteFileTree()
    private(set) var file: (path: String, Load<FileReply>)?
    /// The open file is a skill's `SKILL.md`, named by its command.
    @ObservationIgnored private var fileIsSkill = false
    /// The screen that pushed the open review or file. The session can be open in several tabs at once;
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
    /// An idle refresh that arrived while a review was open; it runs when the review closes.
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
    /// Cards waiting on a file's text, by path.
    @ObservationIgnored private var peekWaiters: [String: [CheckedContinuation<String?, Never>]] = [:]
    /// The session's PR shepherd, once the host's session list said; nil without one.
    private(set) var shepherd: RemoteShepherd?
    /// Ship would publish a stack for this session, which has no shepherd yet.
    private(set) var shipsStack = false
    private(set) var shepherdLoaded = false
    private(set) var shepherdRunning: RemoteShepherdAction?
    /// The worktree's pull request, once the host reported one.
    private(set) var pullRequest: RemotePullRequest?
    @ObservationIgnored private var reviewStatusId: Int?
    /// The worktree's run scripts, once listed.
    private(set) var runScripts: [RemoteRunScript] = []
    @ObservationIgnored private var runScriptsId: Int?
    @ObservationIgnored private var shepherdListId: Int?
    /// `readWorktree` requests awaiting their answer: what each asked, and of which member's worktree.
    @ObservationIgnored private var memberReads: [Int: (read: RemoteWorktreeRead.Read, worktreeId: String)] = [:]
    /// The member worktree the loaded changes, tree and open views belong to; nil outside a checkout.
    @ObservationIgnored private var memberStateOwner: String?

    init(hub: HostHub, hostID: UUID, sessionId: String) {
        self.hub = hub
        self.hostID = hostID
        self.sessionId = sessionId
    }

    /// True while a view `owner` pushed (a review or a file) is open.
    func hasPushedChild(_ owner: UUID) -> Bool { pushedBy == owner && (review != nil || file != nil || commit != nil) }

    // MARK: Lifecycle

    /// Listens while any screen showing the session holds the token; the last release stops.
    /// The first holder asks again for whatever is open, since replies sent while nobody listened
    /// were dropped and the host may have reconnected meanwhile.
    func activate() -> ListenerToken {
        holders += 1
        if holders == 1 {
            listener = hub.addListener(hostID) { [weak self] in self?.receive($0) }
            hostWasOnline = hub.state(of: hostID) == .online
            // The focus may have moved while nobody listened; drop what the previous member showed first.
            followFocus(reload: false)
            if hostWasOnline { replay() }
            watchGeneration += 1
            watchHost(generation: watchGeneration)
            watchFocus(generation: watchGeneration)
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
        if online, !hostWasOnline {
            replay()
            reconnects += 1
        }
    }

    /// Follows the focused member while the session is open: the host can drop the focused one from
    /// its list, or a pick land, and the focus moves without `focusMember`.
    private func watchFocus(generation: Int) {
        guard generation == watchGeneration else { return }
        withObservationTracking {
            _ = focusedMember?.worktreeId
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchFocus(generation: generation) }
        }
        followFocus()
    }

    /// Asks again for whatever is open; the host forgot everything it was asked while away.
    private func replay() {
        changesFlight.reset()
        // The host forgot the reads it was asked; each is asked again below.
        memberReads.removeAll()
        if case .idle = changes {} else { refreshChanges() }
        if let commit { sendRead(.commitFiles(sha: commit.commit.revision)) }
        for key in diffWaiters.keys { requestDiff(key) }
        for sha in commitFilesWaiters.keys where sha != commit?.commit.revision { sendRead(.commitFiles(sha: sha)) }
        if treeRequested { loadTree() }
        refreshShepherd()
        refreshRunScripts()
        if let file {
            self.file = (file.path, .loading)
            // A skill's path is its command, which only `readSkill` reads.
            if fileIsSkill { send(.readSkill(sessionId: sessionId, command: file.path)) } else { sendRead(.file(path: file.path)) }
        }
    }

    // MARK: Changes

    func refreshChanges() {
        if case .loaded = changes {} else { changes = .loading }
        guard changesFlight.shouldSend() else { return }
        changesMode = comparisonMode
        sendRead(.changes(comparisonMode: comparisonMode))
        refreshPullRequest()
    }

    /// Asks the host to read the worktree's pull request again; its answer replaces `pullRequest`.
    private func refreshPullRequest() {
        guard canUseGit, let target = repositoryTarget, hub.state(of: hostID) == .online else { return }
        let id = hub.nextHostRequestId()
        reviewStatusId = id
        send(.host(RemoteGitRequest.reviewStatus(id: id, projectID: target.projectID, path: target.worktree.path)))
    }

    func openReview(_ source: ReviewSource, focus: ReviewEntryID?, by owner: UUID) {
        pushedBy = owner
        review = (source, focus)
    }

    func closeReview() {
        review = nil
        if refreshDeferred { scheduleRefresh() }
    }

    /// One file's diff. Loads of the same key share one request.
    func loadDiff(_ key: DiffKey) async -> Result<DiffReply, RemoteGitFailure> {
        await wait(\.diffWaiters, key) { requestDiff(key) }
    }

    /// A commit's files, without opening it.
    func loadCommitFiles(_ sha: String) async -> Result<CommitFilesReply, RemoteGitFailure> {
        await wait(\.commitFilesWaiters, sha) { sendRead(.commitFiles(sha: sha)) }
    }

    /// Refreshes the change list and returns it once it lands.
    func loadChanges() async -> Result<ChangeListReply, RemoteGitFailure> {
        await wait(\.changesWaiters, true) { refreshChanges() }
    }

    /// Asks with `request` unless a wait for `key` already did, and waits for the reply, even if the
    /// screen that asked has gone.
    private func wait<K: Hashable, R: Sendable>(_ waiters: ReferenceWritableKeyPath<SessionWorkspace, Waiters<K, R>>, _ key: K,
                                      request: () -> Void) async -> Result<R, RemoteGitFailure> {
        guard hub.state(of: hostID) == .online else { return .failure(offline) }
        let hold = activate()
        defer { hold.cancel() }
        if self[keyPath: waiters][key] == nil {
            request()
            // One timer per request, so a wait that joins late shares the request's deadline, not an earlier caller's.
            waitTimers[[AnyHashable(waiters), AnyHashable(key)]] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.resume(waiters, key, .failure(RemoteGitFailure("The machine didn't answer. Check the session there.")))
            }
        }
        return await withCheckedContinuation { self[keyPath: waiters][key, default: []].append($0) }
    }

    private func resume<K: Hashable, R: Sendable>(_ waiters: ReferenceWritableKeyPath<SessionWorkspace, Waiters<K, R>>, _ key: K,
                                        _ result: Result<R, RemoteGitFailure>) {
        waitTimers.removeValue(forKey: [AnyHashable(waiters), AnyHashable(key)])?.cancel()
        self[keyPath: waiters].removeValue(forKey: key)?.forEach { $0.resume(returning: result) }
    }

    private func requestDiff(_ key: DiffKey) {
        if let sha = key.sha {
            sendRead(.commitDiff(sha: sha, path: key.path))
        } else {
            sendRead(.fileDiff(path: key.path, stage: key.stage, comparisonMode: comparisonMode))
        }
    }

    func openCommit(_ commit: RemoteCommit, by owner: UUID) {
        pushedBy = owner
        self.commit = (commit, .loading)
        sendRead(.commitFiles(sha: commit.revision))
    }

    func closeCommit() {
        commit = nil
        if case .commit = review?.source { closeReview() }
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
        guard review == nil else {
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
        sendRead(.files(path: nil))
    }

    func toggle(_ dir: String) {
        if tree.expanded.remove(dir) != nil { return }
        tree.expanded.insert(dir)
        // Always re-lists: a collapsed directory misses the refreshes, so its cached listing shows only until the reply.
        sendRead(.files(path: dir))
    }

    /// What a checkout's link to a file in none of its members tells the user.
    static let linkOutsideMembers = "This file isn't in one of the workspace's repositories."

    /// Opens `path`, relative to the checkout's root, in the member that holds it. False when this is
    /// no checkout or no member holds the path.
    @discardableResult
    func openCheckoutLink(rootRelative path: String, by owner: UUID) -> Bool {
        guard let match = checkout?.memberFile(atRootRelative: path) else { return false }
        focusMember(match.member.id)
        openFile(match.relativePath, by: owner)
        return true
    }

    /// `path`, an image's path in the repository the viewer shows, as the host's transcript image reader
    /// takes it. A checkout session's images are read against the checkout's root, not the member's, so a
    /// member's file is named by its absolute path; a URL or an absolute path stays as it is.
    func imageSource(forRepositoryPath path: String) -> String {
        guard let member = focusedMember, !path.hasPrefix("/"), URL(string: path)?.scheme == nil else { return path }
        return member.worktree.path + "/" + path
    }

    func openFile(_ path: String, by owner: UUID) {
        pushedBy = owner
        file = (path, .loading)
        fileIsSkill = false
        sendRead(.file(path: path))
    }

    /// Opens a skill command's `SKILL.md`, which the host reads by command.
    func openSkill(_ command: String, by owner: UUID) {
        pushedBy = owner
        file = (command, .loading)
        fileIsSkill = true
        send(.readSkill(sessionId: sessionId, command: command))
    }

    /// A file's text without opening it, for a card that shows part of it; `sessionPath` is relative
    /// to where the session works, a checkout's root in a workspace checkout. Nil when the host can't
    /// read it or doesn't answer within 10 s, and in a checkout when the file isn't in the focused
    /// member: peeking never moves the focus.
    func peekFile(_ sessionPath: String) async -> String? {
        guard hub.state(of: hostID) == .online else { return nil }
        let path: String
        if let checkout {
            guard let found = checkout.memberFile(atRootRelative: sessionPath),
                  found.member.id == focusedMemberID else { return nil }
            path = found.relativePath
        } else {
            path = sessionPath
        }
        if peekWaiters[path] == nil { sendRead(.file(path: path)) }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.peekWaiters.removeValue(forKey: path)?.forEach { $0.resume(returning: nil) }
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { peekWaiters[path, default: []].append($0) }
    }

    func closeFile() {
        file = nil
        fileIsSkill = false
    }

    // MARK: Workspace checkout

    /// The workspace checkout the session works in, keeping only the members this connection can
    /// name; nil for a session in a worktree of its own, or one a gateway relays from another Mac.
    var checkout: RemoteSessionCheckout? {
        guard let summary = hub.sessions(of: hostID).first(where: { $0.id == sessionId }), summary.serverId == nil,
              let checkout = summary.checkout,
              // Without `readWorktree` the host answers only for the session, as it did before checkouts.
              hub.supports(HostProtocolCapability.worktreesReadV1, on: hostID),
              hub.supports(HostProtocolCapability.workspacesPhoneV1, on: hostID) else { return nil }
        // An SSH member's summary carries a display path (`host:/repo`), as `ownWorktreeTarget` notes.
        return RemoteSessionCheckout(id: checkout.id, name: checkout.name, branch: checkout.branch, rootPath: checkout.rootPath,
                                     members: checkout.members.filter { $0.worktree.path.hasPrefix("/") })
    }

    /// The member repository Changes and Files read: the one last picked for this checkout, in any
    /// session of it, while it's still listed, else the first.
    var focusedMember: RemoteSessionCheckout.Member? {
        guard let checkout else { return nil }
        let preferred = CheckoutFocus.shared.member(of: checkout.id)
        return checkout.members.first { $0.id == preferred } ?? checkout.members.first
    }

    var focusedMemberID: String? { focusedMember?.id }

    /// Reads member `id` from now on, here and in every other open session of the checkout. What the
    /// previous member showed is dropped, and any reply still on its way for it is ignored; the
    /// loaded tabs ask again.
    func focusMember(_ id: String) {
        guard let checkout, id != focusedMemberID, checkout.members.contains(where: { $0.id == id }) else { return }
        CheckoutFocus.shared.setMember(id, of: checkout.id)
        followFocus()
    }

    /// Resets what the previous member showed when the focused member's worktree is no longer the
    /// one it was loaded for.
    /// `reload`: ask again now; else the next `replay` does.
    private func followFocus(reload: Bool = true) {
        let current = focusedMember?.worktreeId
        guard current != memberStateOwner else { return }
        memberStateOwner = current
        resetMemberState(reload: reload)
    }

    /// Drops what the previous member showed, failing the waits on it, and asks again for whatever
    /// tab was loaded. Replies still on their way for the previous member are ignored.
    private func resetMemberState(reload: Bool) {
        let changesWereLoaded = if case .idle = changes { false } else { true }
        // Forgetting the reads in flight drops their replies, which name the previous member's worktree.
        memberReads.removeAll()
        changesFlight.reset()
        changesMode = nil
        changes = .idle
        refreshTask?.cancel()
        refreshDeferred = false
        tree = RemoteFileTree()
        truncatedDirs = []
        treeError = nil
        review = nil
        commit = nil
        file = nil
        fileIsSkill = false
        pullRequest = nil
        runScripts = []
        let switched = RemoteGitFailure("You switched to another repository.")
        for key in Array(diffWaiters.keys) { resume(\.diffWaiters, key, .failure(switched)) }
        for sha in Array(commitFilesWaiters.keys) { resume(\.commitFilesWaiters, sha, .failure(switched)) }
        for waiters in peekWaiters.values { waiters.forEach { $0.resume(returning: nil) } }
        peekWaiters.removeAll()
        guard reload, hub.state(of: hostID) == .online else {
            // Not idle, so the replay asks for them again.
            if changesWereLoaded { changes = .loading }
            return
        }
        if changesWereLoaded { refreshChanges() } else { refreshPullRequest() }
        if treeRequested { loadTree() }
        refreshRunScripts()
    }

    /// The repository the session's reads name: the focused member in a workspace checkout, else the
    /// session's own worktree.
    var repositoryTarget: (projectID: String, worktreeId: String?, worktree: RemoteWorktreeSummary)? {
        if checkout != nil {
            guard let member = focusedMember else { return nil }
            return (member.projectId, member.worktreeId, member.worktree)
        }
        guard let target = ownWorktreeTarget else { return nil }
        return (target.projectID, hub.sessions(of: hostID).first { $0.id == sessionId }?.worktreeId, target.worktree)
    }

    /// Asks for `read`: of the session's own worktree by its id, or, in a workspace checkout, of the
    /// focused member's through `readWorktree`.
    private func sendRead(_ read: RemoteWorktreeRead.Read) {
        guard checkout != nil else {
            if let message = sessionRead(read) { send(message) }
            return
        }
        guard let target = repositoryTarget, let worktreeId = target.worktreeId else {
            // Answered on the next turn, so a wait that asked has registered for it.
            Task { @MainActor [weak self] in
                self?.refuse(read, RemoteGitFailure("This workspace checkout has no repository the phone can open."))
            }
            return
        }
        let id = hub.nextHostRequestId()
        memberReads[id] = (read, worktreeId)
        send(.host(RemoteWorktreeRead.request(id: id, projectID: target.projectID, path: target.worktree.path, read: read)))
    }

    /// `read` as the session-addressed message a host answers for the session's own worktree.
    private func sessionRead(_ read: RemoteWorktreeRead.Read) -> PhoneClientMessage? {
        switch read {
        case .changes(let mode): .listChanges(sessionId: sessionId, comparisonMode: mode)
        case .fileDiff(let path, let stage, let mode): .fileDiff(sessionId: sessionId, path: path, stage: stage, comparisonMode: mode)
        case .files(let path): .listFiles(sessionId: sessionId, path: path, comparisonMode: nil)
        case .commitFiles(let sha): .listCommitFiles(sessionId: sessionId, sha: sha)
        case .commitDiff(let sha, let path): .commitFileDiff(sessionId: sessionId, sha: sha, path: path)
        case .file(let path): .readFile(sessionId: sessionId, path: path)
        // File history goes through its own host request.
        case .fileHistory: nil
        }
    }

    /// Shows the host's refusal of `read` where its reply would have landed.
    private func refuse(_ read: RemoteWorktreeRead.Read, _ failure: RemoteGitFailure) {
        switch read {
        case .changes:
            if changeListLanded() { return }
            changes = .failed(failure.message)
            resume(\.changesWaiters, true, .failure(failure))
        case .fileDiff(let path, let stage, _):
            resume(\.diffWaiters, DiffKey(path: path, stage: stage), .failure(failure))
        case .commitDiff(let sha, let path):
            resume(\.diffWaiters, DiffKey(path: path, stage: nil, sha: sha), .failure(failure))
        case .commitFiles(let sha):
            resume(\.commitFilesWaiters, sha, .failure(failure))
            guard let open = commit?.commit, open.revision == sha else { return }
            commit = (open, .failed(failure.message))
        case .files(let path):
            if let path, tree.children[path] == nil { tree.expanded.remove(path) }
            treeError = failure.message
        case .file(let path):
            peekWaiters.removeValue(forKey: path)?.forEach { $0.resume(returning: nil) }
            guard file?.path == path, !fileIsSkill else { return }
            file = (path, .failed(failure.message))
        case .fileHistory:
            break
        }
    }

    /// Whether a reply addressed to `id` is this session's: its own, or the focused member's worktree.
    private func accepts(_ id: String) -> Bool {
        id == sessionId || id == focusedMember?.worktreeId
    }

    // MARK: Replies

    // MARK: Git

    /// The session's own worktree on its host, the only one the phone renames, archives or deletes;
    /// git, reviews and runs name `repositoryTarget`. A session a gateway relays lives on another Mac,
    /// whose worktrees this connection can't name; nor can it name one in an SSH project, whose
    /// summary carries a display path (`host:/repo`), not the stored one.
    private var ownWorktreeTarget: (projectID: String, worktree: RemoteWorktreeSummary)? {
        guard let summary = hub.sessions(of: hostID).first(where: { $0.id == sessionId }), summary.serverId == nil,
              let projectID = summary.projectId, let worktree = summary.worktree, worktree.path.hasPrefix("/") else { return nil }
        return (projectID, worktree)
    }

    var canUseGit: Bool {
        repositoryTarget != nil && (hub.supports(HostProtocolCapability.worktreesGitPhoneV1, on: hostID)
            || hub.supports(HostProtocolCapability.worktreesGitV1, on: hostID))
    }

    /// Whether working-tree hunks can be staged, unstaged or discarded one by one.
    var canChangeHunks: Bool {
        guard repositoryTarget != nil else { return false }
        return hub.supports(HostProtocolCapability.worktreesHunksPhoneV1, on: hostID)
            || hub.supports(HostProtocolCapability.worktreesHunksV1, on: hostID) && hub.supports(HostProtocolCapability.worktreesGitV1, on: hostID)
    }

    /// Applies `action` to `hunk`, the `index`th of `key`'s working-tree diff. Returns the host's refusal, or nil.
    func changeHunk(_ action: RemoteHunkAction, index: Int, _ hunk: RemoteDiffHunk, in key: DiffKey) async -> String? {
        guard key.sha == nil else { return "This diff can't be changed from here." }
        return await git(.hunk(path: key.path, index: index, header: hunk.header, linesHash: hunk.linesHash, action: action))
    }

    /// Runs `change` on the repository the session works on and refreshes the change list. Returns the host's
    /// refusal, worded for the user, or nil once it succeeded.
    func git(_ change: RemoteGitChange) async -> String? {
        guard gitRunning == nil, let target = repositoryTarget else { return "This worktree can't be changed from here." }
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
    var canReadFileHistory: Bool {
        repositoryTarget != nil && hub.supports(HostProtocolCapability.worktreesFileHistoryV1, on: hostID)
    }

    /// The commits that touched `path`, newest first.
    func fileHistory(_ path: String) async -> Result<(entries: [HostFileHistoryEntry], truncated: Bool), RemoteGitFailure> {
        guard let target = repositoryTarget else { return .failure(RemoteGitFailure("This worktree's history isn't available here.")) }
        var id = 0
        let reply = await hostReply(timeout: .seconds(30)) {
            id = $0
            return RemoteFileHistoryRequest.request(id: $0, projectID: target.projectID, worktreePath: target.worktree.path, path: path)
        }
        switch reply {
        case .failure(let failure): return .failure(failure)
        case .success(let message):
            switch RemoteFileHistoryRequest.result(replying: id, in: message) {
            case .success(let entries, let truncated)?: return .success((entries, truncated))
            case .failure(_, let message)?: return .failure(RemoteGitFailure(message ?? "Couldn't read this file's history."))
            case nil: return .failure(RemoteGitFailure("Couldn't read this file's history."))
            }
        }
    }

    func commitMessageInput() async -> CommitMessageSuggestionInput? {
        guard canUseGit, let target = repositoryTarget,
              case .success(let reply) = await hostReply(timeout: .seconds(30), {
                  RemoteGitRequest.commitMessageInput(id: $0, projectID: target.projectID, path: target.worktree.path)
              }) else { return nil }
        return RemoteGitRequest.commitMessageInput(in: reply)
    }

    // MARK: Reviews

    /// The Mac's draft reviews of the repository's worktree, its comments readable and changeable from here.
    var canReview: Bool {
        repositoryTarget != nil && (hub.supports(HostProtocolCapability.reviewsPhoneV1, on: hostID)
            || hub.supports(HostProtocolCapability.reviewsV1, on: hostID))
    }

    func reviews() async -> Result<[RemoteReviewSummary], RemoteGitFailure> {
        guard let target = repositoryTarget else { return .failure(RemoteGitFailure("This worktree's reviews can't be read from here.")) }
        return await hostReply { RemoteReviewRequest.list(id: $0, projectID: target.projectID, path: target.worktree.path) }
            .flatMap { Self.readable(RemoteReviewRequest.reviews(in: $0)) }
    }

    func review(_ sessionID: String) async -> Result<RemoteReview, RemoteGitFailure> {
        guard let target = repositoryTarget else { return .failure(RemoteGitFailure("This worktree's reviews can't be read from here.")) }
        return await hostReply {
            RemoteReviewRequest.read(id: $0, projectID: target.projectID, path: target.worktree.path, sessionID: sessionID)
        }
        .flatMap { Self.readable(RemoteReviewRequest.review(in: $0)) }
    }

    /// Whether the host reads and answers a pull or merge request review's threads for the phone.
    var canReadPullRequestThreads: Bool {
        repositoryTarget != nil && (hub.supports(HostProtocolCapability.reviewsProviderPhoneV1, on: hostID)
            || hub.supports(HostProtocolCapability.reviewsProviderV1, on: hostID))
    }

    /// Review `sessionID`'s pull or merge request threads, fetched from its provider by the host; its raw diff too when `withDiff`.
    func pullRequestReview(_ sessionID: String, withDiff: Bool) async -> Result<RemoteProviderReview, RemoteGitFailure> {
        guard let target = repositoryTarget else { return .failure(RemoteGitFailure("This pull request can't be read from here.")) }
        return await hostReply {
            RemoteReviewRequest.readProvider(id: $0, projectID: target.projectID, path: target.worktree.path, sessionID: sessionID,
                                             withDiff: withDiff)
        }
        .mapError { RemoteGitFailure(RemoteReviewRequest.providerFailureMessage($0.message)) }
        .flatMap { Self.readable(RemoteReviewRequest.providerReview(in: $0)) }
    }

    /// Replies to, resolves or unresolves a thread on the provider, as the host's user.
    /// Returns the host's refusal, worded for the user, or nil once it's done.
    func changeThread(_ sessionID: String, threadID: String, _ action: RemoteProviderThreadAction, body: String? = nil) async -> String? {
        guard let target = repositoryTarget else { return "This pull request can't be changed from here." }
        return await hostRequest {
            RemoteReviewRequest.mutateThread(id: $0, projectID: target.projectID, path: target.worktree.path,
                                             sessionID: sessionID, threadID: threadID, action, body: body)
        }
        .map(RemoteReviewRequest.providerFailureMessage)
    }

    /// Submits review `sessionID` on the provider with its open line drafts, as the host's user,
    /// pinned to `headSHA`, the head the phone showed. Succeeds with what it couldn't post, if anything.
    func submitReview(_ sessionID: String, _ decision: RemoteReviewDecision, body: String,
                      headSHA: String?) async -> Result<String?, RemoteGitFailure> {
        guard let target = repositoryTarget else { return .failure(RemoteGitFailure("This review can't be submitted from here.")) }
        // Each draft may be its own provider call; a phone giving up early would invite a duplicate submission.
        return await hostReply(timeout: .seconds(300)) {
            RemoteReviewRequest.publish(id: $0, projectID: target.projectID, path: target.worktree.path,
                                        sessionID: sessionID, decision, body: body, headSHA: headSHA)
        }
        .map { RemoteReviewRequest.publishProblems(in: $0) }
        .mapError { RemoteGitFailure(RemoteReviewRequest.providerFailureMessage($0.message)) }
    }

    /// Whether the host sends a review's comments to an agent chat for the phone.
    var canSendReviewToAgent: Bool {
        repositoryTarget != nil && hub.supports(HostProtocolCapability.reviewsAgentPhoneV1, on: hostID)
    }

    /// Where the Mac would send review `sessionID`, this chat first.
    func reviewAgentTargets(_ sessionID: String) async -> Result<[RemoteAgentTarget], RemoteGitFailure> {
        guard let target = repositoryTarget else { return .failure(RemoteGitFailure("This review can't be sent from here.")) }
        return await hostReply {
            RemoteReviewRequest.agentTargets(id: $0, projectID: target.projectID, path: target.worktree.path, sessionID: sessionID)
        }
        .flatMap { Self.readable(RemoteReviewRequest.agentTargets(in: $0)) }
        .map { targets in targets.filter(isThisChat) + targets.filter { !isThisChat($0) } }
    }

    func isThisChat(_ target: RemoteAgentTarget) -> Bool {
        target.kind == .existingSession && target.sessionID == sessionId
    }

    /// Sends review `sessionID`'s open comments to `agent`; the Mac marks them sent.
    /// Returns the host's refusal, worded for the user, or nil once the agent took them.
    func sendReview(_ sessionID: String, to agent: RemoteAgentTarget) async -> String? {
        guard let target = repositoryTarget else { return "This review can't be sent from here." }
        // A new chat on the Mac can take a while to start; a phone giving up early would invite a second send.
        return await hostFailure(timeout: .seconds(300)) {
            RemoteReviewRequest.sendToAgent(id: $0, projectID: target.projectID, path: target.worktree.path,
                                            sessionID: sessionID, target: agent)
        }?.message
    }

    private static func readable<T>(_ value: T?) -> Result<T, RemoteGitFailure> {
        value.map(Result.success) ?? .failure(RemoteGitFailure("The machine's answer couldn't be read."))
    }

    /// Returns the host's refusal, worded for the user, or nil once the comment changed.
    func changeReview(_ sessionID: String, _ mutation: RemoteReviewMutation) async -> String? {
        guard let target = repositoryTarget else { return "This worktree's reviews can't be changed from here." }
        return await hostRequest {
            RemoteReviewRequest.mutate(id: $0, projectID: target.projectID, path: target.worktree.path, sessionID: sessionID, mutation)
        }
    }

    /// Comments on `entry` in review `sessionID`, filed under its stage as the Mac's Review workspace files it.
    /// Returns the host's refusal, or nil.
    /// `originalPath`: a renamed file's old path, which a merge request comment needs to publish.
    func comment(in sessionID: String, entry: ReviewEntryID, originalPath: String?, anchor: RemoteReviewAnchor, body: String) async -> String? {
        await changeReview(sessionID, .add(fileID: RemoteReviewFileID(namespace: entry.namespace, path: entry.path),
                                           path: entry.path, originalPath: originalPath, anchor: anchor, body: body))
    }

    /// The repository worktree's local-changes review, where the Mac's Review workspace files working-tree comments.
    var localChangesReviewID: String? {
        guard let target = repositoryTarget, let worktreeID = target.worktreeId else { return nil }
        return RemoteReviewRequest.localChangesSessionID(worktreeID: worktreeID, worktreePath: target.worktree.path)
    }

    // MARK: Lifecycle

    /// The branch the session's worktree is on, when the host lets the phone rename it.
    var renamableBranch: String? {
        hub.supports(HostProtocolCapability.worktreesRenameBranchV1, on: hostID) ? ownWorktreeTarget?.worktree.branch : nil
    }

    /// Renames the worktree's branch `from`, the one the user saw, so the host refuses a checkout
    /// switched since; then refreshes the changes. Returns the host's refusal, or nil.
    func renameBranch(from: String, to branch: String) async -> String? {
        guard let target = ownWorktreeTarget else { return "This worktree can't be changed from here." }
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

    /// The session's own worktree, never a checkout member, when removable: not the main checkout or a folder, and one the host
    /// can tell apart from a replacement.
    var removalTarget: RemovalTarget? {
        guard let target = ownWorktreeTarget, target.worktree.isMain != true, target.worktree.isFolder != true,
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
    var canRun: Bool { repositoryTarget != nil && hub.supports(HostProtocolCapability.runsScriptsV1, on: hostID) }

    func refreshRunScripts() {
        guard canRun, let target = repositoryTarget, hub.state(of: hostID) == .online else { return }
        let id = hub.nextHostRequestId()
        runScriptsId = id
        send(.host(RemoteGitRequest.listRunScripts(id: id, projectID: target.projectID, path: target.worktree.path)))
    }

    /// Follows an accepted launch by its run ID, independently of the screen that asked for it.
    func run(_ action: RemoteRunAction, _ script: RemoteRunScript, openConsole: @escaping PhoneRunTracker.OpenConsole) async -> String? {
        guard let target = repositoryTarget else { return "This worktree can't run scripts from here." }
        let result = await hostReply {
            RemoteGitRequest.run(id: $0, action, scriptKey: script.key, projectID: target.projectID, path: target.worktree.path)
        }
        switch result {
        case .success(let reply):
            if let runID = RemoteGitRequest.startedRunID(in: reply) { hub.followRun(runID, on: hostID, openConsole: openConsole) }
            return nil
        case .failure(let failure): return failure.message
        }
    }

    // MARK: Shepherd

    /// A session this host runs itself in its own worktree, on a host that lets the phone shepherd it.
    /// A workspace checkout's session has no worktree of its own, and the shepherd refuses it, as on the Mac.
    var canShepherd: Bool {
        guard let summary = hub.sessions(of: hostID).first(where: { $0.id == sessionId }) else { return false }
        return summary.serverId == nil && summary.worktreeId != nil
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
        guard hub.state(of: hostID) == .online else { return .failure(offline) }
        let id = hub.nextHostRequestId()
        let hold = activate()
        defer { hold.cancel() }
        // ponytail: a fixed wait; a push to a slow remote that outlasts it reads as lost.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finishHostRequest(id, .failure(RemoteGitFailure("The machine didn't answer. Check the session there.")))
        }
        return await withCheckedContinuation {
            hostWaiters[id] = $0
            send(.host(make(id)))
        }
    }

    private var offline: RemoteGitFailure {
        let name = hub.hosts.first { $0.id == hostID }?.name ?? "the machine"
        return RemoteGitFailure("Not connected to \(name). Try again once it's back online.")
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
            if !memberReads.isEmpty, let id = RemoteGitRequest.responseID(in: reply), memberReads[id] != nil,
               let result = RemoteWorktreeRead.reply(to: id, in: reply), let pending = memberReads.removeValue(forKey: id) {
                // A member the focus left since, as when it's no longer listed.
                guard pending.worktreeId == focusedMember?.worktreeId else { return }
                switch result {
                case .success(let inner): receive(inner)
                case .failure(let failure): refuse(pending.read, failure)
                }
                return
            }
            if let id = runScriptsId, let found = RemoteGitRequest.runScripts(replying: id, in: reply) {
                runScripts = found
                return
            }
            if let id = reviewStatusId, let found = RemoteGitRequest.pullRequest(replying: id, in: reply) {
                pullRequest = found
                return
            }
            if let id = shepherdListId, let found = RemoteShepherdRequest.listing(of: sessionId, replying: id, in: reply) {
                shepherd = found.shepherd
                shipsStack = found.shipsStack
                shepherdLoaded = true
                return
            }
            for id in hostWaiters.keys {
                if let result = RemoteGitRequest.reply(to: id, in: reply) { return finishHostRequest(id, result.map { reply }) }
            }
        case .changeList(let id, let ref, let metrics, let files, let staged, let unstaged, let commits,
                         let truncated, let commitsTruncated, _, _) where accepts(id):
            if changeListLanded() { return }
            let reply = ChangeListReply(
                comparisonRef: ref, metricsAvailable: metrics, files: files, staged: staged, unstaged: unstaged,
                commits: commits, truncated: truncated, commitsTruncated: commitsTruncated)
            changes = .loaded(reply)
            resume(\.changesWaiters, true, .success(reply))
        case .changeListFailed(let id, let reason, let message) where accepts(id):
            if changeListLanded() { return }
            let text = RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)
            changes = .failed(text)
            resume(\.changesWaiters, true, .failure(RemoteGitFailure(text)))
        case .fileDiffResult(let id, let path, let stage, let hunks, let truncated, let note) where accepts(id):
            resume(\.diffWaiters, DiffKey(path: path, stage: stage), .success(DiffReply(hunks: hunks, truncated: truncated, metadataNote: note)))
        case .fileDiffFailed(let id, let path, let stage, let reason, let message) where accepts(id):
            resume(\.diffWaiters, DiffKey(path: path, stage: stage),
                   .failure(RemoteGitFailure(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil))))
        case .commitFiles(let id, let sha, let files, let truncated) where accepts(id):
            let reply = CommitFilesReply(files: files, truncated: truncated)
            resume(\.commitFilesWaiters, sha, .success(reply))
            guard let open = commit?.commit, open.revision == sha else { return }
            commit = (open, .loaded(reply))
        case .commitFilesFailed(let id, let sha, let reason, let message) where accepts(id):
            let text = RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)
            resume(\.commitFilesWaiters, sha, .failure(RemoteGitFailure(text)))
            guard let open = commit?.commit, open.revision == sha else { return }
            commit = (open, .failed(text))
        case .commitDiffResult(let id, let sha, let path, let hunks, let truncated, let note) where accepts(id):
            resume(\.diffWaiters, DiffKey(path: path, stage: nil, sha: sha), .success(DiffReply(hunks: hunks, truncated: truncated, metadataNote: note)))
        case .commitDiffFailed(let id, let sha, let path, let reason, let message) where accepts(id):
            resume(\.diffWaiters, DiffKey(path: path, stage: nil, sha: sha),
                   .failure(RemoteGitFailure(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil))))
        case .fileTree(let id, let path, let nodes, let truncated) where accepts(id):
            tree.apply(path: path, nodes: nodes)
            treeError = nil
            if truncated { truncatedDirs.insert(path ?? "") } else { truncatedDirs.remove(path ?? "") }
            if path == nil { for dir in tree.pathsToRefresh() { sendRead(.files(path: dir)) } }
        case .fileTreeFailed(let id, let path, let reason, let message) where accepts(id):
            // A directory that failed to list must not stay open and empty.
            if let path, tree.children[path] == nil { tree.expanded.remove(path) }
            treeError = RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)
        case .fileContents(let id, let path, let text, let truncated, _) where accepts(id):
            peekWaiters.removeValue(forKey: path)?.forEach { $0.resume(returning: text) }
            guard file?.path == path else { return }
            file = (path, .loaded(FileReply(text: text, truncated: truncated)))
        case .fileUnavailable(let id, let path, let reason, let byteSize, let message) where accepts(id):
            peekWaiters.removeValue(forKey: path)?.forEach { $0.resume(returning: nil) }
            guard file?.path == path else { return }
            file = (path, .failed(RemoteChangesRules.accessMessage(reason, message: message, byteSize: byteSize)))
        default:
            break
        }
    }
}

/// The phone-wide Compare Against choice.
@MainActor @Observable
final class ChangesComparison {
    static let shared = ChangesComparison()
    private static let key = "changesComparisonMode"

    var mode: ChangesComparisonMode? = UserDefaults.standard.string(forKey: key).flatMap(ChangesComparisonMode.init(rawValue:))
        // Manual compares against the Mac's per-worktree pick, which the host doesn't forward; it isn't offered.
        .flatMap { $0 == .manual ? nil : $0 } {
        didSet { UserDefaults.standard.set(mode?.rawValue, forKey: Self.key) }
    }
}

/// The member each workspace checkout's sessions read, by checkout id: one pick for every session of
/// a checkout, observed so an open session follows a pick made in another. Remembered across launches.
@MainActor @Observable
final class CheckoutFocus {
    static let shared = CheckoutFocus()

    /// Picks made since launch; earlier ones are read from the defaults.
    private var picked: [String: String] = [:]

    func member(of checkoutID: String) -> String? {
        picked[checkoutID] ?? UserDefaults.standard.string(forKey: Self.key(checkoutID))
    }

    func setMember(_ memberID: String, of checkoutID: String) {
        picked[checkoutID] = memberID
        UserDefaults.standard.set(memberID, forKey: Self.key(checkoutID))
    }

    private static func key(_ checkoutID: String) -> String { "checkoutFocus.\(checkoutID)" }
}
