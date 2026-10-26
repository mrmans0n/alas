import Foundation
import Observation

/// Paired Macs' worktrees, followed over the host channel of each online
/// peer that serves it (`host.v1` and `host.events.v1`). Peers without it
/// keep the session-derived grouping.
@MainActor
@Observable
final class NativePeerHosts {
    /// Visible worktrees by peer `serverId`. A key exists only for a peer
    /// whose channel holds a snapshot.
    private(set) var worktrees: [String: [PeerHostWorktree]] = [:]
    /// Archived worktrees, keyed like `worktrees`.
    private(set) var archivedWorktrees: [String: [PeerHostWorktree]] = [:]
    /// Each peer's latest run per (worktree, script), keyed like `worktrees`.
    private(set) var runs: [String: [RunRecord]] = [:]
    /// Each peer's shepherd pills by session id, keyed like `worktrees`.
    private(set) var shepherds: [String: [String: HostSessionShepherd]] = [:]
    /// Each peer's followed worktrees' review statuses by worktree id, keyed like `worktrees`.
    private(set) var reviewStatuses: [String: [String: ReviewLoopSnapshot]] = [:]
    /// Each peer's count of `reviewsChanged` by worktree id, keyed like
    /// `worktrees`, for a review view to read again on.
    private(set) var reviewRevisions: [String: [String: Int]] = [:]
    /// Each peer's count of subscriptions, by `serverId`: bumped when its
    /// channel subscribes again, so a view reads again after a reconnect
    /// whose missed events no revision records.
    private(set) var subscriptions: [String: Int] = [:]
    @ObservationIgnored private var subscribed: Set<String> = []
    /// Changes each time the git target's follow is sent: for a new target,
    /// and on a channel subscribed again, whose events do not repeat an
    /// unchanged status. Nil until sent.
    private(set) var gitFollowKey: String?
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// Fired with the peer's `serverId` when its runs changed, so a run's
    /// console can be listed without waiting for the next poll.
    @ObservationIgnored var onRunsChanged: (@MainActor (_ serverId: String) -> Void)?

    private let send: @MainActor (_ serverId: String, HostClientMessage) -> Void
    private let supports: @MainActor (_ serverId: String, _ capability: String) -> Bool
    let confirm: @MainActor (PeerWorktreeRemoval.Confirmation, _ peerName: String) async -> Bool
    let showError: @MainActor (_ title: String, _ message: String) -> Void
    /// Shows a notice a peer's agent sent, with the peer's server id.
    private let notice: @MainActor (_ serverId: String, HostNotice) -> Void
    /// Shows a notice about one of a peer's worktrees, with the peer's server id.
    private let worktreeNotice: @MainActor (_ serverId: String, HostWorktreeNotice) -> Void
    private let timeout: Duration
    @ObservationIgnored private var channels: [String: PeerHostChannel] = [:]
    /// The worktree whose review status is followed, and whether its channel's
    /// current subscription was sent the follow.
    @ObservationIgnored private var gitFollow: GitFollow?
    @ObservationIgnored private var gitFollowSent = false
    @ObservationIgnored private var gitFollowSends = 0

    init(
        send: @escaping @MainActor (_ serverId: String, HostClientMessage) -> Void,
        supports: @escaping @MainActor (_ serverId: String, _ capability: String) -> Bool,
        confirm: @escaping @MainActor (PeerWorktreeRemoval.Confirmation, _ peerName: String) async -> Bool = { _, _ in false },
        showError: @escaping @MainActor (_ title: String, _ message: String) -> Void = { _, _ in },
        notice: @escaping @MainActor (_ serverId: String, HostNotice) -> Void = { _, _ in },
        worktreeNotice: @escaping @MainActor (_ serverId: String, HostWorktreeNotice) -> Void = { _, _ in },
        timeout: Duration = PeerHostChannel.defaultTimeout
    ) {
        self.send = send
        self.supports = supports
        self.confirm = confirm
        self.showError = showError
        self.notice = notice
        self.worktreeNotice = worktreeNotice
        self.timeout = timeout
    }

