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
        if online, !hostWasOnline {
            replay()
            reconnects += 1
        }
    }

    /// Asks again for whatever is open; the host forgot everything it was asked while away.
    private func replay() {
        changesFlight.reset()
        if case .idle = changes {} else { refreshChanges() }
        if let commit { send(.listCommitFiles(sessionId: sessionId, sha: commit.commit.revision)) }
        for key in diffWaiters.keys { requestDiff(key) }
        for sha in commitFilesWaiters.keys where sha != commit?.commit.revision { send(.listCommitFiles(sessionId: sessionId, sha: sha)) }
        if treeRequested { loadTree() }
        refreshShepherd()
        refreshRunScripts()
        if let file {
            self.file = (file.path, .loading)
            // A skill's path is its command, which only `readSkill` reads.
            send(fileIsSkill ? .readSkill(sessionId: sessionId, command: file.path)
                : .readFile(sessionId: sessionId, path: file.path))
        }
    }

    // MARK: Changes

    func refreshChanges() {
        if case .loaded = changes {} else { changes = .loading }
        guard changesFlight.shouldSend() else { return }
        changesMode = comparisonMode
        send(.listChanges(sessionId: sessionId, comparisonMode: comparisonMode))
        refreshPullRequest()
    }

    /// Asks the host to read the worktree's pull request again; its answer replaces `pullRequest`.
    private func refreshPullRequest() {
        guard canUseGit, let target = gitTarget, hub.state(of: hostID) == .online else { return }
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
        await wait(\.commitFilesWaiters, sha) { send(.listCommitFiles(sessionId: sessionId, sha: sha)) }
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
            send(.commitFileDiff(sessionId: sessionId, sha: sha, path: key.path))
        } else {
            send(.fileDiff(sessionId: sessionId, path: key.path, stage: key.stage, comparisonMode: comparisonMode))
        }
    }

    func openCommit(_ commit: RemoteCommit, by owner: UUID) {
        pushedBy = owner
        self.commit = (commit, .loading)
        send(.listCommitFiles(sessionId: sessionId, sha: commit.revision))
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
        fileIsSkill = false
        send(.readFile(sessionId: sessionId, path: path))
    }

    /// Opens a skill command's `SKILL.md`, which the host reads by command.
    func openSkill(_ command: String, by owner: UUID) {
        pushedBy = owner
        file = (command, .loading)
        fileIsSkill = true
        send(.readSkill(sessionId: sessionId, command: command))
    }

    /// A file's text without opening it, for a card that shows part of it;
    /// nil when the host can't read it or doesn't answer within 10 s.
    func peekFile(_ path: String) async -> String? {
        guard hub.state(of: hostID) == .online else { return nil }
        if peekWaiters[path] == nil { send(.readFile(sessionId: sessionId, path: path)) }
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

    /// Whether working-tree hunks can be staged, unstaged or discarded one by one.
    var canChangeHunks: Bool {
        guard gitTarget != nil else { return false }
        return hub.supports(HostProtocolCapability.worktreesHunksPhoneV1, on: hostID)
            || hub.supports(HostProtocolCapability.worktreesHunksV1, on: hostID) && hub.supports(HostProtocolCapability.worktreesGitV1, on: hostID)
    }

    /// Applies `action` to `hunk`, the `index`th of `key`'s working-tree diff. Returns the host's refusal, or nil.
    func changeHunk(_ action: RemoteHunkAction, index: Int, _ hunk: RemoteDiffHunk, in key: DiffKey) async -> String? {
        guard key.sha == nil else { return "This diff can't be changed from here." }
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
    var canReadFileHistory: Bool {
        gitTarget != nil && hub.supports(HostProtocolCapability.worktreesFileHistoryV1, on: hostID)
    }

    /// The commits that touched `path`, newest first.
    func fileHistory(_ path: String) async -> Result<(entries: [HostFileHistoryEntry], truncated: Bool), RemoteGitFailure> {
        guard let target = gitTarget else { return .failure(RemoteGitFailure("This worktree's history isn't available here.")) }
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
        guard canUseGit, let target = gitTarget,
              case .success(let reply) = await hostReply(timeout: .seconds(30), {
                  RemoteGitRequest.commitMessageInput(id: $0, projectID: target.projectID, path: target.worktree.path)
              }) else { return nil }
        return RemoteGitRequest.commitMessageInput(in: reply)
    }

    // MARK: Reviews

    /// The Mac's draft reviews of this worktree, its comments readable and changeable from here.
    var canReview: Bool {
        gitTarget != nil && (hub.supports(HostProtocolCapability.reviewsPhoneV1, on: hostID)
            || hub.supports(HostProtocolCapability.reviewsV1, on: hostID))
    }

    func reviews() async -> Result<[RemoteReviewSummary], RemoteGitFailure> {
        guard let target = gitTarget else { return .failure(RemoteGitFailure("This worktree's reviews can't be read from here.")) }
        return await hostReply { RemoteReviewRequest.list(id: $0, projectID: target.projectID, path: target.worktree.path) }
            .flatMap { Self.readable(RemoteReviewRequest.reviews(in: $0)) }
    }

    func review(_ sessionID: String) async -> Result<RemoteReview, RemoteGitFailure> {
        guard let target = gitTarget else { return .failure(RemoteGitFailure("This worktree's reviews can't be read from here.")) }
        return await hostReply {
            RemoteReviewRequest.read(id: $0, projectID: target.projectID, path: target.worktree.path, sessionID: sessionID)
        }
        .flatMap { Self.readable(RemoteReviewRequest.review(in: $0)) }
    }

    /// Whether the host reads and answers a pull or merge request review's threads for the phone.
    var canReadPullRequestThreads: Bool {
        gitTarget != nil && (hub.supports(HostProtocolCapability.reviewsProviderPhoneV1, on: hostID)
            || hub.supports(HostProtocolCapability.reviewsProviderV1, on: hostID))
    }

    /// Review `sessionID`'s pull or merge request threads, fetched from its provider by the host.
    func pullRequestThreads(_ sessionID: String) async -> Result<RemoteProviderReview, RemoteGitFailure> {
        guard let target = gitTarget else { return .failure(RemoteGitFailure("This pull request can't be read from here.")) }
        return await hostReply {
            RemoteReviewRequest.readProvider(id: $0, projectID: target.projectID, path: target.worktree.path, sessionID: sessionID)
        }
        .mapError { RemoteGitFailure(RemoteReviewRequest.providerFailureMessage($0.message)) }
        .flatMap { Self.readable(RemoteReviewRequest.providerReview(in: $0)) }
    }

    /// Replies to, resolves or unresolves a thread on the provider, as the host's user.
    /// Returns the host's refusal, worded for the user, or nil once it's done.
    func changeThread(_ sessionID: String, threadID: String, _ action: RemoteProviderThreadAction, body: String? = nil) async -> String? {
        guard let target = gitTarget else { return "This pull request can't be changed from here." }
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
        guard let target = gitTarget else { return .failure(RemoteGitFailure("This review can't be submitted from here.")) }
        // Each draft may be its own provider call; a phone giving up early would invite a duplicate submission.
        return await hostReply(timeout: .seconds(300)) {
            RemoteReviewRequest.publish(id: $0, projectID: target.projectID, path: target.worktree.path,
                                        sessionID: sessionID, decision, body: body, headSHA: headSHA)
        }
        .map { RemoteReviewRequest.publishProblems(in: $0) }
        .mapError { RemoteGitFailure(RemoteReviewRequest.providerFailureMessage($0.message)) }
    }

    private static func readable<T>(_ value: T?) -> Result<T, RemoteGitFailure> {
        value.map(Result.success) ?? .failure(RemoteGitFailure("The machine's answer couldn't be read."))
    }

    /// Returns the host's refusal, worded for the user, or nil once the comment changed.
    func changeReview(_ sessionID: String, _ mutation: RemoteReviewMutation) async -> String? {
        guard let target = gitTarget else { return "This worktree's reviews can't be changed from here." }
        return await hostRequest {
            RemoteReviewRequest.mutate(id: $0, projectID: target.projectID, path: target.worktree.path, sessionID: sessionID, mutation)
        }
    }

    /// Comments on `entry` in review `sessionID`, filed under its stage as the Mac's Review workspace files it.
    /// Returns the host's refusal, or nil.
    func comment(in sessionID: String, entry: ReviewEntryID, anchor: RemoteReviewAnchor, body: String) async -> String? {
        await changeReview(sessionID, .add(fileID: RemoteReviewFileID(namespace: entry.namespace, path: entry.path),
                                           path: entry.path, anchor: anchor, body: body))
    }

    /// The worktree's local-changes review, where the Mac's Review workspace files working-tree comments.
    var localChangesReviewID: String? {
        guard let target = gitTarget,
              let worktreeID = hub.sessions(of: hostID).first(where: { $0.id == sessionId })?.worktreeId else { return nil }
        return RemoteReviewRequest.localChangesSessionID(worktreeID: worktreeID, worktreePath: target.worktree.path)
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

    /// Follows an accepted launch by its run ID, independently of the screen that asked for it.
    func run(_ action: RemoteRunAction, _ script: RemoteRunScript, openConsole: @escaping PhoneRunTracker.OpenConsole) async -> String? {
        guard let target = gitTarget else { return "This worktree can't run scripts from here." }
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
                         let truncated, let commitsTruncated, _, _) where id == sessionId:
            if changeListLanded() { return }
            let reply = ChangeListReply(
                comparisonRef: ref, metricsAvailable: metrics, files: files, staged: staged, unstaged: unstaged,
                commits: commits, truncated: truncated, commitsTruncated: commitsTruncated)
            changes = .loaded(reply)
            resume(\.changesWaiters, true, .success(reply))
        case .changeListFailed(let id, let reason, let message) where id == sessionId:
            if changeListLanded() { return }
            let text = RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)
            changes = .failed(text)
            resume(\.changesWaiters, true, .failure(RemoteGitFailure(text)))
        case .fileDiffResult(let id, let path, let stage, let hunks, let truncated, let note) where id == sessionId:
            resume(\.diffWaiters, DiffKey(path: path, stage: stage), .success(DiffReply(hunks: hunks, truncated: truncated, metadataNote: note)))
        case .fileDiffFailed(let id, let path, let stage, let reason, let message) where id == sessionId:
            resume(\.diffWaiters, DiffKey(path: path, stage: stage),
                   .failure(RemoteGitFailure(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil))))
        case .commitFiles(let id, let sha, let files, let truncated) where id == sessionId:
            let reply = CommitFilesReply(files: files, truncated: truncated)
            resume(\.commitFilesWaiters, sha, .success(reply))
            guard let open = commit?.commit, open.revision == sha else { return }
            commit = (open, .loaded(reply))
        case .commitFilesFailed(let id, let sha, let reason, let message) where id == sessionId:
            let text = RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)
            resume(\.commitFilesWaiters, sha, .failure(RemoteGitFailure(text)))
            guard let open = commit?.commit, open.revision == sha else { return }
            commit = (open, .failed(text))
        case .commitDiffResult(let id, let sha, let path, let hunks, let truncated, let note) where id == sessionId:
            resume(\.diffWaiters, DiffKey(path: path, stage: nil, sha: sha), .success(DiffReply(hunks: hunks, truncated: truncated, metadataNote: note)))
        case .commitDiffFailed(let id, let sha, let path, let reason, let message) where id == sessionId:
            resume(\.diffWaiters, DiffKey(path: path, stage: nil, sha: sha),
                   .failure(RemoteGitFailure(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil))))
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
            peekWaiters.removeValue(forKey: path)?.forEach { $0.resume(returning: text) }
            guard file?.path == path else { return }
            file = (path, .loaded(FileReply(text: text, truncated: truncated)))
        case .fileUnavailable(let id, let path, let reason, let byteSize, let message) where id == sessionId:
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