    /// Reconciles with the peers whose links currently carry sessions. A
    /// channel that is not subscribed, because its snapshot or resync
    /// failed, connects again here.
    func peersChanged(online: Set<String>) {
        for (serverId, channel) in channels where !online.contains(serverId) || !servesHostChannel(serverId) {
            channels[serverId] = nil
            channel.disconnect() // its onChange drops `worktrees[serverId]`
        }
        for serverId in online where servesHostChannel(serverId) {
            let channel = channels[serverId] ?? makeChannel(serverId)
            guard !channel.isSubscribed, !channel.isConnecting else { continue }
            // ponytail: unthrottled retry, once per refresh (each session-list or
            // availability change); add a failure counter with backoff if a peer
            // that keeps refusing the snapshot or subscribe shows up.
            Task { await channel.connect() }
        }
    }

    func receive(serverId: String, _ message: HostServerMessage) {
        channels[serverId]?.receive(message)
    }

    func stop() {
        let stopped = channels.values
        channels = [:]
        worktrees = [:]
        archivedWorktrees = [:]
        runs = [:]
        shepherds = [:]
        reviewStatuses = [:]
        reviewRevisions = [:]
        subscribed = []
        gitFollowSent = false
        for channel in stopped {
            channel.onChange = nil
            channel.disconnect()
        }
    }

    /// Whether `serverId`'s worktrees can be read over its host channel.
    func canRead(serverId: String) -> Bool {
        channels[serverId]?.isSubscribed == true && supports(serverId, HostProtocolCapability.worktreesReadV1)
    }

    /// The reply a session in `worktree` would get for `read`. Nil when the
    /// host cannot be read, refused, or did not answer in time.
    func read(_ read: HostWorktreeRead, in worktree: PeerHostWorktree, serverId: String) async -> RemoteServerMessage? {
        guard canRead(serverId: serverId), let channel = channels[serverId] else { return nil }
        guard case .worktreeRead(let reply) = await channel.request(.readWorktree(worktree: Self.ref(worktree), read: read)) else {
            return nil
        }
        return reply
    }

    /// Whether `serverId` serves its worktrees' Run tab.
    func servesRuns(serverId: String) -> Bool {
        runs[serverId] != nil && supports(serverId, HostProtocolCapability.runsScriptsV1)
    }

    /// The scripts `worktree`'s Run tab lists on the host. Nil when the host
    /// does not serve runs, refused, or did not answer.
    func runScripts(in worktree: PeerHostWorktree, serverId: String) async -> [HostRunScript]? {
        guard servesRuns(serverId: serverId), let channel = channels[serverId] else { return nil }
        guard case .runScripts(let scripts) = await channel.request(.listRunScripts(worktree: Self.ref(worktree))) else { return nil }
        return scripts
    }

    func perform(
        _ command: PeerRuns.Command, on row: PeerRuns.Row, in worktree: PeerHostWorktree, serverId: String
    ) async -> PeerRuns.Reply {
        guard servesRuns(serverId: serverId), let channel = channels[serverId] else {
            return .refused(title: "Run Script Failed", message: FederatedSessionsProvider.peerUnavailableMessage)
        }
        return await PeerRuns.perform(command, on: row, in: Self.ref(worktree)) { await channel.request($0) }
    }

    private static func ref(_ worktree: PeerHostWorktree) -> WorktreeRef {
        WorktreeRef(projectID: worktree.snapshot.worktree.projectId, path: worktree.snapshot.worktree.path.path)
    }

    /// Archive and Delete for `worktree`, only on a host that serves them.
    func controls(for worktree: PeerHostWorktree, serverId: String) -> PeerWorktreeControls {
        worktree.controls(lifecycleSupported: supports(serverId, HostProtocolCapability.worktreesLifecycleV1))
    }

    func archive(_ worktree: PeerHostWorktree, serverId: String, peerName: String) {
        remove(worktree, .archive, failureTitle: "Archive Failed", serverId: serverId, peerName: peerName)
    }

    func delete(_ worktree: PeerHostWorktree, keepBranch: Bool, deleteBranchIfMerged: Bool, serverId: String, peerName: String) {
        remove(
            worktree, .delete(keepBranch: keepBranch, deleteBranchIfMerged: deleteBranchIfMerged),
            failureTitle: "Delete Failed", serverId: serverId, peerName: peerName
        )
    }

    /// Whether `serverId` unarchives its archived worktrees.
    func canUnarchive(serverId: String) -> Bool {
        channels[serverId] != nil && supports(serverId, HostProtocolCapability.worktreesLifecycleV1)
    }

    /// The host's events then move the row back; only a refusal is shown here.
    func unarchive(_ worktree: PeerHostWorktree, serverId: String) {
        guard canUnarchive(serverId: serverId), let channel = channels[serverId] else { return }
        let showError = showError
        Task {
            if case .failure(let error) = await channel.request(.unarchiveWorktree(worktree: Self.ref(worktree))) {
                showError("Unarchive Failed", PeerWorktreeRemoval.message(for: error))
            }
        }
    }

    /// Whether `serverId` archives its sessions.
    func canArchiveSessions(serverId: String) -> Bool {
        channels[serverId] != nil && supports(serverId, HostProtocolCapability.sessionsV1)
    }

    /// Archives host session `sessionID`. The host's next session list then
    /// drops its tab; only a refusal is shown here.
    func archiveSession(_ sessionID: String, serverId: String) {
        guard canArchiveSessions(serverId: serverId), let channel = channels[serverId] else { return }
        let showError = showError
        Task {
            switch await channel.request(.archiveSession(sessionID: sessionID)) {
            case .done:
                break
            case .failure(.session(.notWriter)):
                showError("Archive Failed", "Another device is driving this session.")
            case .failure(.session(.notFound)):
                showError("Archive Failed", "The host no longer lists this session.")
            case .failure(let error):
                showError("Archive Failed", PeerWorktreeRemoval.message(for: error))
            default:
                showError("Archive Failed", "The host sent an unexpected reply.")
            }
        }
    }

    /// Whether `worktree`'s branch can be renamed, on a host that serves it.
    func canRenameBranch(_ worktree: PeerHostWorktree, serverId: String) -> Bool {
        channels[serverId] != nil && supports(serverId, HostProtocolCapability.worktreesRenameBranchV1)
            && worktree.canRenameBranch
    }

    /// The error message for the rename sheet; nil once renamed. The host's
    /// events then relabel the row.
    func renameBranch(_ worktree: PeerHostWorktree, to branch: String, serverId: String) async -> String? {
        guard canRenameBranch(worktree, serverId: serverId), let channel = channels[serverId] else {
            return FederatedSessionsProvider.peerUnavailableMessage
        }
        switch await channel.request(.renameBranch(worktree: Self.ref(worktree), from: worktree.snapshot.worktree.branch, to: branch)) {
        case .done: return nil
        case .failure(let error): return PeerWorktreeRemoval.message(for: error)
        default: return "The host sent an unexpected reply."
        }
    }

    /// Whether `serverId` stages, commits, pushes and pulls its worktrees.
    func servesGit(serverId: String) -> Bool {
        worktrees[serverId] != nil && channels[serverId]?.isSubscribed == true
            && supports(serverId, HostProtocolCapability.worktreesGitV1)
    }

    /// The error message for `change`; nil once done.
    func mutate(_ change: HostWorktreeChange, in worktree: PeerHostWorktree, serverId: String) async -> String? {
        let served = servesGit(serverId: serverId) && change.capability.map { supports(serverId, $0) } != false
        // A pull is a fetch then a rebase, each bounded at 30 s on the host.
        let request = HostRequest.mutateWorktree(
            worktree: Self.ref(worktree), branch: worktree.snapshot.worktree.branch, change: change
        )
        let result = await answer(
            request, served: served, serverId: serverId, timeout: .seconds(120),
            unavailable: NativePeerReviewGitClientError(message: FederatedSessionsProvider.peerUnavailableMessage),
            notFound: Self.checkpointGone
        ) { if case .done = $0 { () } else { nil } }
        switch result {
        case .success: return nil
        case .failure(let error): return error.message
        }
    }

    /// What the host suggests `worktree`'s commit message from; nil when it cannot say.
    func commitMessageInput(in worktree: PeerHostWorktree, serverId: String) async -> CommitMessageSuggestionInput? {
        guard servesGit(serverId: serverId), let channel = channels[serverId],
              case .commitMessageInput(let input) = await channel.request(.commitMessageInput(worktree: Self.ref(worktree)))
        else { return nil }
        return input
    }

    /// `worktree`'s review status, read again on the host. Nil for none, and
    /// for a refusal or no answer.
    func reviewStatus(in worktree: PeerHostWorktree, serverId: String) async -> ReviewLoopSnapshot? {
        guard servesGit(serverId: serverId), let channel = channels[serverId],
              case .reviewStatus(let snapshot) = await channel.request(.reviewStatus(worktree: Self.ref(worktree)))
        else { return nil }
        return snapshot
    }

    /// Whether `serverId` lists, shows and changes its worktrees' stashes.
    func servesStash(serverId: String) -> Bool {
        servesGit(serverId: serverId) && supports(serverId, HostProtocolCapability.worktreesStashV1)
    }

    /// Whether `serverId` continues, skips and aborts its worktrees' git
    /// operations, resolves their conflicts, and cherry-picks and reverts.
    func servesOperations(serverId: String) -> Bool {
        servesGit(serverId: serverId) && supports(serverId, HostProtocolCapability.worktreesOperationsV1)
    }

    /// The repository's stashes as `worktree` lists them. Nil for a refusal or no answer.
    func stashes(in worktree: PeerHostWorktree, serverId: String) async -> [GitStash]? {
        guard servesStash(serverId: serverId), let channel = channels[serverId],
              case .stashes(let stashes) = await channel.request(.listStashes(worktree: Self.ref(worktree)))
        else { return nil }
        return stashes
    }

    func stashFiles(
        _ stash: GitStash, in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<[GitStashFile], NativePeerReviewGitClientError> {
        await answer(
            .stashFiles(worktree: Self.ref(worktree), stash: HostStashRef(stash)),
            served: servesStash(serverId: serverId), serverId: serverId, showsInvalidRequest: true
        ) { if case .stashFiles(let files) = $0 { files } else { nil } }
    }

    func stashDiff(
        _ stash: HostStashRef, path: String, in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<HostDiff, NativePeerReviewGitClientError> {
        await answer(
            .stashDiff(worktree: Self.ref(worktree), stash: stash, path: path),
            served: servesStash(serverId: serverId), serverId: serverId, showsInvalidRequest: true
        ) { if case .diff(let diff) = $0 { diff } else { nil } }
    }

    /// Whether `serverId` shows its worktrees' commits and edits them as the commit editor does.
    func servesCommitEdit(serverId: String) -> Bool {
        servesGit(serverId: serverId) && supports(serverId, HostProtocolCapability.worktreesCommitEditV1)
    }

    /// Commit `sha` as its editor shows it, its files capped.
    func commitDetails(
        _ sha: String, in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<CommitDetails, NativePeerReviewGitClientError> {
        await answer(
            .commitDetails(worktree: Self.ref(worktree), sha: sha),
            served: servesCommitEdit(serverId: serverId), serverId: serverId,
            unavailable: NativePeerReviewGitClientError(message: FederatedSessionsProvider.peerUnavailableMessage),
            showsInvalidRequest: true, notFound: Self.commitGone
        ) { if case .commitDetails(let details) = $0 { details } else { nil } }
    }

    /// The commit editor's copy for a commit the host no longer has.
    private static let commitGone = (what: "commit ", message: "This commit is no longer on the host. Refresh and try again.")

    /// Rewrites commit `sha` above the fold of `comparisonMode`, as the commit editor does.
    func editCommit(
        _ sha: String, _ edit: HostCommitEdit, comparisonMode: AppConfig.Changes.ChangesComparisonMode,
        in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<CommitEditResult, NativePeerReviewGitClientError> {
        let request = HostRequest.mutateWorktree(
            worktree: Self.ref(worktree), branch: worktree.snapshot.worktree.branch,
            change: .editCommit(sha: sha, edit: edit, comparisonMode: comparisonMode)
        )
        // The commits above it are replayed, each a git call on the host.
        return await answer(
            request, served: servesCommitEdit(serverId: serverId), serverId: serverId, timeout: .seconds(120),
            unavailable: NativePeerReviewGitClientError(message: FederatedSessionsProvider.peerUnavailableMessage),
            notFound: Self.commitGone
        ) { if case .commitEdited(let result) = $0 { result } else { nil } }
    }

    /// Whether `serverId` lists, inspects, takes, deletes and restores its worktrees' checkpoints.
    func servesCheckpoints(serverId: String) -> Bool {
        servesGit(serverId: serverId) && supports(serverId, HostProtocolCapability.worktreesCheckpointsV1)
    }

    /// The copy for a checkpoint the host no longer lists.
    private static let checkpointGone = (what: "checkpoint ", message: "This checkpoint is no longer on the host. Refresh and try again.")

    /// `worktree`'s checkpoints, newest first. Nil for a refusal or no answer.
    func checkpoints(in worktree: PeerHostWorktree, serverId: String) async -> CheckpointCatalogSnapshot? {
        guard servesCheckpoints(serverId: serverId), let channel = channels[serverId],
              case .checkpoints(let catalog) = await channel.request(.listCheckpoints(worktree: Self.ref(worktree)))
        else { return nil }
        return catalog
    }

    func checkpointManifest(
        _ id: CheckpointID, in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<WorktreeCheckpointManifest, NativePeerReviewGitClientError> {
        await answer(
            .checkpointManifest(worktree: Self.ref(worktree), id: id),
            served: servesCheckpoints(serverId: serverId), serverId: serverId,
            unavailable: NativePeerReviewGitClientError(message: FederatedSessionsProvider.peerUnavailableMessage),
            notFound: Self.checkpointGone
        ) { if case .checkpointManifest(let manifest) = $0 { manifest } else { nil } }
    }

    func checkpointDiff(
        _ id: CheckpointID, path: String, in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<HostDiff, NativePeerReviewGitClientError> {
        await answer(
            .checkpointDiff(worktree: Self.ref(worktree), id: id, path: path),
            served: servesCheckpoints(serverId: serverId), serverId: serverId,
            unavailable: NativePeerReviewGitClientError(message: FederatedSessionsProvider.peerUnavailableMessage),
            showsInvalidRequest: true, notFound: Self.checkpointGone
        ) { if case .diff(let diff) = $0 { diff } else { nil } }
    }

    /// What restoring `groupIDs` of checkpoint `id` would change; nil `groupIDs` selects every group.
    func checkpointRestorePreview(
        _ id: CheckpointID, groupIDs: Set<UUID>?, in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<CheckpointRestorePreview, NativePeerReviewGitClientError> {
        await answer(
            .checkpointRestorePreview(worktree: Self.ref(worktree), id: id, groupIDs: groupIDs),
            served: servesCheckpoints(serverId: serverId), serverId: serverId,
            unavailable: NativePeerReviewGitClientError(message: FederatedSessionsProvider.peerUnavailableMessage),
            notFound: Self.checkpointGone
        ) { if case .checkpointRestorePreview(let preview) = $0 { preview } else { nil } }
    }

    /// Takes a manual checkpoint named `label`. Deleting and restoring one go through `mutate`.
    func createCheckpoint(
        label: String, in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<WorktreeCheckpointManifest, NativePeerReviewGitClientError> {
        let request = HostRequest.mutateWorktree(
            worktree: Self.ref(worktree), branch: worktree.snapshot.worktree.branch, change: .createCheckpoint(label: label)
        )
        // Capturing reads every changed file on the host.
        return await answer(
            request, served: servesCheckpoints(serverId: serverId), serverId: serverId, timeout: .seconds(120),
            unavailable: NativePeerReviewGitClientError(message: FederatedSessionsProvider.peerUnavailableMessage),
            showsInvalidRequest: true
        ) { if case .checkpointManifest(let manifest) = $0 { manifest } else { nil } }
    }

    /// Whether `serverId` lists, reads and changes its worktrees' draft reviews.
    func servesReviews(serverId: String) -> Bool {
        channels[serverId]?.isSubscribed == true && supports(serverId, HostProtocolCapability.reviewsV1)
    }

    /// `worktree`'s draft reviews, newest first. Nil for a refusal or no answer.
    func reviews(in worktree: PeerHostWorktree, serverId: String) async -> [HostReviewSummary]? {
        guard servesReviews(serverId: serverId), let channel = channels[serverId],
              case .reviews(let reviews) = await channel.request(.listReviews(worktree: Self.ref(worktree)))
        else { return nil }
        return reviews
    }

    /// Review `sessionID` of `worktree` with every comment. Nil for a refusal or no answer.
    func review(_ sessionID: String, in worktree: PeerHostWorktree, serverId: String) async -> HostReview? {
        guard servesReviews(serverId: serverId), let channel = channels[serverId],
              case .review(let review) = await channel.request(.readReview(worktree: Self.ref(worktree), sessionID: sessionID))
        else { return nil }
        return review
    }

    /// The error message for `mutation`; nil once done. The host's
    /// `reviewsChanged` then bumps `reviewRevisions`.
    func mutateReview(
        _ mutation: HostReviewMutation, sessionID: String, in worktree: PeerHostWorktree, serverId: String
    ) async -> String? {
        guard servesReviews(serverId: serverId), let channel = channels[serverId] else {
            return FederatedSessionsProvider.peerUnavailableMessage
        }
        switch await channel.request(.mutateReview(worktree: Self.ref(worktree), sessionID: sessionID, mutation: mutation)) {
        case .done: return nil
        case .failure(let error): return PeerWorktreeRemoval.message(for: error)
        default: return "The host sent an unexpected reply."
        }
    }

    /// Whether `serverId` reads, opens and publishes its worktrees' pull and merge request reviews.
    func servesProviderReviews(serverId: String) -> Bool {
        servesReviews(serverId: serverId) && supports(serverId, HostProtocolCapability.reviewsProviderV1)
    }

    /// Pull or merge request review `sessionID` as the host's provider shows
    /// it, with its raw diff when `withDiff`.
    func providerReview(
        _ sessionID: String, in worktree: PeerHostWorktree, serverId: String, withDiff: Bool
    ) async -> Result<HostProviderReview, NativePeerReviewGitClientError> {
        // A large provider diff can take a while to fetch on the host.
        await providerRequest(
            .readProviderReview(worktree: Self.ref(worktree), sessionID: sessionID, withDiff: withDiff),
            serverId: serverId, timeout: withDiff ? .seconds(120) : nil
        ) { if case .providerReview(let review) = $0 { review } else { nil } }
    }

    /// Opens, or reuses, the host's review of `worktree`'s pull or merge request `number`.
    func openProviderReview(
        number: Int, in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<HostReview, NativePeerReviewGitClientError> {
        await providerRequest(.openProviderReview(worktree: Self.ref(worktree), number: number), serverId: serverId) {
            if case .review(let review) = $0 { review } else { nil }
        }
    }

    /// Replies to, resolves or unresolves a provider thread, as the host's user.
    func mutateReviewThread(
        _ threadID: String, kind: ProviderThreadMutationKind, body: String?, sessionID: String,
        in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<ProviderThreadMutationResult, NativePeerReviewGitClientError> {
        let request = HostRequest.mutateReviewThread(
            worktree: Self.ref(worktree), sessionID: sessionID, threadID: threadID, kind: kind, body: body
        )
        return await providerRequest(request, serverId: serverId) {
            if case .reviewThreadMutated(let result) = $0 { result } else { nil }
        }
    }

    /// Publishes the review on its provider, as the host's user.
    func publishReview(
        _ publish: HostReviewPublish, sessionID: String, in worktree: PeerHostWorktree, serverId: String
    ) async -> Result<ProviderReviewPublishResult, NativePeerReviewGitClientError> {
        // A GitLab publish posts one discussion per draft.
        await providerRequest(
            .publishReview(worktree: Self.ref(worktree), sessionID: sessionID, publish: publish),
            serverId: serverId, timeout: .seconds(120)
        ) { if case .reviewPublished(let result) = $0 { result } else { nil } }
    }

    private func providerRequest<Value>(
        _ request: HostRequest, serverId: String, timeout: Duration? = nil, reply: (HostResponse) -> Value?
    ) async -> Result<Value, NativePeerReviewGitClientError> {
        await answer(request, served: servesProviderReviews(serverId: serverId), serverId: serverId, timeout: timeout, reply: reply)
    }

    /// `request`'s reply as `reply` reads it, or the host's refusal;
    /// `unavailable` unless `served`. `showsInvalidRequest` shows an invalid
    /// request's reason, for verbs whose reasons are all written for people.
    private func answer<Value>(
        _ request: HostRequest, served: Bool, serverId: String, timeout: Duration? = nil,
        unavailable: NativePeerReviewGitClientError = .unavailable, showsInvalidRequest: Bool = false,
        notFound: (what: String, message: String)? = nil, reply: (HostResponse) -> Value?
    ) async -> Result<Value, NativePeerReviewGitClientError> {
        guard served, let channel = channels[serverId] else { return .failure(unavailable) }
        let response = await channel.request(request, timeout: timeout)
        if case .failure(let error) = response {
            // Only the missing item: a missing worktree keeps its own message.
            if let notFound, case .notFound(let what) = error, what.hasPrefix(notFound.what) {
                return .failure(NativePeerReviewGitClientError(message: notFound.message))
            }
            if showsInvalidRequest, case .invalidRequest(let reason) = error {
                return .failure(NativePeerReviewGitClientError(message: reason))
            }
            return .failure(NativePeerReviewGitClientError(message: PeerWorktreeRemoval.message(for: error)))
        }
        if let value = reply(response) { return .success(value) }
        return .failure(NativePeerReviewGitClientError(message: "The host sent an unexpected reply."))
    }

    /// Follows `worktree`'s review status in place of the previous target's.
    func followGit(_ worktree: PeerHostWorktree?, serverId: String?) {
        let next = worktree.flatMap { worktree in
            serverId.map { GitFollow(serverId: $0, worktreeID: worktree.snapshot.worktree.id) }
        }
        guard next != gitFollow else { return }
        let old = gitFollow, oldSent = gitFollowSent
        gitFollow = next
        gitFollowSent = false
        gitFollowKey = nil
        if let old, let channel = channels[old.serverId] {
            if oldSent { Task { _ = await channel.request(.unfollowWorktree(worktreeID: old.worktreeID)) } }
            // Its status goes stale unfollowed; its onChange may send the new follow.
            channel.forgetReviewStatus(worktreeID: old.worktreeID)
        }
        sendGitFollow()
    }

    private struct GitFollow: Equatable {
        let serverId: String
        let worktreeID: String
    }

    /// Host-side follows end with the subscription, so each one is sent the follow.
    private func sendGitFollow() {
        guard let follow = gitFollow, !gitFollowSent, servesGit(serverId: follow.serverId),
              let channel = channels[follow.serverId]
        else { return }
        gitFollowSent = true
        gitFollowSends += 1
        gitFollowKey = "\(follow.serverId)/\(follow.worktreeID)#\(gitFollowSends)"
        Task { _ = await channel.request(.followWorktree(worktreeID: follow.worktreeID)) }
    }

    /// The host's events then update or drop the row; only a refusal is shown here.
    private func remove(
        _ worktree: PeerHostWorktree, _ action: PeerWorktreeRemoval.Action, failureTitle: String,
        serverId: String, peerName: String
    ) {
        guard controls(for: worktree, serverId: serverId) == .available, let channel = channels[serverId] else { return }
        let confirm = confirm, showError = showError
        Task {
            let outcome = await PeerWorktreeRemoval.run(
                action, on: worktree.snapshot,
                request: { await channel.request($0, timeout: $1) },
                confirm: { await confirm($0, peerName) }
            )
            if case .refused(let message) = outcome { showError(failureTitle, message) }
        }
    }

    private func servesHostChannel(_ serverId: String) -> Bool {
        supports(serverId, HostProtocolCapability.v1) && supports(serverId, HostProtocolCapability.eventsV1)
    }

    private func makeChannel(_ serverId: String) -> PeerHostChannel {
        let channel = PeerHostChannel(timeout: timeout) { [weak self] in self?.send(serverId, $0) }
        channel.onChange = { [weak self, weak channel] in
            guard let self, let channel else { return }
            worktrees[serverId] = channel.state?.visibleWorktrees()
            archivedWorktrees[serverId] = channel.state?.archivedWorktrees()
            let newRuns = channel.state?.runs
            let runsChanged = runs[serverId] != newRuns
            runs[serverId] = newRuns
            shepherds[serverId] = channel.state?.shepherds
            reviewStatuses[serverId] = channel.state?.reviewStatuses
            reviewRevisions[serverId] = channel.state?.reviewRevisions
            if !channel.isSubscribed {
                subscribed.remove(serverId)
            } else if subscribed.insert(serverId).inserted {
                subscriptions[serverId, default: 0] += 1
            }
            if !channel.isSubscribed, gitFollow?.serverId == serverId { gitFollowSent = false }
            sendGitFollow()
            onChange?()
            if runsChanged { onRunsChanged?(serverId) }
        }
        channel.onNotice = { [notice] in notice(serverId, $0) }
        channel.onWorktreeNotice = { [worktreeNotice] in worktreeNotice(serverId, $0) }
        channels[serverId] = channel
        return channel
    }
}
