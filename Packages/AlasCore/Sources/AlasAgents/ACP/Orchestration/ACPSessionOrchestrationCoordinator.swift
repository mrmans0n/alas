import Foundation
import OSLog
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP
import AlasSessions

@MainActor
public final class ACPSessionOrchestrationCoordinator {
    public struct WorktreeCreationError: Error, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// A worktree made for a paired Mac's child, and whether its repository's
    /// unapproved create hook was skipped.
    public struct PeerWorktree: Sendable {
        public let worktree: Worktree
        public let skippedRepoHook: Bool

        public init(worktree: Worktree, skippedRepoHook: Bool) {
            self.worktree = worktree
            self.skippedRepoHook = skippedRepoHook
        }
    }

    public struct SessionLocation {
        public let origin: ACPOrchestrationSessionOrigin
        public let manager: ACPSessionManager
        /// Lets go of the session a lookup retained to read it; call once
        /// done reading. Nil when the lookup retained nothing.
        public var release: (() -> Void)? = nil

        public init(origin: ACPOrchestrationSessionOrigin, manager: ACPSessionManager, release: (() -> Void)? = nil) {
            self.origin = origin
            self.manager = manager
            self.release = release
        }
    }

    /// A session to read, and what to call once done reading it.
    private struct ReadableSession {
        let session: ACPSession
        let release: () -> Void

        public init(session: ACPSession, release: @escaping () -> Void) {
            self.session = session
            self.release = release
        }
    }

    public enum PeerWorktreeResolution: Equatable, Sendable {
        case matched(Worktree)
        case missing
        case ambiguous([String])
    }

    public struct Environment {
        public let persistence: ACPOrchestrationPersistence
        public let instanceId: String
        public let now: () -> Int64
        /// Epoch **milliseconds**, unlike `now` (seconds). Used only where
        /// millisecond precision matters: recording when a delegated child
        /// reported to its parent, compared against `ACPTurnCompletion
        /// .startedAt` (also milliseconds) in `outcomeDisposition`. Defaults
        /// to a real millisecond clock so existing call sites that don't
        /// care about this comparison don't need to supply one.
        public let nowMillis: () -> Int64
        /// Every request the given session is currently blocked on. Supplied
        /// by `ACPSessionManager`, which is the only place that can see a
        /// parked permission's real id.
        public let blockedRequestKeys: (String) -> Set<String>
        /// Seconds before a still-blocked child escalates from notice to wake.
        /// 0 disables escalation.
        public let escalationDelaySeconds: () -> Int
        /// Arranges for `work` to run after `delay` seconds. Defaults to a
        /// no-op, so `childBlocked` schedules nothing in any fixture that
        /// doesn't override this — every test drives the re-check by calling
        /// `escalateBlockerIfStillBlocked` directly instead of waiting out a
        /// real delay. Only `AppState`'s construction (Task 7) sleeps for real.
        public let scheduleEscalationCheck: (Int, @escaping @Sendable () async -> Void) -> Void
        /// How long a peer stays continuously not online before the parents
        /// of its unsettled children get one notice, in seconds.
        public let peerOfflineNoticeDelay: TimeInterval
        /// A start went unanswered, or a result is now awaited. A live link may
        /// send no signal for either, so the peer needs asking until it settles.
        public let peerNeedsCollecting: (String) -> Void
        /// Fixed collection window for nearby child results; injectable for tests.
        public let waitForChildResultBatch: @Sendable () async -> Void
        public let makeID: () -> String
        public let worktree: (String) -> Worktree?
        public let existingWorktree: (String, String) -> Worktree?
        public let configuredAgents: () -> [ACPOrchestrationAgent]
        public let availableAgents: (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPOrchestrationAgent]
        /// Read-only discovery rows for the caller's worktree, computed on
        /// every request from current Settings and install state.
        public let delegationAgents: (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPDelegationAgentSummary]
        /// The models an agent advertised during this launch on the host the
        /// worktree runs on, nil when none reported there; the spawn-time
        /// model check reads it.
        public let launchModels: (String, Worktree) -> [ACPAgentModelCatalog.Model]?
        public let sessionLocation: (String) -> SessionLocation?
        /// A non-archived session of the given project, live or stored, made
        /// live when it was not. Reaches sessions outside a delegation, so it
        /// is only consulted for sessions the user attached.
        public let referencedSessionLocation: (_ sessionId: String, _ projectId: String) async -> SessionLocation?
        public let manager: (Worktree) -> ACPSessionManager?
        /// Why a child session of `agentID` cannot start in the worktree now,
        /// as any new session there is refused; nil when it can. Main-actor
        /// isolated, so nothing runs between its last check and the child's
        /// creation.
        public let admitChild: @MainActor (_ worktree: Worktree, _ agentID: String) async -> String?
        public let newWorktreeDestination: (String, String) -> URL?
        /// Creates the worktree for `(projectId, branch, base)`. The last
        /// argument records the prepared destination on the delegation and
        /// must be awaited before the checkout is created.
        public let createWorktree: (String, String, String?, @escaping @MainActor (URL) async throws -> Void) async -> Result<Worktree, WorktreeCreationError>
        public let rememberParent: (String, String) -> Void
        public let autoRunDefault: () -> Bool
        public let notifyChanged: () -> Void
        /// Outcomes wait in the outbox of the paired Mac with this server id.
        public let peerOutboxChanged: (String) -> Void
        /// Suspends `session_wait` between polls. Tests replace it to change
        /// state between polls instead of sleeping.
        public let pause: (Duration) async -> Void
        /// The project a paired Mac asked to run a child in.
        public let project: (String) -> ProjectConfig?
        /// Creates the worktree for `(projectId, branch, base)` as `createWorktree`
        /// does, for a child nobody here is waiting on: unapproved hooks are
        /// skipped without asking.
        public let createPeerWorktree: (String, String, String, @escaping @MainActor (URL) async throws -> Void) async -> Result<PeerWorktree, WorktreeCreationError>
        /// What a peer child's new worktree branches from, for `(branch, base,
        /// expectedSHA, repo)`, having made sure it is current.
        public let resolvePeerWorktreeBase: (String, String, String?, URL) async -> Result<String, WorktreeCreationError>
        /// What a paired Mac's user knows this Mac as.
        public let machineName: () -> String
        /// How to reach paired Macs' hosts; nil when this build has no peer links.
        public let delegationPeers: () -> ACPDelegationPeers?
        /// The normalized `origin` remote (`host/owner/repo`) of a worktree on
        /// this Mac, wherever it runs; nil when it has none.
        public let originRemote: (Worktree) async -> String?
        /// Whether a worktree's code is on its remote; nil when git cannot say.
        public let branchState: (Worktree) async -> ACPPeerBranchState?
        /// Which of a peer's worktrees a `--worktree` selector names.
        public let resolvePeerWorktree: (String, [Worktree]) -> PeerWorktreeResolution

        public init(
            persistence: ACPOrchestrationPersistence,
            instanceId: String,
            now: @escaping () -> Int64,
            nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
            blockedRequestKeys: @escaping (String) -> Set<String> = { _ in [] },
            escalationDelaySeconds: @escaping () -> Int = { 30 },
            scheduleEscalationCheck: @escaping (Int, @escaping @Sendable () async -> Void) -> Void = { _, _ in },
            peerOfflineNoticeDelay: TimeInterval = 900,
            peerNeedsCollecting: @escaping (String) -> Void = { _ in },
            waitForChildResultBatch: @escaping @Sendable () async -> Void = {
                try? await Task.sleep(for: .milliseconds(250))
            },
            makeID: @escaping () -> String,
            worktree: @escaping (String) -> Worktree?,
            existingWorktree: @escaping (String, String) -> Worktree?,
            configuredAgents: @escaping () -> [ACPOrchestrationAgent],
            availableAgents: @escaping (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPOrchestrationAgent],
            delegationAgents: @escaping (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPDelegationAgentSummary] = { _, _ in [] },
            launchModels: @escaping (String, Worktree) -> [ACPAgentModelCatalog.Model]? = { _, _ in nil },
            sessionLocation: @escaping (String) -> SessionLocation?,
            referencedSessionLocation: @escaping (String, String) async -> SessionLocation? = { _, _ in nil },
            manager: @escaping (Worktree) -> ACPSessionManager?,
            newWorktreeDestination: @escaping (String, String) -> URL?,
            createWorktree: @escaping (String, String, String?, @escaping @MainActor (URL) async throws -> Void) async -> Result<Worktree, WorktreeCreationError>,
            rememberParent: @escaping (String, String) -> Void,
            autoRunDefault: @escaping () -> Bool,
            notifyChanged: @escaping () -> Void,
            peerOutboxChanged: @escaping (String) -> Void = { _ in },
            pause: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
            admitChild: @escaping @MainActor (_ worktree: Worktree, _ agentID: String) async -> String? = { _, _ in nil },
            project: @escaping (String) -> ProjectConfig? = { _ in nil },
            createPeerWorktree: @escaping (String, String, String, @escaping @MainActor (URL) async throws -> Void) async -> Result<PeerWorktree, WorktreeCreationError> = { _, _, _, _ in
                .failure(.init(message: "This host cannot create worktrees for a paired Mac."))
            },
            resolvePeerWorktreeBase: @escaping (String, String, String?, URL) async -> Result<String, WorktreeCreationError> = { _, base, _, _ in .success(base) },
            machineName: @escaping () -> String = { "this Mac" },
            delegationPeers: @escaping () -> ACPDelegationPeers? = { nil },
            originRemote: @escaping (Worktree) async -> String? = { _ in nil },
            branchState: @escaping (Worktree) async -> ACPPeerBranchState? = { _ in nil },
            resolvePeerWorktree: @escaping (String, [Worktree]) -> PeerWorktreeResolution = { selector, worktrees in
                let matches = worktrees.filter { $0.branch == selector || $0.name == selector || $0.path.path == selector }
                return matches.count == 1 ? .matched(matches[0]) : matches.isEmpty ? .missing : .ambiguous(matches.map(\.branch))
            }
        ) {
            self.delegationPeers = delegationPeers
            self.originRemote = originRemote
            self.branchState = branchState
            self.resolvePeerWorktree = resolvePeerWorktree
            self.admitChild = admitChild
            self.project = project
            self.createPeerWorktree = createPeerWorktree
            self.resolvePeerWorktreeBase = resolvePeerWorktreeBase
            self.machineName = machineName
            self.persistence = persistence
            self.instanceId = instanceId
            self.now = now
            self.nowMillis = nowMillis
            self.blockedRequestKeys = blockedRequestKeys
            self.escalationDelaySeconds = escalationDelaySeconds
            self.scheduleEscalationCheck = scheduleEscalationCheck
            self.peerOfflineNoticeDelay = peerOfflineNoticeDelay
            self.peerNeedsCollecting = peerNeedsCollecting
            self.waitForChildResultBatch = waitForChildResultBatch
            self.makeID = makeID
            self.worktree = worktree
            self.existingWorktree = existingWorktree
            self.configuredAgents = configuredAgents
            self.availableAgents = availableAgents
            self.delegationAgents = delegationAgents
            self.launchModels = launchModels
            self.sessionLocation = sessionLocation
            self.referencedSessionLocation = referencedSessionLocation
            self.manager = manager
            self.newWorktreeDestination = newWorktreeDestination
            self.createWorktree = createWorktree
            self.rememberParent = rememberParent
            self.autoRunDefault = autoRunDefault
            self.notifyChanged = notifyChanged
            self.peerOutboxChanged = peerOutboxChanged
            self.pause = pause
        }
    }

    private let environment: Environment
    private var deliveringSessions: Set<String> = []
    private var deliveryRequested: Set<String> = []
    /// What a peer child's start asked for, until the peer took it. Held in
    /// memory only: the record has nowhere to keep the target.
    private var pendingPeerStarts: [String: ACPPeerChildStartRequest] = [:]
    private var peerStartsInFlight: Set<String> = []
    private var peerStatusRounds: [String: [[String]: PeerStatusRound]] = [:]
    private var peerOutboxSignals: [String: Int] = [:]
    private var lastSeenPeerOnline: [String: Int64] = [:]
    private var peerOutages: [String: PeerOutage] = [:]
    private var peerOutageCount = 0
    /// Names of peers this Mac no longer has a record of, for what it says
    /// about their children afterwards.
    private var revokedPeerNames: [String: String] = [:]

    public init(environment: Environment) {
        self.environment = environment
    }

    public func list(origin: ACPOrchestrationSessionOrigin) async -> AlasCLIResponse {
        do {
            let parent = try await environment.persistence.parent(childSessionId: origin.sessionId)
            let children = try await environment.persistence.children(parentSessionId: origin.sessionId)
            let visible = ACPSessionOrchestrationPolicy.visibleSessions(
                callerSessionId: origin.sessionId,
                parent: parent,
                children: children
            )
            var summaries: [ACPOrchestrationSessionSummary] = []
            for visible in visible {
                if visible.sessionId == origin.sessionId {
                    summaries.append(await sessionSummary(
                        sessionId: origin.sessionId,
                        relationship: nil,
                        agentId: environment.sessionLocation(origin.sessionId)?.manager.liveSession(for: origin.sessionId)?.agentId ?? parent?.agentId ?? "unknown",
                        worktreeId: origin.worktreeId,
                        phase: .ready,
                        failure: nil,
                        createdAt: 0
                    ))
                    continue
                }
                if visible.relationship == .parent {
                    let location = environment.sessionLocation(visible.sessionId)
                    summaries.append(await sessionSummary(
                        sessionId: visible.sessionId,
                        relationship: "parent",
                        agentId: location?.manager.liveSession(for: visible.sessionId)?.agentId ?? "unknown",
                        worktreeId: location?.origin.worktreeId ?? parent?.parentWorktreeId ?? "",
                        phase: .ready,
                        failure: nil,
                        createdAt: 0
                    ))
                    continue
                }
                guard let record = children.first(where: { $0.childSessionId == visible.sessionId }) else { continue }
                if let serverId = record.peerServerId {
                    // From the stored phase: a list does not wait on another Mac.
                    summaries.append(.init(
                        sessionId: record.childSessionId, relationship: "child", agentId: record.agentId, worktreeId: "",
                        state: record.phase == .ready
                            ? ACPOrchestrationPublicState.onPeer.rawValue
                            : ACPSessionOrchestrationPolicy.publicState(phase: record.phase, runtime: nil, archived: false).rawValue,
                        failure: record.failureMessage, createdAt: record.createdAt, role: record.role,
                        peer: peerName(serverId)
                    ))
                    continue
                }
                summaries.append(await sessionSummary(
                    sessionId: record.childSessionId,
                    relationship: "child",
                    agentId: record.agentId,
                    worktreeId: record.childWorktreeId ?? record.worktreeRequest.worktreeId ?? "",
                    phase: record.phase,
                    failure: record.failureMessage,
                    createdAt: record.createdAt,
                    role: record.role
                ))
            }
            return json(ACPOrchestrationListResponse(sessions: summaries))
        } catch {
            return .error("Could not load delegated sessions.")
        }
    }

    /// Read-only: never starts a session, a model request, or a focus change.
    /// `worktreeSelector` mirrors `session_new`'s existing-worktree target:
    /// install state can differ per worktree, so a caller planning to spawn
    /// elsewhere in the project asks about that worktree.
    public func discoverAgents(
        origin: ACPOrchestrationSessionOrigin, worktree worktreeSelector: String?, peer peerSelector: String? = nil
    ) async -> AlasCLIResponse {
        if peerSelector != nil, worktreeSelector != nil {
            return .error("Pass either worktree or peer, not both: a peer's worktrees are in its answer.")
        }
        let worktree: Worktree
        if let worktreeSelector {
            guard let resolved = environment.existingWorktree(origin.projectId, worktreeSelector) else {
                return .error("The requested worktree is not available in this project.")
            }
            worktree = resolved
        } else {
            guard let current = environment.worktree(origin.worktreeId) else {
                return .error("The current worktree is no longer available.")
            }
            worktree = current
        }
        let parent: ACPDelegationRecord?
        do {
            parent = try await environment.persistence.parent(childSessionId: origin.sessionId)
        } catch {
            return .error("Could not verify session delegation.")
        }
        let canDelegate: Bool
        switch ACPSessionOrchestrationPolicy.authorizeCreate(parent: parent) {
        case .success: canDelegate = true
        case .failure: canDelegate = false
        }
        let callerAgentId = environment.sessionLocation(origin.sessionId)?.manager
            .liveSession(for: origin.sessionId)?.agentId
        if let peerSelector {
            guard canDelegate else { return .error(Self.delegatedChildCannotCreate) }
            do {
                let found = try await discoverOnPeer(peerSelector, near: worktree)
                let matchedIDs = Set(found.discovery.projects.map(\.id))
                return json(ACPDelegationAgentListResponse(
                    version: ACPDelegationAgentListResponse.currentVersion,
                    callerAgentId: callerAgentId,
                    canDelegate: true,
                    worktreeId: worktree.id,
                    agents: found.discovery.agents.map { agent in
                        let usable = matchedIDs.isEmpty || !matchedIDs.isSubset(of: agent.unavailableProjectIDs)
                        return ACPDelegationAgentSummary(
                            id: agent.id, displayName: agent.name, available: usable,
                            availability: usable ? .available : .notInstalled,
                            modelSelection: .unknown,
                            modelCatalog: .init(state: usable ? .notLoaded : .unavailable, models: [])
                        )
                    },
                    peer: ACPOrchestrationPeerOffer(
                        serverId: found.peer.serverId, name: found.peer.name, access: found.discovery.access,
                        projects: found.discovery.projects.map { project in
                            .init(id: project.id, name: project.name, worktrees: Self.peerWorktrees(of: project, in: found.discovery).map {
                                .init(name: $0.name, branch: $0.branch, path: $0.path.path)
                            })
                        }
                    )
                ))
            } catch let failure as PeerRequestError {
                return .error(failure.message)
            } catch {
                return .error("Could not ask the peer.")
            }
        }
        return json(ACPDelegationAgentListResponse(
            version: ACPDelegationAgentListResponse.currentVersion,
            callerAgentId: callerAgentId,
            canDelegate: canDelegate,
            worktreeId: worktree.id,
            agents: await environment.delegationAgents(origin, worktree),
            peers: canDelegate ? environment.delegationPeers().map { peers in
                peers.peers.map {
                    ACPOrchestrationPeer(
                        serverId: $0.serverId, name: $0.name, state: $0.state.rawValue,
                        supportsDelegation: $0.supportsDelegation
                    )
                }
            } : nil
        ))
    }

    // MARK: Delegating to a paired Mac

    private static let delegatedChildCannotCreate = "Delegated sessions cannot create child sessions."

    private struct PeerRequestError: Error {
        let message: String
    }

    private static func message(for error: ACPPeerError) -> String {
        switch error {
        case .unreachable(let peer): "\(peer) cannot be reached right now. Check that it is online and paired."
        case .outdated(let peer): "\(peer) runs a version of Alas that cannot take delegated work. Update Alas on it."
        case .revoked(let peer): "This Mac's pairing with \(peer) was revoked."
        case .refused(let reason): reason
        case .notFound: "The peer has no such session."
        }
    }

    /// The paired Mac `selector` names: a server id first, then an exact name.
    private func resolvePeer(_ selector: String) throws -> (peers: ACPDelegationPeers, info: ACPDelegationPeerInfo) {
        guard let peers = environment.delegationPeers(), !peers.peers.isEmpty else {
            throw PeerRequestError(message: "No paired Macs. Pair another Mac in Settings to delegate to it.")
        }
        func described(_ infos: [ACPDelegationPeerInfo]) -> String {
            infos.map { "\($0.name) (\($0.serverId))" }.joined(separator: ", ")
        }
        let info: ACPDelegationPeerInfo
        if let byID = peers.peers.first(where: { $0.serverId == selector }) {
            info = byID
        } else {
            let named = peers.peers.filter { $0.name == selector }
            switch named.count {
            case 1: info = named[0]
            case 0:
                throw PeerRequestError(message: "No paired Mac is named \"\(selector)\". Paired Macs: \(described(peers.peers)).")
            default:
                throw PeerRequestError(
                    message: "Several paired Macs are named \"\(selector)\": \(described(named)). Pass the server id instead."
                )
            }
        }
        // State first: a peer that is down reports no capabilities, which says
        // nothing about its build.
        guard info.state == .online else {
            let reason = switch info.state {
            case .incompatible: Self.message(for: .outdated(peer: info.name))
            case .revoked: Self.message(for: .revoked(peer: info.name))
            default: Self.message(for: .unreachable(peer: info.name))
            }
            throw PeerRequestError(message: "\(info.name) is \(info.state.rawValue). \(reason)")
        }
        guard info.supportsDelegation else {
            throw PeerRequestError(message: Self.message(for: .outdated(peer: info.name)))
        }
        return (peers, info)
    }

    /// Asks the peer `selector` names about the projects whose origin is
    /// that of `worktree`, or all of them when `worktree` has none.
    private func discoverOnPeer(
        _ selector: String, near worktree: Worktree
    ) async throws -> (peer: ACPDelegationPeerInfo, discovery: ACPPeerDiscovery, repository: String?) {
        let (peers, info) = try resolvePeer(selector)
        let repository = await environment.originRemote(worktree)
        switch await peers.discover(serverId: info.serverId, repository: repository) {
        case .success(let discovery): return (info, discovery, repository)
        case .failure(let error): throw PeerRequestError(message: Self.message(for: error))
        }
    }

    private static func peerWorktrees(of project: ACPPeerDiscovery.Project, in discovery: ACPPeerDiscovery) -> [Worktree] {
        discovery.worktrees.filter { $0.projectID == project.id && !$0.isArchived }.map {
            Worktree(
                id: $0.path, projectId: $0.projectID, name: URL(fileURLWithPath: $0.path).lastPathComponent,
                branch: $0.branch, path: URL(fileURLWithPath: $0.path), status: .clean, lastActivity: .distantPast
            )
        }
    }

    /// The one project of the peer the child belongs to.
    private func chooseProject(
        _ project: String?, in found: (peer: ACPDelegationPeerInfo, discovery: ACPPeerDiscovery, repository: String?)
    ) throws -> ACPPeerDiscovery.Project {
        let projects = found.discovery.projects
        let name = found.peer.name
        func described(_ projects: [ACPPeerDiscovery.Project]) -> String {
            projects.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        }
        guard let project else {
            guard found.repository != nil else {
                throw PeerRequestError(
                    message: "This worktree has no origin remote, so pass --project. \(name)'s projects: \(described(projects))."
                )
            }
            switch projects.count {
            case 1: return projects[0]
            case 0: throw PeerRequestError(message: "None of \(name)'s projects has this repository as its origin. Pass --project to name one that does.")
            default:
                throw PeerRequestError(
                    message: "Several of \(name)'s projects match this repository: \(described(projects)). Pass --project."
                )
            }
        }
        var matches = projects.filter { $0.id == project }
        if matches.isEmpty { matches = projects.filter { $0.name == project } }
        switch matches.count {
        case 1: return matches[0]
        case 0:
            throw PeerRequestError(
                message: "\(name) has no matching project \"\(project)\". Its projects: \(projects.isEmpty ? "none" : described(projects))."
            )
        default:
            throw PeerRequestError(message: "Several of \(name)'s projects are named \"\(project)\": \(described(matches)). Pass the id.")
        }
    }

    /// Checks everything a delegation to a peer needs, records the child, then
    /// asks the peer to start it. `task` goes without its role framing, which
    /// the peer adds. Model and reasoning are the peer's to check.
    private func createOnPeer(
        _ selector: String, request: ACPDelegatedSessionNewRequest, task: String, role: String?,
        parent: ACPSession, origin: ACPOrchestrationSessionOrigin
    ) async -> AlasCLIResponse {
        if case .current = request.worktree {
            return .error("A peer cannot use this worktree. Pass --worktree or --new-worktree to say where the child runs there.")
        }
        guard let current = environment.worktree(origin.worktreeId) else {
            return .error("The current worktree is no longer available.")
        }
        guard let peers = environment.delegationPeers() else {
            return .error("No paired Macs. Pair another Mac in Settings to delegate to it.")
        }
        // Cheap and local, so before anything is asked of the peer or recorded.
        var newWorktreeBase: (name: String, expectedSHA: String?)?
        if case .new(_, let base) = request.worktree {
            switch ACPPeerBasePreflight.decide(explicitBase: base, state: base == nil ? await environment.branchState(current) : nil) {
            case .useBase(let name, let expectedSHA): newWorktreeBase = (name, expectedSHA)
            case .refuse(let message): return .error(message)
            }
        }
        let peerInfo: ACPDelegationPeerInfo
        let target: ACPPeerChildStartRequest.Target
        do {
            let found = try await discoverOnPeer(selector, near: current)
            let chosen = try chooseProject(request.project, in: found)
            peerInfo = found.peer
            switch request.worktree {
            case .current:
                return .error("A peer cannot use this worktree.")
            case .existing(let selector):
                let worktrees = Self.peerWorktrees(of: chosen, in: found.discovery)
                switch environment.resolvePeerWorktree(selector, worktrees) {
                case .matched(let worktree):
                    target = .worktree(projectID: chosen.id, path: worktree.path.path)
                case .missing:
                    throw PeerRequestError(
                        message: "\(found.peer.name) has no worktree \"\(selector)\" in \(chosen.name). Its worktrees: \(worktrees.map(\.branch).joined(separator: ", "))."
                    )
                case .ambiguous(let labels):
                    throw PeerRequestError(message: "\"\(selector)\" matches several of \(chosen.name)'s worktrees: \(labels.joined(separator: ", ")).")
                }
            case .new(let branch, _):
                if case .invalid(let message) = GitNameValidator.validateBranchName(branch) {
                    throw PeerRequestError(message: "invalid branch name: \(message)")
                }
                guard let newWorktreeBase else { throw PeerRequestError(message: "Could not ask the peer.") }
                target = .newWorktree(
                    projectID: chosen.id, branch: branch, base: newWorktreeBase.name, expectedBaseSHA: newWorktreeBase.expectedSHA
                )
            }
        } catch let failure as PeerRequestError {
            return .error(failure.message)
        } catch {
            return .error("Could not ask the peer.")
        }

        let childID = environment.makeID()
        let requestedAgent = request.agentId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = ACPPeerChildStartRequest(
            childID: childID, target: target,
            agentID: requestedAgent?.isEmpty == false ? requestedAgent! : parent.agentId,
            modelID: request.modelSelection?.model, reasoning: request.modelSelection?.reasoning,
            role: role, autoRun: parent.autoRunEnabled, prompt: task
        )
        let now = environment.now()
        // Marked before the row exists: an availability signal during the
        // insert or the request must not spend this child's retry.
        peerStartsInFlight.insert(childID)
        defer { peerStartsInFlight.remove(childID) }
        do {
            try await environment.persistence.insert(ACPDelegationRecord(
                childSessionId: childID, parentSessionId: origin.sessionId, projectId: origin.projectId,
                parentWorktreeId: origin.worktreeId, childWorktreeId: nil, agentId: start.agentID,
                worktreeRequest: .current(worktreeId: origin.worktreeId), phase: .starting, failureMessage: nil,
                createdAt: now, updatedAt: now, modelSelection: request.modelSelection, role: role,
                peerServerId: peerInfo.serverId, peerAwaiting: true
            ))
        } catch {
            return .error("Could not persist delegated session.")
        }
        environment.notifyChanged()
        notePeerAvailability(peerInfo.serverId)

        switch await peers.start(serverId: peerInfo.serverId, start) {
        case .success(let reply):
            await markPeerChildReady(childID, serverId: peerInfo.serverId, keepingForRetry: start)
            environment.peerNeedsCollecting(peerInfo.serverId)
            return json(ACPOrchestrationNewResponse(sessionId: childID, state: reply.state, worktreeId: nil, peer: peerInfo.name))
        case .failure(.unreachable(let name)):
            pendingPeerStarts[childID] = start
            // A live link that lost one answer sends no availability signal.
            if peers.peers.first(where: { $0.serverId == peerInfo.serverId })?.state == .online {
                let serverId = peerInfo.serverId
                environment.scheduleEscalationCheck(Self.peerStartRetryDelaySeconds) { [weak self] in
                    await self?.retryPeerStarts(serverId: serverId)
                }
                environment.peerNeedsCollecting(serverId)
            }
            return json(ACPOrchestrationNewResponse(
                sessionId: childID, state: ACPOrchestrationPublicState.starting.rawValue, worktreeId: nil, peer: peerInfo.name,
                note: "\(name) did not answer. Alas will retry once when it is back, and tell you if that fails."
            ))
        case .failure(let error):
            // The caller hears this in the answer, so nothing wakes it.
            let message = Self.message(for: error)
            try? await environment.persistence.updatePhase(
                childSessionId: childID, phase: .failed, failureMessage: message, updatedAt: environment.now()
            )
            environment.notifyChanged()
            return .error(message)
        }
    }

    private static let peerStartRetryDelaySeconds = 30
    /// How long a `.starting` row with no request in memory may belong to
    /// another instance on this store that is still starting it.
    private static let peerStartGraceSeconds: Int64 = 120

    /// Moves a child the peer confirmed to `.ready`, unless it already ended.
    /// If that cannot be stored it stays `.starting`, and `start` is kept for
    /// a retry, which the peer answers with the same child.
    private func markPeerChildReady(_ childID: String, serverId: String, keepingForRetry start: ACPPeerChildStartRequest?) async {
        // A status question already out may predate the child reaching the
        // peer. Its `gone` would fail the child a later wait shares it for.
        peerStatusRounds[serverId] = nil
        do {
            try await environment.persistence.markReadyIfStarting(childSessionId: childID, updatedAt: environment.now())
            pendingPeerStarts[childID] = nil
        } catch {
            pendingPeerStarts[childID] = start
        }
        environment.notifyChanged()
    }

    /// Gives each child still starting on the peer `serverId` its one further
    /// attempt. Only proof fails a child, with a wake since the parent has
    /// moved on: the peer answering no, or `status` finding nothing there. No
    /// answer proves nothing, so the row stays `.starting` and `status` decides
    /// next time. A peer that is not online gets no request and uses up
    /// nothing, since availability signals also fire as a peer goes away.
    public func retryPeerStarts(serverId: String) async {
        guard let peers = environment.delegationPeers(),
              peers.peers.first(where: { $0.serverId == serverId })?.state == .online,
              let children = try? await environment.persistence.peerChildren(peerServerId: serverId)
        else { return }
        for child in children where child.phase != .starting { pendingPeerStarts[child.childSessionId] = nil }
        for child in children where child.phase == .starting {
            let childID = child.childSessionId
            guard peerStartsInFlight.insert(childID).inserted else { continue }
            defer { peerStartsInFlight.remove(childID) }
            // The list is as old as the requests before this one took.
            guard let current = try? await environment.persistence.delegation(childSessionId: childID) else { continue }
            guard current.phase == .starting else {
                pendingPeerStarts[childID] = nil
                continue
            }
            if let start = pendingPeerStarts[childID] {
                switch await peers.start(serverId: serverId, start) {
                case .success:
                    await markPeerChildReady(childID, serverId: serverId, keepingForRetry: start)
                case .failure(.unreachable):
                    pendingPeerStarts[childID] = nil
                case .failure(let error):
                    pendingPeerStarts[childID] = nil
                    await markChildFailed(childSessionId: childID, message: Self.message(for: error))
                }
            } else {
                await settlePeerStart(current, serverId: serverId, peers: peers)
            }
        }
    }

    /// For a `.starting` row with no request to send: its retry was spent, this
    /// Mac restarted, or another instance on this store is starting it. If the
    /// peer knows the child it started. If not, the row is failed only once it
    /// is too old to be another instance's. No clear answer leaves it as it is.
    private func settlePeerStart(_ child: ACPDelegationRecord, serverId: String, peers: ACPDelegationPeers) async {
        let childID = child.childSessionId
        guard case .success(let data) = await peers.status(serverId: serverId, sessionIDs: [childID]),
              let reply = try? JSONDecoder().decode(ACPOrchestrationWaitResponse.self, from: data),
              let session = reply.sessions.first(where: { $0.sessionId == childID })
        else { return }
        guard session.state == ACPOrchestrationWaitResponse.Session.goneState else {
            await markPeerChildReady(childID, serverId: serverId, keepingForRetry: nil)
            return
        }
        guard environment.now() - child.updatedAt > Self.peerStartGraceSeconds else { return }
        await markChildFailed(
            childSessionId: childID,
            message: "\(peerName(serverId)) never started the delegated session."
        )
    }

    private func peerName(_ serverId: String) -> String {
        environment.delegationPeers()?.peers.first { $0.serverId == serverId }?.name
            ?? revokedPeerNames[serverId] ?? serverId
    }

    // MARK: Outages and lost pairings

    /// One stretch of a peer being not online. `lastSeenOnlineAt` names it in
    /// a notice's id; `id` tells it from another that shares that second.
    private struct PeerOutage {
        let id: Int
        let lastSeenOnlineAt: Int64
    }

    /// Whether `serverId` can be reached may have changed. An outage fails
    /// nothing, however long it lasts: the child keeps running over there.
    /// Asking about starts can hold a row for a minute, so it runs apart.
    public func peerAvailabilityChanged(serverId: String) {
        notePeerAvailability(serverId)
        guard environment.delegationPeers()?.peers.first(where: { $0.serverId == serverId })?.state == .online else { return }
        Task { @MainActor [weak self] in await self?.retryPeerStarts(serverId: serverId) }
    }

    /// Ends the outage of a peer that is back, or begins one and arranges its
    /// notice. A peer revoked or forgotten has its own path.
    private func notePeerAvailability(_ serverId: String) {
        let state = environment.delegationPeers()?.peers.first { $0.serverId == serverId }?.state
        switch state {
        case .online:
            lastSeenPeerOnline[serverId] = environment.now()
            peerOutages[serverId] = nil
        case nil, .revoked:
            peerOutages[serverId] = nil
        case .offline, .unverified, .incompatible:
            guard peerOutages[serverId] == nil else { return }
            peerOutageCount += 1
            let id = peerOutageCount
            peerOutages[serverId] = PeerOutage(
                id: id, lastSeenOnlineAt: lastSeenPeerOnline[serverId] ?? environment.now()
            )
            environment.scheduleEscalationCheck(Int(environment.peerOfflineNoticeDelay)) { [weak self] in
                await self?.noticePeerOffline(serverId: serverId, outage: id)
            }
        }
    }

    /// A child its parent is owed a word about, should the pairing end. A
    /// `.ready` child with no result owed is history.
    private static func isUnfinishedOnPeer(_ child: ACPDelegationRecord) -> Bool {
        child.phase != .failed && child.phase != .closed && (child.phase == .starting || child.peerAwaiting)
    }

    /// One notice per child still awaited, if this outage is still going on.
    /// Reads live state, so a peer that returned simply produces nothing.
    private func noticePeerOffline(serverId: String, outage id: Int) async {
        guard let outage = peerOutages[serverId], outage.id == id else { return }
        let state = environment.delegationPeers()?.peers.first { $0.serverId == serverId }?.state
        guard let state, state != .online, state != .revoked else {
            notePeerAvailability(serverId)
            return
        }
        let name = peerName(serverId)
        guard let children = try? await environment.persistence.peerChildren(peerServerId: serverId) else { return }
        for child in children where child.peerAwaiting && child.phase != .failed && child.phase != .closed {
            await enqueueOutcome(.init(
                id: "peer-offline-\(serverId)-\(child.childSessionId)-\(outage.lastSeenOnlineAt)",
                sourceSessionId: child.childSessionId,
                targetSessionId: child.parentSessionId,
                prompt: ACPDelegatedOutcomeText.peerOffline(
                    outcomeContext(for: child), peer: name, minutes: Int(environment.peerOfflineNoticeDelay / 60)
                ),
                createdAt: environment.now(),
                kind: .notice
            ), child: child)
        }
    }

    /// The pairing with `serverId` is over: its link was refused, or it was
    /// forgotten here. Its unfinished children fail with one wake each.
    /// `name` is passed because a forgotten peer is no longer listed.
    public func peerRevoked(serverId: String, name: String, forgotten: Bool) async {
        let name = ACPPeerName.sanitized(name) ?? serverId
        revokedPeerNames[serverId] = name
        peerOutages[serverId] = nil
        if forgotten {
            lastSeenPeerOnline[serverId] = nil
            await deleteOutbox(forPeer: serverId)
        }
        guard let children = try? await environment.persistence.peerChildren(peerServerId: serverId) else { return }
        let unfinished = children.filter(Self.isUnfinishedOnPeer)
        let message = forgotten ? Self.forgottenMessage(name) : Self.message(for: .revoked(peer: name))
        // Together, so one slow parent holds up no other, and one parent's
        // children join one wake.
        let failures = unfinished.map { child in
            pendingPeerStarts[child.childSessionId] = nil
            let childID = child.childSessionId
            return Task { @MainActor in await self.markChildFailed(childSessionId: childID, message: message) }
        }
        for failure in failures { await failure.value }
    }

    /// `peerRevoked` for a process only booted to forget a peer, which ends
    /// next and has no business attaching agents. The wake waits in the inbox,
    /// written with the phase, for the next launch's recovery to deliver.
    public func peerForgottenWithoutHost(serverId: String, name: String) async {
        let name = ACPPeerName.sanitized(name) ?? serverId
        revokedPeerNames[serverId] = name
        await deleteOutbox(forPeer: serverId)
        guard let children = try? await environment.persistence.peerChildren(peerServerId: serverId) else { return }
        let message = Self.forgottenMessage(name)
        for child in children where Self.isUnfinishedOnPeer(child) {
            _ = try? await environment.persistence.claimFailedPhase(
                childSessionId: child.childSessionId,
                failureMessage: message,
                updatedAt: environment.now(),
                outcome: failureOutcome(of: child, message: message),
                discardingHeldMessages: child.modelSelection != nil
            )
        }
    }

    private static func forgottenMessage(_ name: String) -> String {
        "\(name) was forgotten on this Mac"
    }

    /// What waits for a forgotten peer to collect, which it never will. The
    /// cursor stays: a peer paired again still holds the last page this Mac
    /// never acknowledged, and only the cursor stops it waking a parent twice.
    private func deleteOutbox(forPeer serverId: String) async {
        do {
            try await environment.persistence.deleteOutbox(peerServerId: serverId)
        } catch {
            Logger(subsystem: "io.nlopez.alas", category: "peer-outbox")
                .error("Could not delete the outbox of peer \(serverId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// `status` or `read` found nothing on the peer for a child that started
    /// there. Reads the row again: the request took a while.
    private func failGonePeerChild(_ childID: String) async {
        guard let current = await peerChild(childID), current.phase == .ready else { return }
        await markChildFailed(childSessionId: childID, message: peerFailureMessage(.notFound, child: current))
    }

    /// The child `sessionId` when it runs on a paired Mac.
    private func peerChild(_ sessionId: String) async -> ACPDelegationRecord? {
        guard let record = try? await environment.persistence.delegation(childSessionId: sessionId),
              record.peerServerId != nil
        else { return nil }
        return record
    }

    /// Why a request about a peer's child failed. A child still starting may
    /// not have reached the peer, so "no such session" says nothing about it.
    private func peerFailureMessage(_ error: ACPPeerError, child: ACPDelegationRecord) -> String {
        let name = peerName(child.peerServerId ?? "")
        guard case .notFound = error else { return Self.message(for: error) }
        return child.phase == .starting
            ? "\(name) has not started session \(child.childSessionId) yet. Try again once it has."
            : "\(name) has no session \(child.childSessionId)."
    }

    private func sendToPeer(
        _ child: ACPDelegationRecord, prompt: String, origin: ACPOrchestrationSessionOrigin
    ) async -> AlasCLIResponse {
        guard case .success = ACPSessionOrchestrationPolicy.authorizeChildControl(
            callerSessionId: origin.sessionId, callerProjectId: origin.projectId, target: child
        ) else {
            return .error("Messages may only be sent to a direct parent or child session.")
        }
        guard ACPSessionOrchestrationPolicy.acceptsMessages(target: child) else {
            return .error("The target delegated session is not available.")
        }
        let serverId = child.peerServerId ?? ""
        guard let peers = environment.delegationPeers() else {
            return .error(Self.message(for: .unreachable(peer: peerName(serverId))))
        }
        switch await peers.send(serverId: serverId, sessionID: child.childSessionId, prompt: prompt) {
        case .success(let acceptedAt):
            // A status question asked before this could report the child
            // settled, with this turn still to run.
            peerStatusRounds[serverId] = nil
            do {
                try await environment.persistence.markPeerAwaiting(childSessionId: child.childSessionId, since: acceptedAt)
            } catch {
                // The turn is running, so the send stands. Its result still arrives.
                Logger(subsystem: "io.nlopez.alas", category: "peer-outbox")
                    .error("Could not store that session \(child.childSessionId, privacy: .public) is awaited: \(String(describing: error), privacy: .public)")
            }
            notePeerAvailability(serverId)
            environment.peerNeedsCollecting(serverId)
            return json(ACPOrchestrationSendResponse(messageId: environment.makeID(), state: "queued"))
        case .failure(let error):
            return .error(peerFailureMessage(error, child: child))
        }
    }

    private func readOnPeer(
        _ child: ACPDelegationRecord, request: ACPDelegatedSessionReadRequest, origin: ACPOrchestrationSessionOrigin
    ) async -> AlasCLIResponse {
        guard case .success = ACPSessionOrchestrationPolicy.authorizeChildControl(
            callerSessionId: origin.sessionId, callerProjectId: origin.projectId, target: child
        ) else {
            return .error(Self.cannotReadMessage)
        }
        let serverId = child.peerServerId ?? ""
        guard let peers = environment.delegationPeers() else {
            return .error(Self.message(for: .unreachable(peer: peerName(serverId))))
        }
        switch await peers.read(
            serverId: serverId, sessionID: child.childSessionId,
            offset: request.offset, limit: request.limit, maxChars: request.maxChars
        ) {
        case .success(let data): return .text([String(decoding: data, as: UTF8.self)])
        case .failure(let error):
            let message = peerFailureMessage(error, child: child)
            if case .notFound = error { await failGonePeerChild(child.childSessionId) }
            return .error(message)
        }
    }

    /// Past its authorization, which the caller shares with a local child.
    private func interruptOnPeer(_ child: ACPDelegationRecord) async -> AlasCLIResponse {
        let serverId = child.peerServerId ?? ""
        guard let peers = environment.delegationPeers() else {
            return .error(Self.message(for: .unreachable(peer: peerName(serverId))))
        }
        switch await peers.interrupt(serverId: serverId, sessionID: child.childSessionId) {
        case .success(let cancelRequested):
            return json(ACPOrchestrationInterruptResponse(sessionId: child.childSessionId, cancelRequested: cancelRequested))
        case .failure(.notFound) where child.phase != .ready:
            return json(ACPOrchestrationInterruptResponse(sessionId: child.childSessionId, cancelRequested: false))
        case .failure(let error):
            return .error(peerFailureMessage(error, child: child))
        }
    }

    // MARK: Waiting on a paired Mac

    /// How often a wait asks a peer again without being told to.
    private static let peerStatusPollMillis: Int64 = 2_000

    /// One status question to a peer. It runs apart from the waits reading it:
    /// a peer that does not answer takes a minute to fail, which would hold a
    /// wait past its timeout and the CLI's read timeout.
    private final class PeerStatusRound {
        var answer: Result<Data, ACPPeerError>?
    }

    /// What one `session_wait` has heard about its peer children.
    private final class PeerWaitState {
        var heard: [String: ACPOrchestrationWaitResponse.Session] = [:]
        var rounds: [(serverId: String, ids: [String], round: PeerStatusRound)] = []
        var nextAskAt: [String: Int64] = [:]
        var seenSignals: [String: Int] = [:]
    }

    /// Tells waits that `serverId` has news, so they ask it again now. The
    /// peer outbox collector calls this for every signal it hears.
    public func peerOutboxDidChange(serverId: String) {
        peerOutboxSignals[serverId, default: 0] += 1
    }

    /// The question already out for exactly these children, or a new one, so
    /// a wait's next slice shares it instead of stacking up another.
    private func statusRound(serverId: String, ids: [String], peers: ACPDelegationPeers) -> PeerStatusRound {
        if let round = peerStatusRounds[serverId]?[ids] { return round }
        let round = PeerStatusRound()
        peerStatusRounds[serverId, default: [:]][ids] = round
        Task { @MainActor [weak self] in
            round.answer = await peers.status(serverId: serverId, sessionIDs: ids)
            if self?.peerStatusRounds[serverId]?[ids] === round {
                self?.peerStatusRounds[serverId]?[ids] = nil
            }
        }
        return round
    }

    private func collectPeerAnswers(into state: PeerWaitState) {
        state.rounds.removeAll { pending in
            guard let answer = pending.round.answer else { return false }
            switch answer {
            case .success(let data):
                // A reply that cannot be read says nothing: keep asking.
                let reply = try? JSONDecoder().decode(ACPOrchestrationWaitResponse.self, from: data)
                for session in reply?.sessions ?? [] where pending.ids.contains(session.sessionId) {
                    state.heard[session.sessionId] = session
                }
            case .failure(.notFound) where pending.ids.count == 1:
                // Only one child this can be about.
                let id = pending.ids[0]
                state.heard[id] = .init(
                    sessionId: id, state: ACPOrchestrationWaitResponse.Session.goneState, settled: true,
                    lastAgentText: nil, failure: nil
                )
            case .failure(.refused), .failure(.notFound):
                // Not proof of anything about the children: keep asking.
                for id in pending.ids
                where state.heard[id]?.state == ACPOrchestrationWaitResponse.Session.peerUnreachableState {
                    state.heard[id] = nil
                }
            case .failure(.unreachable), .failure(.outdated), .failure(.revoked):
                // A child the revocation failed reports that from its row and
                // is not asked about. One it left alone is not called failed:
                // pairing again would still bring its outcome.
                for id in pending.ids { state.heard[id] = Self.peerUnreachable(id) }
            }
            return true
        }
    }

    /// A child's phase changed, so what was heard about it, or is still being
    /// asked, predates that: a `gone` from before a start reached the peer
    /// would otherwise be reported for the running child.
    private func forgetPeerAnswers(about id: String, serverId: String, state: PeerWaitState) {
        state.heard[id] = nil
        state.rounds.removeAll { $0.serverId == serverId }
        state.nextAskAt[serverId] = nil
        peerStatusRounds[serverId] = nil
    }

    private static func peerUnreachable(_ id: String) -> ACPOrchestrationWaitResponse.Session {
        .init(
            sessionId: id, state: ACPOrchestrationWaitResponse.Session.peerUnreachableState, settled: true,
            lastAgentText: nil, failure: nil
        )
    }

    /// Asks each peer about its children whose answer can still change, once
    /// its interval passed or it signalled, one question at a time per peer.
    private func askPeers(about children: [ACPDelegationRecord], state: PeerWaitState) {
        let open = children.filter { child in
            guard child.phase == .ready else { return child.phase == .starting }
            guard let heard = state.heard[child.childSessionId] else { return true }
            return !heard.settled || heard.state == ACPOrchestrationWaitResponse.Session.peerUnreachableState
        }
        let now = environment.nowMillis()
        for (serverId, children) in Dictionary(grouping: open, by: { $0.peerServerId ?? "" }) {
            let signal = peerOutboxSignals[serverId, default: 0]
            guard !state.rounds.contains(where: { $0.serverId == serverId }),
                  now >= state.nextAskAt[serverId, default: .min] || signal != state.seenSignals[serverId, default: 0]
            else { continue }
            state.nextAskAt[serverId] = now + Self.peerStatusPollMillis
            state.seenSignals[serverId] = signal
            // Sorted: rounds are shared by exactly this list.
            let ids = children.map(\.childSessionId).sorted()
            guard let peers = environment.delegationPeers() else {
                for id in ids { state.heard[id] = Self.peerUnreachable(id) }
                continue
            }
            for start in stride(from: 0, to: ids.count, by: ACPDelegatedSessionWaitRequest.maxSessions) {
                let batch = Array(ids[start..<min(start + ACPDelegatedSessionWaitRequest.maxSessions, ids.count)])
                state.rounds.append((serverId, batch, statusRound(serverId: serverId, ids: batch, peers: peers)))
            }
        }
    }

    /// A peer's child as a wait reports it now. A child ended here needs no
    /// peer. One still starting may not have reached the peer, so "gone" means
    /// nothing for it yet; for one that started it is reported as it stands.
    private func peerWaitSession(
        _ child: ACPDelegationRecord, state: PeerWaitState
    ) -> ACPOrchestrationWaitResponse.Session {
        let local = ACPSessionOrchestrationPolicy.publicState(phase: child.phase, runtime: nil, archived: false).rawValue
        let id = child.childSessionId
        if child.phase == .failed || child.phase == .closed {
            return .init(sessionId: id, state: local, settled: true, lastAgentText: nil, failure: child.failureMessage)
        }
        if let heard = state.heard[id],
           child.phase != .starting || heard.state != ACPOrchestrationWaitResponse.Session.goneState {
            return heard
        }
        return .init(sessionId: id, state: local, settled: false, lastAgentText: nil, failure: nil)
    }

    public func create(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionNewRequest
    ) async -> AlasCLIResponse {
        let parentLocation = environment.sessionLocation(origin.sessionId)
        guard let parentSession = parentLocation?.manager.liveSession(for: origin.sessionId) else {
            return .error("The originating ACP session is no longer available.")
        }

        let parent: ACPDelegationRecord?
        do {
            parent = try await environment.persistence.parent(childSessionId: origin.sessionId)
        } catch {
            return .error("Could not verify session delegation.")
        }
        guard case .success = ACPSessionOrchestrationPolicy.authorizeCreate(parent: parent) else {
            return .error(Self.delegatedChildCannotCreate)
        }
        if request.peer == nil, request.project != nil {
            return .error("--project only applies with --peer.")
        }

        let task: String
        let prompt: String
        let role = request.role?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let role, role.isEmpty { return .error("role must not be blank") }
        do {
            task = try ACPSessionOrchestrationPolicy.validatedPrompt(request.prompt)
            prompt = Self.framedPrompt(task, role: role)
        } catch ACPSessionOrchestrationPolicy.Error.blankPrompt {
            return .error("prompt must not be blank")
        } catch {
            return .error("Could not validate delegated session request.")
        }

        if let peer = request.peer {
            return await createOnPeer(peer, request: request, task: task, role: role, parent: parentSession, origin: origin)
        }

        let childID = environment.makeID()
        let now = environment.now()
        switch request.worktree {
        case .current:
            guard let worktree = environment.worktree(origin.worktreeId) else {
                return .error("The current worktree is no longer available.")
            }
            let agentID: String
            do {
                agentID = try await resolveAgent(
                    requestedId: request.agentId,
                    parentAgentId: parentSession.agentId,
                    origin: origin,
                    worktree: worktree
                )
            } catch ACPSessionOrchestrationPolicy.Error.agentUnavailable(let id) {
                return .error("Agent is not enabled or ACP-capable: \(id)")
            } catch {
                return .error("Could not validate delegated session request.")
            }
            if let rejection = modelSelectionRejection(request.modelSelection, agentID: agentID, worktree: worktree) {
                return .error(rejection)
            }
            return response(await createChild(
                childID: childID,
                origin: origin,
                prompt: prompt,
                agentID: agentID,
                modelSelection: request.modelSelection,
                role: role,
                worktree: worktree,
                request: .current(worktreeId: worktree.id),
                phase: .starting,
                now: now
            ))
        case .existing(let id):
            guard let worktree = environment.existingWorktree(origin.projectId, id) else {
                return .error("The requested worktree is not available in this project.")
            }
            let agentID: String
            do {
                agentID = try await resolveAgent(
                    requestedId: request.agentId,
                    parentAgentId: parentSession.agentId,
                    origin: origin,
                    worktree: worktree
                )
            } catch ACPSessionOrchestrationPolicy.Error.agentUnavailable(let id) {
                return .error("Agent is not enabled or ACP-capable: \(id)")
            } catch {
                return .error("Could not validate delegated session request.")
            }
            if let rejection = modelSelectionRejection(request.modelSelection, agentID: agentID, worktree: worktree) {
                return .error(rejection)
            }
            return response(await createChild(
                childID: childID,
                origin: origin,
                prompt: prompt,
                agentID: agentID,
                modelSelection: request.modelSelection,
                role: role,
                worktree: worktree,
                request: .existing(worktreeId: worktree.id),
                phase: .starting,
                now: now
            ))
        case .new(let branch, let base):
            switch GitNameValidator.validateBranchName(branch) {
            case .valid:
                break
            case .invalid(let message):
                return .error("invalid branch name: \(message)")
            }
            guard let destination = environment.newWorktreeDestination(origin.projectId, branch) else {
                return .error("The project is no longer available.")
            }
            let agentID: String
            do {
                agentID = try ACPSessionOrchestrationPolicy.resolveAgent(
                    requestedId: request.agentId,
                    parentAgentId: parentSession.agentId,
                    available: environment.configuredAgents()
                )
            } catch ACPSessionOrchestrationPolicy.Error.agentUnavailable(let id) {
                return .error("Agent is not enabled or ACP-capable: \(id)")
            } catch {
                return .error("Could not validate delegated session request.")
            }
            // The new worktree belongs to the same project, so it runs on the
            // caller's host.
            if let rejection = modelSelectionRejection(
                request.modelSelection, agentID: agentID, worktree: environment.worktree(origin.worktreeId)
            ) {
                return .error(rejection)
            }
            return response(await createChildInNewWorktree(
                childID: childID,
                origin: origin,
                prompt: prompt,
                agentID: agentID,
                modelSelection: request.modelSelection,
                role: role,
                branch: branch,
                base: base,
                destination: destination,
                now: now
            ) { recordDestination in
                await self.environment.createWorktree(origin.projectId, branch, base, recordDestination)
            })
        }
    }

    /// Starts a child a paired Mac asked for, as an ordinary delegation whose
    /// parent is the peer's sentinel, so its outcomes wait in that peer's
    /// outbox. Refuses what can be known now; what goes wrong later fails the
    /// child, which the peer hears through the outbox. A repeated request gets
    /// the child the first one started.
    public func startForPeer(_ start: ACPPeerChildStart) async -> ACPPeerStartResult {
        let sentinel = ACPPeerParent.sentinel(serverId: start.peerServerId)
        guard ACPPeerParent.serverId(from: sentinel) != nil, !start.childID.isEmpty else {
            return .refused("The delegation request names no peer or child.")
        }
        let existing: ACPDelegationRecord?
        do {
            existing = try await environment.persistence.delegation(childSessionId: start.childID)
        } catch {
            return .refused("Could not verify session delegation.")
        }
        if let existing { return await repeatedPeerStart(start, existing: existing) }

        guard let project = environment.project(start.projectID) else {
            return .refused("The project is no longer available.")
        }
        guard project.host == nil else { return .refused("Delegated sessions cannot start in an SSH project.") }
        guard !project.isFolder else { return .refused("Delegated sessions cannot start in a folder project.") }
        // The id comes from the peer: it must not reach a session that is not
        // its child.
        guard environment.sessionLocation(start.childID) == nil else { return .refused(Self.sessionIdTakenReason) }
        let role = start.role?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let role, role.isEmpty { return .refused("role must not be blank") }
        guard let task = try? ACPSessionOrchestrationPolicy.validatedPrompt(start.prompt) else {
            return .refused("prompt must not be blank")
        }
        let prompt = Self.framedPrompt(task, role: role)
        let now = environment.now()

        let created: ACPOrchestrationNewResponse?
        switch start.target {
        case .worktree(let path):
            // The exact root, as `SessionsAPI` matches it. The peer resolved
            // names already, and the lookup would match a branch name, or the
            // worktree containing a path that is no longer one itself.
            guard let worktree = environment.existingWorktree(start.projectID, path),
                  worktree.path.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
            else {
                return .refused("The worktree is not listed, or is archived.")
            }
            if await environment.manager(worktree)?.persistedSessionRow(id: start.childID) != nil {
                return .refused(Self.sessionIdTakenReason)
            }
            let origin = ACPOrchestrationSessionOrigin(sessionId: sentinel, projectId: start.projectID, worktreeId: worktree.id)
            guard let agentID = try? ACPSessionOrchestrationPolicy.resolveAgent(
                requestedId: start.agentID,
                parentAgentId: start.agentID,
                available: await environment.availableAgents(origin, worktree)
            ) else {
                return .refused("Agent is not enabled or ACP-capable: \(start.agentID)")
            }
            if let rejection = modelSelectionRejection(start.modelSelection, agentID: agentID, worktree: worktree) {
                return .refused(rejection)
            }
            // Checked again when the child starts, where a refusal fails it.
            if let refusal = await environment.admitChild(worktree, agentID) { return .refused(refusal) }
            created = await createChild(
                childID: start.childID,
                origin: origin,
                prompt: prompt,
                agentID: agentID,
                modelSelection: start.modelSelection,
                role: role,
                worktree: worktree,
                request: .existing(worktreeId: worktree.id),
                phase: .starting,
                autoRun: start.autoRun,
                now: now
            )
        case .newWorktree(let branch, let base, let expectedBaseSHA):
            for name in [branch, base] {
                if case .invalid(let message) = GitNameValidator.validateBranchName(name) {
                    return .refused("invalid branch name: \(message)")
                }
            }
            guard let destination = environment.newWorktreeDestination(start.projectID, branch) else {
                return .refused("The project is no longer available.")
            }
            guard let agentID = try? ACPSessionOrchestrationPolicy.resolveAgent(
                requestedId: start.agentID,
                parentAgentId: start.agentID,
                available: environment.configuredAgents()
            ) else {
                return .refused("Agent is not enabled or ACP-capable: \(start.agentID)")
            }
            // Peer children only run in local projects, so the worktree it
            // will be has the same host as this stand-in.
            let upcoming = Worktree(
                id: Worktree.makeId(path: destination), projectId: start.projectID, name: branch, branch: branch,
                path: destination, status: .clean, lastActivity: Date(timeIntervalSince1970: TimeInterval(now))
            )
            if let rejection = modelSelectionRejection(start.modelSelection, agentID: agentID, worktree: upcoming) {
                return .refused(rejection)
            }
            let repo = URL(fileURLWithPath: project.path)
            created = await createChildInNewWorktree(
                childID: start.childID,
                origin: .init(sessionId: sentinel, projectId: start.projectID, worktreeId: upcoming.id),
                prompt: prompt,
                agentID: agentID,
                modelSelection: start.modelSelection,
                role: role,
                branch: branch,
                base: base,
                destination: destination,
                autoRun: start.autoRun,
                now: now
            ) { recordDestination in
                await self.createWorktreeForPeerChild(
                    start, branch: branch, base: base, expectedBaseSHA: expectedBaseSHA, repo: repo,
                    recordDestination: recordDestination
                )
            }
        }
        if let created { return .started(sessionId: created.sessionId, state: created.state) }
        // Another copy of this request can win the insert.
        if let winner = try? await environment.persistence.delegation(childSessionId: start.childID) {
            return await repeatedPeerStart(start, existing: winner)
        }
        return .refused("Could not persist delegated session.")
    }

    private static let sessionIdTakenReason = "A session with this id already exists."

    private func repeatedPeerStart(_ start: ACPPeerChildStart, existing: ACPDelegationRecord) async -> ACPPeerStartResult {
        guard ACPPeerParent.serverId(from: existing.parentSessionId) == start.peerServerId else {
            return .refused(Self.sessionIdTakenReason)
        }
        return .started(sessionId: existing.childSessionId, state: await waitSnapshot(sessionId: existing.childSessionId).state)
    }

    private func createWorktreeForPeerChild(
        _ start: ACPPeerChildStart,
        branch: String,
        base: String,
        expectedBaseSHA: String?,
        repo: URL,
        recordDestination: @escaping @MainActor (URL) async throws -> Void
    ) async -> Result<Worktree, WorktreeCreationError> {
        let resolvedBase: String
        switch await environment.resolvePeerWorktreeBase(branch, base, expectedBaseSHA, repo) {
        case .success(let base): resolvedBase = base
        case .failure(let error): return .failure(error)
        }
        switch await environment.createPeerWorktree(start.projectID, branch, resolvedBase, recordDestination) {
        case .failure(let error):
            return .failure(error)
        case .success(let created):
            if created.skippedRepoHook,
               let record = try? await environment.persistence.delegation(childSessionId: start.childID) {
                let context = ACPDelegatedOutcomeText.Context(
                    childSessionId: record.childSessionId, agentId: record.agentId,
                    worktreeName: created.worktree.name, role: record.role
                )
                await enqueueOutcome(.init(
                    id: "notice-\(record.childSessionId)-repo-hook-skipped",
                    sourceSessionId: record.childSessionId,
                    targetSessionId: record.parentSessionId,
                    prompt: ACPDelegatedOutcomeText.peerRepoHookSkipped(context, machine: peerMachineName()),
                    createdAt: environment.now(),
                    kind: .notice
                ), child: record)
            }
            return .success(created.worktree)
        }
    }

    private static func framedPrompt(_ task: String, role: String?) -> String {
        role.map { "[alas system] Your role in this delegated task is \($0).\n\n\(task)" } ?? task
    }

    private func response(_ created: ACPOrchestrationNewResponse?) -> AlasCLIResponse {
        created.map { json($0) } ?? .error("Could not persist delegated session.")
    }

    private func modelSelectionRejection(
        _ selection: ACPDelegatedModelSelection?,
        agentID: String,
        worktree: Worktree?
    ) -> String? {
        guard let selection else { return nil }
        guard let error = ACPSessionOrchestrationPolicy.preflightModelSelection(
            selection,
            agentId: agentID,
            launchModels: worktree.flatMap { environment.launchModels(agentID, $0) }
        ) else { return nil }
        return error.localizedDescription
    }

    private func resolveAgent(
        requestedId: String?,
        parentAgentId: String,
        origin: ACPOrchestrationSessionOrigin,
        worktree: Worktree
    ) async throws -> String {
        try ACPSessionOrchestrationPolicy.resolveAgent(
            requestedId: requestedId,
            parentAgentId: parentAgentId,
            available: await environment.availableAgents(origin, worktree)
        )
    }

    public func send(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionMessageRequest
    ) async -> AlasCLIResponse {
        let prompt: String
        do {
            prompt = try ACPSessionOrchestrationPolicy.validatedPrompt(request.prompt)
        } catch {
            return .error("prompt must not be blank")
        }
        let callerParent: ACPDelegationRecord?
        let targetParent: ACPDelegationRecord?
        do {
            callerParent = try await environment.persistence.parent(childSessionId: origin.sessionId)
            if let callerParent, ACPPeerParent.serverId(from: callerParent.parentSessionId) != nil {
                return .error(
                    "This session was delegated from another machine and cannot message its parent. "
                        + "Your final message is your report to the parent."
                )
            }
            targetParent = try await environment.persistence.parent(childSessionId: request.targetSessionId)
            if let targetParent, targetParent.peerServerId != nil {
                return await sendToPeer(targetParent, prompt: prompt, origin: origin)
            }
            let target = environment.sessionLocation(request.targetSessionId)
            guard let targetProjectId = target?.origin.projectId ?? targetParent?.projectId ?? callerParent?.projectId else {
                return .error("The target ACP session is not available.")
            }
            guard case .success = ACPSessionOrchestrationPolicy.authorizeSend(
                callerSessionId: origin.sessionId,
                callerProjectId: origin.projectId,
                targetSessionId: request.targetSessionId,
                targetProjectId: targetProjectId,
                callerParent: callerParent,
                targetParent: targetParent
            ) else {
                return .error("Messages may only be sent to a direct parent or child session.")
            }
            guard ACPSessionOrchestrationPolicy.acceptsMessages(target: targetParent) else {
                return .error("The target delegated session is not available.")
            }
            let targetIsStillStarting = targetParent?.phase == .creatingWorktree
                || targetParent?.phase == .starting
            if !targetIsStillStarting,
               await resolveDeliveryTarget(
                   sessionID: request.targetSessionId,
                   callerParent: callerParent,
                   targetParent: targetParent
               ) == nil {
                return .error("The target ACP session is not available.")
            }
        } catch {
            return .error("Could not verify session delegation.")
        }

        let targetSession = environment.sessionLocation(request.targetSessionId)?.manager.liveSession(for: request.targetSessionId)
        targetSession?.nextPromptWorkCount += 1
        var deliveryScheduled = false
        defer { if !deliveryScheduled { targetSession?.nextPromptWorkCount -= 1 } }
        // A child's report is framed at enqueue, not delivery, so every
        // delivery path (and an older build sharing the store) hands the
        // parent the same text.
        let deliveredPrompt = callerParent.flatMap { record in
            record.parentSessionId == request.targetSessionId
                ? ACPDelegatedOutcomeText.childReport(outcomeContext(for: record), message: prompt)
                : nil
        } ?? prompt
        let message = ACPDelegatedMessage(
            id: environment.makeID(),
            sourceSessionId: origin.sessionId,
            targetSessionId: request.targetSessionId,
            prompt: deliveredPrompt,
            createdAt: environment.now()
        )
        // The phase was checked above, but another instance sharing the store
        // can fail the target in between; the store rechecks it atomically
        // with the insert, so a failed child never gets a stranded row.
        do {
            guard try await environment.persistence.enqueueUnlessTargetEnded(message) else {
                return .error("The target delegated session is not available.")
            }
        } catch {
            return .error("Could not queue delegated message.")
        }
        targetSession?.hasPendingDelegatedMessages = true
        if callerParent?.parentSessionId == request.targetSessionId {
            // `nowMillis`, not `message.createdAt` (seconds): this is compared
            // against `ACPTurnCompletion.startedAt`, also milliseconds, in
            // `outcomeDisposition` — whole-second precision let a report near
            // the end of one turn be mistaken for covering the next.
            try? await environment.persistence.markParentReport(
                childSessionId: origin.sessionId,
                at: environment.nowMillis()
            )
        }
        environment.notifyChanged()
        deliveryScheduled = true
        Task { @MainActor in
            defer { targetSession?.nextPromptWorkCount -= 1 }
            await self.deliverPendingMessages(
                to: request.targetSessionId,
                callerParent: callerParent,
                targetParent: targetParent
            )
        }
        return json(ACPOrchestrationSendResponse(messageId: message.id, state: "queued"))
    }

    public func perform(origin: ACPOrchestrationSessionOrigin, _ action: ACPDelegatedSessionAction) async -> AlasCLIResponse {
        switch action {
        case .read(let request): await read(origin: origin, request: request)
        case .search(let request): await search(origin: origin, request: request)
        case .wait(let request): await wait(origin: origin, request: request)
        case .interrupt(let targetSessionId): await interrupt(origin: origin, targetSessionId: targetSessionId)
        }
    }

    /// `session_read`: one page of a direct relative's transcript, of a fork
    /// read by its source session, or of a session the user attached to one
    /// of the caller's prompts.
    public func read(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionReadRequest
    ) async -> AlasCLIResponse {
        if let child = await peerChild(request.targetSessionId) {
            return await readOnPeer(child, request: request, origin: origin)
        }
        let readable: ReadableSession
        switch await readableSession(origin: origin, targetSessionId: request.targetSessionId) {
        case .success(let found): readable = found
        case .failure(let error): return .error(error.message)
        }
        defer { readable.release() }
        let session = readable.session
        let page = ACPSessionTranscriptReader.page(
            ACPSessionTranscriptReader.entries(session.transcript.messages),
            offset: request.offset,
            limit: request.limit,
            maxChars: request.maxChars,
            lastEntryIsLive: Self.runtimeState(session) != .idle
        )
        return json(ACPOrchestrationReadResponse(
            sessionId: request.targetSessionId,
            entries: page.entries,
            start: page.start,
            end: page.end,
            total: page.total
        ))
    }

    /// `session_search`: text matches across the caller's direct parent and
    /// children, the same sessions `session_list` shows. Sessions without a
    /// readable transcript are skipped.
    public func search(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionSearchRequest
    ) async -> AlasCLIResponse {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .error("query must not be blank") }
        let targets: [ACPOrchestrationVisibleSession]
        do {
            targets = ACPSessionOrchestrationPolicy.visibleSessions(
                callerSessionId: origin.sessionId,
                parent: try await environment.persistence.parent(childSessionId: origin.sessionId),
                children: try await environment.persistence.children(parentSessionId: origin.sessionId)
            ).filter { $0.relationship != nil }
        } catch {
            return .error("Could not load delegated sessions.")
        }
        var matches: [ACPOrchestrationSearchResponse.Match] = []
        var truncated = false
        search: for target in targets {
            guard case .success(let readable) = await readableSession(
                origin: origin, targetSessionId: target.sessionId
            ) else { continue }
            let entries = ACPSessionTranscriptReader.entries(readable.session.transcript.messages)
            readable.release()
            for match in ACPSessionTranscriptReader.search(entries, query: query) {
                guard matches.count < request.limit else {
                    truncated = true
                    break search
                }
                matches.append(.init(
                    sessionId: target.sessionId, index: match.index, role: match.role, snippet: match.snippet
                ))
            }
        }
        return json(ACPOrchestrationSearchResponse(matches: matches, truncated: truncated))
    }

    public static let waitPollInterval: Duration = .milliseconds(250)

    /// `session_wait`: returns once every listed direct child has settled
    /// (see `ACPSessionOrchestrationPolicy.waitSettled`) or the timeout
    /// passes, with each child's state and latest agent text either way.
    public func wait(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionWaitRequest
    ) async -> AlasCLIResponse {
        var sessionIds: [String] = []
        for id in request.targetSessionIds where !sessionIds.contains(id) {
            sessionIds.append(id)
        }
        var peerChildren: [String: ACPDelegationRecord] = [:]
        do {
            for id in sessionIds {
                let target = try await environment.persistence.delegation(childSessionId: id)
                guard case .success = ACPSessionOrchestrationPolicy.authorizeChildControl(
                    callerSessionId: origin.sessionId,
                    callerProjectId: origin.projectId,
                    target: target
                ) else {
                    return .error("Only direct child sessions can be waited on: \(id)")
                }
                if let target, target.peerServerId != nil { peerChildren[id] = target }
            }
        } catch {
            return .error("Could not verify session delegation.")
        }
        let peerState = PeerWaitState()
        let deadline = environment.nowMillis() + Int64(request.timeoutMillis)
        while true {
            if !peerChildren.isEmpty {
                // A retry can move a child on during the wait.
                for (id, known) in peerChildren {
                    guard let current = await peerChild(id) else { continue }
                    if current.phase != known.phase, let serverId = current.peerServerId {
                        forgetPeerAnswers(about: id, serverId: serverId, state: peerState)
                    }
                    peerChildren[id] = current
                }
                collectPeerAnswers(into: peerState)
                askPeers(about: Array(peerChildren.values), state: peerState)
                // An answer that is ready, such as a link known to be down,
                // need not wait for the next poll.
                await Task.yield()
                collectPeerAnswers(into: peerState)
                for (id, child) in peerChildren
                where child.phase == .ready && peerState.heard[id]?.state == ACPOrchestrationWaitResponse.Session.goneState {
                    await failGonePeerChild(id)
                    if let current = await peerChild(id) { peerChildren[id] = current }
                }
            }
            var sessions: [ACPOrchestrationWaitResponse.Session] = []
            for id in sessionIds {
                if let child = peerChildren[id] {
                    sessions.append(peerWaitSession(child, state: peerState))
                } else {
                    sessions.append(await waitSnapshot(sessionId: id))
                }
            }
            let settled = sessions.allSatisfy(\.settled)
            if settled || environment.nowMillis() >= deadline || Task.isCancelled {
                return json(ACPOrchestrationWaitResponse(sessions: sessions, timedOut: !settled))
            }
            await environment.pause(Self.waitPollInterval)
        }
    }

    /// What `session_wait` with no timeout reports for a paired Mac's
    /// children, whichever projects they are in. An id that is not a child of
    /// that peer reports `Session.goneState` instead of failing the others, so
    /// one lost child can be told apart; a store that cannot say answers an
    /// error, never gone.
    public func peerStatus(peerServerId: String, sessionIDs: [String]) async -> AlasCLIResponse {
        var seen = Set<String>()
        var sessions: [ACPOrchestrationWaitResponse.Session] = []
        for id in sessionIDs where seen.insert(id).inserted {
            let record: ACPDelegationRecord?
            do {
                record = try await environment.persistence.delegation(childSessionId: id)
            } catch {
                return .error("Could not verify session delegation.")
            }
            if let record, ACPPeerParent.serverId(from: record.parentSessionId) == peerServerId {
                sessions.append(await waitSnapshot(sessionId: id))
            } else {
                sessions.append(.init(
                    sessionId: id, state: ACPOrchestrationWaitResponse.Session.goneState, settled: true, lastAgentText: nil, failure: nil
                ))
            }
        }
        return json(ACPOrchestrationWaitResponse(sessions: sessions, timedOut: !sessions.allSatisfy(\.settled)))
    }

    /// `session_interrupt`: cancels a direct child's running turn, as the
    /// Stop button would. A pending permission request is cancelled with the
    /// turn, never approved.
    public func interrupt(
        origin: ACPOrchestrationSessionOrigin,
        targetSessionId: String
    ) async -> AlasCLIResponse {
        do {
            let target = try await environment.persistence.delegation(childSessionId: targetSessionId)
            guard case .success = ACPSessionOrchestrationPolicy.authorizeChildControl(
                callerSessionId: origin.sessionId,
                callerProjectId: origin.projectId,
                target: target
            ) else {
                return .error("Only a direct child session can be interrupted.")
            }
            if let target, target.peerServerId != nil { return await interruptOnPeer(target) }
        } catch {
            return .error("Could not verify session delegation.")
        }
        guard let location = environment.sessionLocation(targetSessionId),
              let session = location.manager.liveSession(for: targetSessionId),
              Self.runtimeState(session) != .idle
        else {
            return json(ACPOrchestrationInterruptResponse(sessionId: targetSessionId, cancelRequested: false))
        }
        // False when another Alas instance holds the child's writer lease and
        // this one only mirrors it.
        let cancelRequested = await location.manager.interrupt(for: targetSessionId)
        return json(ACPOrchestrationInterruptResponse(sessionId: targetSessionId, cancelRequested: cancelRequested))
    }

    private static let cannotReadMessage = "Only a direct parent, child, or this session's fork transcript can be read."

    private struct ObservationError: Error {
        let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// A session whose transcript may be read: a fork of the caller, a
    /// session in the caller's project that the user attached to one of its
    /// prompts, or a direct parent or child, the same edge `session_send` may
    /// use. A session that is not live is hydrated from its stored
    /// transcript; an archived one is not readable (except a fork).
    private func readableSession(
        origin: ACPOrchestrationSessionOrigin,
        targetSessionId: String
    ) async -> Result<ReadableSession, ObservationError> {
        // No transcript here, whoever asks: `read` goes to the peer first, and
        // a user attaching the id to a prompt gives no way to reach it.
        if await peerChild(targetSessionId) != nil {
            return .failure(.init(message: "The target ACP session has no transcript available."))
        }
        if let fork = await readableFork(origin: origin, targetSessionId: targetSessionId) {
            return .success(ReadableSession(session: fork, release: {}))
        }
        if let location = await userAttachedLocation(origin: origin, targetSessionId: targetSessionId) {
            return await hydratedSession(targetSessionId, at: location)
        }
        let callerParent: ACPDelegationRecord?
        let targetParent: ACPDelegationRecord?
        do {
            callerParent = try await environment.persistence.parent(childSessionId: origin.sessionId)
            targetParent = try await environment.persistence.parent(childSessionId: targetSessionId)
        } catch {
            return .failure(.init(message: "Could not verify session delegation."))
        }
        guard let targetProjectId = environment.sessionLocation(targetSessionId)?.origin.projectId
            ?? targetParent?.projectId ?? callerParent?.projectId,
            case .success = ACPSessionOrchestrationPolicy.authorizeSend(
                callerSessionId: origin.sessionId,
                callerProjectId: origin.projectId,
                targetSessionId: targetSessionId,
                targetProjectId: targetProjectId,
                callerParent: callerParent,
                targetParent: targetParent
            )
        else {
            return .failure(.init(message: Self.cannotReadMessage))
        }
        guard let location = await resolveDeliveryTarget(
            sessionID: targetSessionId,
            callerParent: callerParent,
            targetParent: targetParent
        ) else {
            return .failure(.init(message: "The target ACP session has no transcript available."))
        }
        return await hydratedSession(targetSessionId, at: location)
    }

    /// Where `targetSessionId` lives when the user attached it to one of the
    /// caller's own prompts and it belongs to the caller's project.
    private func userAttachedLocation(
        origin: ACPOrchestrationSessionOrigin,
        targetSessionId: String
    ) async -> SessionLocation? {
        guard targetSessionId != origin.sessionId,
              let callerManager = environment.sessionLocation(origin.sessionId)?.manager
        else { return nil }
        // The attaching prompt may sit in older messages still backfilling.
        await callerManager.awaitBackfill(id: origin.sessionId)
        guard let caller = callerManager.liveSession(for: origin.sessionId),
              ACPSessionReference.attachedSessionIds(in: caller.transcript.messages).contains(targetSessionId),
              let location = await environment.referencedSessionLocation(targetSessionId, origin.projectId)
        else { return nil }
        guard location.origin.projectId == origin.projectId else {
            location.release?()
            return nil
        }
        return location
    }

    private func hydratedSession(
        _ targetSessionId: String,
        at location: SessionLocation
    ) async -> Result<ReadableSession, ObservationError> {
        let release = location.release ?? {}
        // A restored tab can still be loading its stored transcript, and
        // hydration applies only the tail before backfilling older messages,
        // which would shift every entry index between pages.
        await location.manager.hydrateIfNeeded(id: targetSessionId)
        await location.manager.awaitBackfill(id: targetSessionId)
        guard let session = location.manager.liveSession(for: targetSessionId) else {
            release()
            return .failure(.init(message: "The target ACP session has no transcript available."))
        }
        return .success(ReadableSession(session: session, release: release))
    }

    /// Fork access is read-only and scoped to its recorded source in the same store.
    /// Archived forks remain readable so a merge reference survives closing its tab.
    private func readableFork(
        origin: ACPOrchestrationSessionOrigin,
        targetSessionId: String
    ) async -> ACPSession? {
        let manager: ACPSessionManager
        if let caller = environment.sessionLocation(origin.sessionId) {
            guard caller.origin.projectId == origin.projectId,
                  caller.origin.worktreeId == origin.worktreeId else { return nil }
            manager = caller.manager
        } else {
            guard let worktree = environment.worktree(origin.worktreeId),
                  worktree.projectId == origin.projectId,
                  let resolved = environment.manager(worktree) else { return nil }
            manager = resolved
        }
        await manager.flushPersistence()
        guard let fork = try? await manager.persistence.loadFork(targetSessionID: targetSessionId),
              fork.sourceSessionID == origin.sessionId, fork.phase == .ready,
              await manager.persistedSessionRow(id: targetSessionId) != nil,
              manager.placeholderSession(id: targetSessionId) != nil else { return nil }
        await manager.hydrateIfNeeded(id: targetSessionId)
        await manager.awaitBackfill(id: targetSessionId)
        guard let session = manager.liveSession(for: targetSessionId), session.hydrationState == .ready else { return nil }
        return session
    }

    private func waitSnapshot(sessionId: String) async -> ACPOrchestrationWaitResponse.Session {
        let record = try? await environment.persistence.delegation(childSessionId: sessionId)
        let session = environment.sessionLocation(sessionId)?.manager.liveSession(for: sessionId)
        let runtime = session.map(Self.runtimeState)
        let phase = record?.phase ?? .closed
        var queued = session.map { ACPSessionOrchestrationPolicy.queueOwesTurn($0.queue) } ?? false
        var archived = false
        if session == nil, phase == .ready, let record {
            // Not live here: restored later, or driven by another instance.
            // Judge it by its stored queue, whose head stays until the turn
            // ends, and keep it unsettled when its store is out of reach.
            switch await storedTurnState(record) {
            case .archived: archived = true
            case .queue(let stored): queued = ACPSessionOrchestrationPolicy.queueOwesTurn(stored)
            case nil: queued = true
            }
        }
        let undelivered = !((try? await environment.persistence.pendingMessages(targetSessionId: sessionId)) ?? []).isEmpty
        let settled = archived || ACPSessionOrchestrationPolicy.waitSettled(
            phase: phase, runtime: runtime, hasPendingPrompts: queued || undelivered
        )
        // A settled child that is not live here still has its result in its
        // stored transcript; load it only now, not on every poll.
        var transcriptSession = session
        if transcriptSession == nil, settled, !archived, phase == .ready, let record,
           let location = await resolveDeliveryTarget(sessionID: sessionId, callerParent: record, targetParent: record) {
            await location.manager.hydrateIfNeeded(id: sessionId)
            transcriptSession = location.manager.liveSession(for: sessionId)
        }
        return .init(
            sessionId: sessionId,
            state: ACPSessionOrchestrationPolicy.publicState(phase: phase, runtime: runtime, archived: archived).rawValue,
            settled: settled,
            lastAgentText: transcriptSession.flatMap { ACPSessionTranscriptReader.lastAgentText($0.transcript.messages) },
            // A turn's failure is rewritten only when a turn ends, so until the
            // child settles it describes an earlier turn, not the running one.
            failure: record?.failureMessage ?? (settled ? session?.turnFailure
                ?? transcriptSession.flatMap { ACPSessionTranscriptReader.trailingTurnFailure($0.transcript.messages) } : nil)
        )
    }

    private enum StoredTurnState {
        case archived
        case queue([QueuedPrompt])
    }

    /// A child's persisted state when it has no live session here, or nil
    /// when its worktree or stored session cannot be reached.
    private func storedTurnState(_ record: ACPDelegationRecord) async -> StoredTurnState? {
        guard let worktreeId = record.childWorktreeId,
              let worktree = environment.worktree(worktreeId),
              let manager = environment.manager(worktree),
              let row = await manager.persistedSessionRow(id: record.childSessionId)
        else { return nil }
        if row.archived { return .archived }
        guard let queue = try? await manager.persistence.loadQueue(sessionId: record.childSessionId) else {
            return nil
        }
        return .queue(queue)
    }

    /// Entry point for a delegated child's finished turn. Non-children,
    /// terminal children and turns started by a PR shepherd prompt (the
    /// shepherd, not the parent, asked for that work) are ignored; everything
    /// else becomes an inbox row for the parent, wake or notice per
    /// `outcomeDisposition`.
    ///
    /// A child turn that settled at its result while the child's own
    /// background work still runs waits here (`defersOutcome`) and reports
    /// once that work ends, with the text the child ended on, or as cancelled
    /// when the user stopped that work. A later turn of
    /// the same child replaces it. Held in memory only: a restart in between
    /// loses it, and the child's turn then reports nothing, as a turn cut off
    /// by a restart does.
    public func childTurnCompleted(_ completion: ACPTurnCompletion) async {
        deferredOutcomes[completion.sessionId] = nil
        guard completion.delegatedSource?.isFromShepherd != true,
              let record = try? await environment.persistence.delegation(childSessionId: completion.sessionId),
              record.phase != .failed, record.phase != .closed
        else { return }
        if let location = environment.sessionLocation(completion.sessionId) {
            defer { location.release?() }
            if let session = location.manager.liveSession(for: completion.sessionId),
               ACPSessionOrchestrationPolicy.defersOutcome(result: completion.result, activity: session.activity) {
                deferOutcome(completion, session: session)
                return
            }
        }
        await enqueueTurnOutcome(completion, record: record)
    }

    private final class DeferredOutcome {
        let completion: ACPTurnCompletion
        let promptIDAtResult: Int
        /// Children still live at the result.
        let liveChildIds: Set<String>
        var subscriptions: [ChangeSubscription] = []
        var checkScheduled = false

        init(completion: ACPTurnCompletion, promptIDAtResult: Int, liveChildIds: Set<String>) {
            self.completion = completion
            self.promptIDAtResult = promptIDAtResult
            self.liveChildIds = liveChildIds
        }
    }

    private var deferredOutcomes: [String: DeferredOutcome] = [:]

    private func deferOutcome(_ completion: ACPTurnCompletion, session: ACPSession) {
        let childId = completion.sessionId
        let deferred = DeferredOutcome(
            completion: completion, promptIDAtResult: session.nextPromptID,
            liveChildIds: Set(session.subagents.values.filter(\.isRunning).map(\.subagentSessionId)))
        // Change signals fire before the new value is stored: look on the
        // next main-actor turn, once per burst of changes.
        let changed: () -> Void = { [weak self, weak deferred, weak session] in
            guard let deferred, !deferred.checkScheduled else { return }
            deferred.checkScheduled = true
            Task { @MainActor [weak self, weak deferred, weak session] in
                guard let deferred else { return }
                deferred.checkScheduled = false
                await self?.checkDeferredOutcome(deferred, childId: childId, session: session)
            }
        }
        deferred.subscriptions = [session.willChange.observe(changed), session.transcript.willChange.observe(changed)]
        deferredOutcomes[childId] = deferred
    }

    private func checkDeferredOutcome(_ deferred: DeferredOutcome, childId: String, session: ACPSession?) async {
        guard deferredOutcomes[childId] === deferred else { return }
        let step = ACPSessionOrchestrationPolicy.deferredOutcomeStep(
            activity: session?.activity,
            agentReady: session?.agentState == .ready,
            promptSentSince: session.map { $0.nextPromptID != deferred.promptIDAtResult } ?? false
        )
        switch step {
        case .wait:
            return
        case .discard:
            deferredOutcomes[childId] = nil
        case .deliver:
            deferredOutcomes[childId] = nil
            let original = deferred.completion
            let finalText = session.flatMap { ACPSessionTranscriptReader.lastAgentText($0.transcript.messages) }
            let root = session.map { $0.remoteSessionId ?? $0.id }
            let latestCycle = session?.backgroundTasks.last {
                $0.taskType == "turn" && $0.ownerSessionId == root
                    && Int64($0.startedAt.timeIntervalSince1970 * 1000) >= original.startedAt
            }
            let childCancelled = deferred.liveChildIds.contains { session?.subagents[$0]?.state == .cancelled }
            let completion = ACPTurnCompletion(
                sessionId: original.sessionId, startedAt: original.startedAt,
                result: ACPSessionOrchestrationPolicy.deferredOutcomeResult(
                    original.result, latestCycleState: latestCycle?.state, childCancelled: childCancelled),
                delegatedSource: original.delegatedSource, lastAgentText: finalText ?? original.lastAgentText)
            guard let record = try? await environment.persistence.delegation(childSessionId: childId),
                  record.phase != .failed, record.phase != .closed
            else { return }
            await enqueueTurnOutcome(completion, record: record)
        }
    }

    private func enqueueTurnOutcome(_ completion: ACPTurnCompletion, record: ACPDelegationRecord) async {
        let disposition = ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: completion.result,
            lastParentReportAt: record.lastParentReportAt,
            turnStartedAt: completion.startedAt
        )
        let context = outcomeContext(for: record)
        let prompt: String
        switch (disposition, completion.result) {
        case (.notice, .cancelled):
            prompt = ACPDelegatedOutcomeText.cancelled(context)
        case (.notice, .limited):
            prompt = ACPDelegatedOutcomeText.limited(context)
        case (.notice, _):
            prompt = ACPDelegatedOutcomeText.notice(context)
        case (.wake, .failed(let message)):
            prompt = ACPDelegatedOutcomeText.failure(context, message: message)
        case (.wake, .stopped(let reason)):
            prompt = ACPDelegatedOutcomeText.stopped(context, reason: reason.summary)
        case (.wake, _) where context.machine != nil:
            // The child's final message is its report to a parent on another Mac.
            prompt = ACPDelegatedOutcomeText.peerFinished(context, lastAgentText: completion.lastAgentText)
        case (.wake, _):
            prompt = ACPDelegatedOutcomeText.unreported(context, lastAgentText: completion.lastAgentText)
        }
        await enqueueOutcome(.init(
            id: "outcome-\(record.childSessionId)-\(completion.startedAt)",
            sourceSessionId: record.childSessionId,
            targetSessionId: record.parentSessionId,
            prompt: prompt,
            createdAt: environment.now(),
            kind: disposition == .wake ? .prompt : .notice
        ), child: record)
    }

    /// Mark a delegated child failed and wake its parent with the reason.
    /// Idempotent: the outcome id is fixed per child, so repeated calls
    /// update the phase but enqueue nothing new.
    public func markChildFailed(childSessionId: String, message: String) async {
        // The fixed outcome id (`outcome-<childId>-failed`) only dedupes via
        // INSERT OR IGNORE while the row is still in the inbox — once the
        // parent's outcome is delivered, the row is deleted and a later call
        // for the same already-failed child would re-enqueue and wake the
        // parent a second time for one failure. `claimFailedPhase` makes the
        // transition itself the source of truth: its conditional
        // `WHERE phase != 'failed'` inside one transaction (mirroring the
        // inbox's own `claimMessage`) ensures exactly one caller — even
        // across two Alas instances racing on the same shared SQLite file —
        // sees `true` and is responsible for the outcome. A separate read
        // before the write would leave a window where both readers see the
        // pre-transition phase before either writes.
        //
        // The outcome is built here, before the claim, because its text needs
        // the delegation record — but it is WRITTEN inside the claim's own
        // transaction, so the phase change and the parent's notification
        // commit together. Splitting them left a crash window that stranded
        // the child permanently: phase `.failed`, no outcome, and every later
        // call correctly losing the claim.
        guard let record = try? await environment.persistence.delegation(childSessionId: childSessionId)
        else { return }
        let outcome = failureOutcome(of: record, message: message)
        // A child still waiting on its model selection must never run the
        // parent's prompt on the agent's default model: drop it from the
        // session's queue, durably, before `.failed` lifts the prompt hold
        // (a later hydration of a failed child is not held).
        let holdsDispatch = ACPSessionOrchestrationPolicy.holdsPromptDispatch(target: record)
        let heldManager = holdsDispatch ? environment.sessionLocation(childSessionId)?.manager : nil
        let initialPromptGone = await heldManager?.discardDelegatedPrompt(
            messageId: initialPromptSource(for: record).messageId,
            in: childSessionId
        ) ?? true
        // A child whose model selection never took effect loses its held
        // inbox rows in the same transaction, so no path (startup recovery
        // included) can later run them on the agent's default model.
        let wonTransition = (try? await environment.persistence.claimFailedPhase(
            childSessionId: childSessionId,
            failureMessage: message,
            updatedAt: environment.now(),
            outcome: outcome,
            discardingHeldMessages: record.modelSelection != nil
        )) ?? false
        // Lift the hold only once `.failed` is durable: a claim that threw
        // (busy timeout, I/O) left the child `starting`, and a released hold
        // cannot be re-armed on this session object. If the prompt could not
        // be written out of the queue, the hold stays for this process.
        if let heldManager, initialPromptGone,
           (try? await environment.persistence.delegation(childSessionId: childSessionId))??.phase == .failed {
            heldManager.releaseDelegatedSelectionHold(childSessionId)
        }
        environment.notifyChanged()
        guard wonTransition else { return }
        notifyPeerOutbox(of: outcome.targetSessionId)
        await deliverPendingMessages(
            to: outcome.targetSessionId,
            callerParent: record,
            targetParent: nil
        )
    }

    private func failureOutcome(of record: ACPDelegationRecord, message: String) -> ACPDelegatedMessage {
        ACPDelegatedMessage(
            id: "outcome-\(record.childSessionId)-failed",
            sourceSessionId: record.childSessionId,
            targetSessionId: record.parentSessionId,
            prompt: ACPDelegatedOutcomeText.failure(outcomeContext(for: record), message: message),
            createdAt: environment.now(),
            kind: .prompt
        )
    }

    /// A delegated child stopped on something only a human can resolve. The
    /// parent is noticed at once, then woken only if the same request is still
    /// unresolved after the configured delay.
    public func childBlocked(_ blocker: ACPChildBlocker) async {
        guard let record = try? await environment.persistence.delegation(childSessionId: blocker.sessionId),
              record.phase != .failed, record.phase != .closed
        else { return }
        var context = outcomeContext(for: record)
        context.blockerSummary = blocker.summary
        await enqueueOutcome(.init(
            id: "blocker-\(blocker.sessionId)-\(blocker.requestKey)-notice",
            sourceSessionId: blocker.sessionId,
            targetSessionId: record.parentSessionId,
            prompt: ACPDelegatedOutcomeText.blocker(
                context, kindLabel: blocker.kind.rawValue, waitedSeconds: 0, escalated: false
            ),
            createdAt: environment.now(),
            kind: .notice
        ), child: record)

        let delay = environment.escalationDelaySeconds()
        guard delay > 0 else { return }
        environment.scheduleEscalationCheck(delay) { [weak self] in
            await self?.escalateBlockerIfStillBlocked(blocker)
        }
    }

    /// The delayed re-check, reached in production through
    /// `scheduleEscalationCheck` and called directly by tests. Reads live
    /// state rather than tracking timers, so a block the human already
    /// cleared simply produces nothing and no cancellation is required.
    public func escalateBlockerIfStillBlocked(_ blocker: ACPChildBlocker) async {
        guard environment.escalationDelaySeconds() > 0,
              let record = try? await environment.persistence.delegation(childSessionId: blocker.sessionId),
              record.phase != .failed, record.phase != .closed,
              case .wake = ACPSessionOrchestrationPolicy.escalation(
                  blocker: blocker,
                  liveBlockedRequestKeys: environment.blockedRequestKeys(blocker.sessionId)
              )
        else { return }
        var context = outcomeContext(for: record)
        context.blockerSummary = blocker.summary
        await enqueueOutcome(.init(
            id: "blocker-\(blocker.sessionId)-\(blocker.requestKey)",
            sourceSessionId: blocker.sessionId,
            targetSessionId: record.parentSessionId,
            prompt: ACPDelegatedOutcomeText.blocker(
                context,
                kindLabel: blocker.kind.rawValue,
                waitedSeconds: environment.escalationDelaySeconds(),
                escalated: true
            ),
            createdAt: environment.now(),
            kind: .prompt
        ), child: record)
    }

    private func outcomeContext(for record: ACPDelegationRecord) -> ACPDelegatedOutcomeText.Context {
        .init(
            childSessionId: record.childSessionId,
            agentId: record.agentId,
            worktreeName: record.childWorktreeId.flatMap { environment.worktree($0)?.name },
            role: record.role,
            machine: record.peerServerId.map(peerName)
                ?? (ACPPeerParent.serverId(from: record.parentSessionId) == nil ? nil : peerMachineName())
        )
    }

    /// This Mac's name as the delegating Mac shows it: the Remote display name,
    /// which defaults to the computer name.
    private func peerMachineName() -> String {
        let name = environment.machineName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "another Mac" : name
    }

    private func enqueueOutcome(_ message: ACPDelegatedMessage, child: ACPDelegationRecord) async {
        do {
            try await environment.persistence.enqueue(message)
        } catch {
            return
        }
        environment.notifyChanged()
        notifyPeerOutbox(of: message.targetSessionId)
        await deliverPendingMessages(
            to: message.targetSessionId,
            callerParent: child,
            targetParent: nil
        )
    }

    /// Tells the paired Mac a message waits for, when its target is one's
    /// sentinel. Outcomes and failures call this; `send`, the other path that
    /// enqueues, need not, because it cannot target a sentinel.
    private func notifyPeerOutbox(of targetSessionId: String) {
        if let peerServerId = ACPPeerParent.serverId(from: targetSessionId) {
            environment.peerOutboxChanged(peerServerId)
        }
    }

    /// Nil when the child could not be recorded. `autoRun`, when given,
    /// replaces this Mac's default for a new session.
    private func createChild(
        childID: String,
        origin: ACPOrchestrationSessionOrigin,
        prompt: String,
        agentID: String,
        modelSelection: ACPDelegatedModelSelection?,
        role: String?,
        worktree: Worktree,
        request: ACPDelegatedWorktreeRequest,
        phase: ACPDelegationPhase,
        autoRun: Bool? = nil,
        now: Int64
    ) async -> ACPOrchestrationNewResponse? {
        environment.rememberParent(childID, origin.sessionId)
        let record = ACPDelegationRecord(
            childSessionId: childID,
            parentSessionId: origin.sessionId,
            projectId: origin.projectId,
            parentWorktreeId: origin.worktreeId,
            childWorktreeId: worktree.id,
            agentId: agentID,
            worktreeRequest: request,
            pendingInitialPrompt: prompt,
            phase: phase,
            failureMessage: nil,
            createdAt: now,
            updatedAt: now,
            modelSelection: modelSelection,
            role: role
        )
        do {
            try await environment.persistence.insert(record)
        } catch {
            return nil
        }
        let parentSession = environment.sessionLocation(origin.sessionId)?.manager.liveSession(for: origin.sessionId)
        parentSession?.nextPromptWorkCount += 1
        environment.notifyChanged()
        Task { @MainActor in
            defer { parentSession?.nextPromptWorkCount -= 1 }
            await self.startPersistedChild(childID: childID, prompt: prompt, worktree: worktree, autoRun: autoRun)
        }
        return ACPOrchestrationNewResponse(sessionId: childID, state: "starting", worktreeId: worktree.id)
    }

    /// Records the child, then creates its worktree through `create` and
    /// starts it. Nil when the child could not be recorded.
    private func createChildInNewWorktree(
        childID: String,
        origin: ACPOrchestrationSessionOrigin,
        prompt: String,
        agentID: String,
        modelSelection: ACPDelegatedModelSelection?,
        role: String?,
        branch: String,
        base: String?,
        destination: URL,
        autoRun: Bool? = nil,
        now: Int64,
        create: @escaping (_ recordDestination: @escaping @MainActor (URL) async throws -> Void) async -> Result<Worktree, WorktreeCreationError>
    ) async -> ACPOrchestrationNewResponse? {
        let optimisticID = "pending-\(childID)"
        let record = ACPDelegationRecord(
            childSessionId: childID,
            parentSessionId: origin.sessionId,
            projectId: origin.projectId,
            parentWorktreeId: origin.worktreeId,
            childWorktreeId: nil,
            agentId: agentID,
            worktreeRequest: .new(
                branch: branch,
                base: base,
                destinationPath: destination.path,
                optimisticId: optimisticID
            ),
            pendingInitialPrompt: prompt,
            phase: .creatingWorktree,
            failureMessage: nil,
            createdAt: now,
            updatedAt: now,
            modelSelection: modelSelection,
            role: role
        )
        do {
            try await environment.persistence.insert(record)
        } catch {
            return nil
        }
        let parentSession = environment.sessionLocation(origin.sessionId)?.manager.liveSession(for: origin.sessionId)
        parentSession?.nextPromptWorkCount += 1
        environment.notifyChanged()
        Task { @MainActor in
            defer { parentSession?.nextPromptWorkCount -= 1 }
            let result = await create { prepared in
                // Recovery matches an interrupted create by this path, so it
                // must be the prepared one (remote home, virtual path).
                try await self.environment.persistence.updateWorktreeRequest(
                    childSessionId: childID,
                    request: .new(branch: branch, base: base, destinationPath: prepared.path, optimisticId: optimisticID),
                    updatedAt: self.environment.now()
                )
            }
            switch result {
            case .success(let worktree):
                await self.startPersistedChild(childID: childID, prompt: prompt, worktree: worktree, autoRun: autoRun)
            case .failure(let error):
                await self.markChildFailed(childSessionId: childID, message: error.message)
            }
        }
        return ACPOrchestrationNewResponse(sessionId: childID, state: "creating_worktree", worktreeId: nil)
    }

    private func startPersistedChild(childID: String, prompt: String, worktree: Worktree, autoRun: Bool? = nil) async {
        let record: ACPDelegationRecord?
        do {
            record = try await environment.persistence.delegation(childSessionId: childID)
        } catch {
            return
        }
        guard let record else { return }
        environment.rememberParent(childID, record.parentSessionId)
        let parentLocation = environment.sessionLocation(record.parentSessionId)
        let parentSession = parentLocation?.manager.liveSession(for: record.parentSessionId)
        let validationOrigin = parentLocation?.origin ?? ACPOrchestrationSessionOrigin(
            sessionId: childID,
            projectId: record.projectId,
            worktreeId: worktree.id
        )
        do {
            _ = try await resolveAgent(
                requestedId: record.agentId,
                parentAgentId: parentSession?.agentId ?? record.agentId,
                origin: validationOrigin,
                worktree: worktree
            )
        } catch ACPSessionOrchestrationPolicy.Error.agentUnavailable(let id) {
            await markChildFailed(childSessionId: childID, message: "Agent is not enabled or ACP-capable: \(id)")
            return
        } catch {
            await markChildFailed(childSessionId: childID, message: "Could not validate delegated session request.")
            return
        }
        try? await environment.persistence.updateChildWorktree(
            childSessionId: childID,
            worktreeId: worktree.id,
            phase: .starting,
            updatedAt: environment.now()
        )
        // The awaits above can cross a delete claim on the worktree, and a
        // child is admitted as any new session would be.
        if let refusal = await environment.admitChild(worktree, record.agentId) {
            await markChildFailed(childSessionId: childID, message: refusal)
            return
        }
        // Looked up after admission, which can replace the worktree's
        // manager when its project changed.
        guard let manager = environment.manager(worktree) else {
            await markChildFailed(childSessionId: childID, message: "Could not create ACP session manager.")
            return
        }
        if manager.liveSession(for: childID) == nil {
            _ = manager.createSession(
                id: childID,
                agentId: record.agentId,
                autoRunDefault: autoRun ?? environment.autoRunDefault()
            )
        }
        // Without a model selection the prompt is queued before attach, as it
        // always was, and goes out once the runner registers. With one, it is
        // queued only after the selection is acknowledged, and the session
        // holds every prompt (a human's in the open tab too) until then.
        if record.modelSelection != nil {
            manager.holdPromptsForDelegatedSelection(childID)
        } else {
            guard await manager.enqueueDelegatedPrompt(
                text: prompt,
                source: initialPromptSource(for: record),
                into: childID
            ) else {
                await markChildFailed(childSessionId: childID, message: "Could not queue initial prompt.")
                return
            }
        }
        await manager.attach(to: childID, freshlyCreated: true)
        guard let session = manager.liveSession(for: childID),
              session.agentState == .ready
        else {
            await markChildFailed(
                childSessionId: childID,
                message: delegatedChildStartFailureMessage(manager.liveSession(for: childID))
            )
            return
        }
        if let selection = record.modelSelection {
            guard await queueInitialPromptAfterModelSelection(
                selection, record: record, prompt: prompt, manager: manager
            ) else { return }
        }
        try? await environment.persistence.clearPendingInitialPrompt(childSessionId: childID, updatedAt: environment.now())
        let markedReady = (try? await environment.persistence.updatePhase(
            childSessionId: childID, phase: .ready, failureMessage: nil, updatedAt: environment.now()
        )) != nil
        // Unless `.ready` is durable, the child stays held: other instances
        // and the next launch still treat it as starting and reapply the
        // selection.
        if record.modelSelection != nil, markedReady {
            manager.releaseDelegatedSelectionHold(childID)
        }
        environment.notifyChanged()
        await deliverPendingMessages(
            to: childID,
            callerParent: record,
            targetParent: record
        )
    }

    public func initialPromptSource(for record: ACPDelegationRecord) -> ACPDelegatedPromptSource {
        ACPDelegatedPromptSource(
            sessionId: record.parentSessionId,
            messageId: ACPSessionOrchestrationPolicy.initialPromptMessageId(childSessionId: record.childSessionId)
        )
    }

    /// Applies a child's requested model/reasoning on its attached session
    /// and only then queues the initial prompt, so no prompt can run on the
    /// agent's default. Any failure marks the child failed, which wakes the
    /// parent with the reason, and nothing is queued. Also used by startup
    /// recovery, so a restarted child reapplies the same selection. The
    /// session's prompt hold stays on: the caller lifts it once the child is
    /// marked ready, and the prompt is queued ahead of anything a human typed
    /// in the tab meanwhile.
    public func queueInitialPromptAfterModelSelection(
        _ selection: ACPDelegatedModelSelection,
        record: ACPDelegationRecord,
        prompt: String,
        manager: ACPSessionManager
    ) async -> Bool {
        do {
            try await manager.applyDelegatedModelSelection(selection, to: record.childSessionId)
        } catch {
            // `markChildFailed` writes the queue without the prompt, which
            // recovery may have withheld in memory, before the failed phase
            // takes the child out of recovery.
            await markChildFailed(childSessionId: record.childSessionId, message: error.localizedDescription)
            return false
        }
        guard await manager.enqueueDelegatedPrompt(
            text: prompt,
            source: initialPromptSource(for: record),
            into: record.childSessionId,
            ahead: true
        ) else {
            await markChildFailed(childSessionId: record.childSessionId, message: "Could not queue initial prompt.")
            return false
        }
        return true
    }

    private func delegatedChildStartFailureMessage(_ session: ACPSession?) -> String {
        guard let session else { return "Could not start delegated ACP session." }
        switch session.setupState {
        case .needsSetup(let reason), .setupError(let reason):
            return reason
        case .needsAuth(_, let reason):
            return reason ?? "ACP session needs authentication."
        case .checking, .ready:
            break
        }
        if case .failed(let reason) = session.agentState {
            return reason
        }
        return "Could not start delegated ACP session."
    }

    /// True only when `child`'s parent is known not to exist: its worktree is
    /// loaded and its manager has no row for the session. An unknown or
    /// unloaded worktree is not proof, since real outcomes would be dropped.
    public func parentIsGone(of child: ACPDelegationRecord) async -> Bool {
        guard environment.sessionLocation(child.parentSessionId) == nil,
              let worktree = environment.worktree(child.parentWorktreeId),
              let manager = environment.manager(worktree)
        else { return false }
        do {
            return try await manager.storedSessionRow(id: child.parentSessionId) == nil
        } catch {
            // A failed read proves nothing, and the collector acts on "gone"
            // by dropping the outcome for good.
            Logger(subsystem: "io.nlopez.alas", category: "peer-outbox")
                .error("Could not tell whether parent \(child.parentSessionId, privacy: .public) exists: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func deliverPendingMessages(
        to sessionID: String,
        callerParent: ACPDelegationRecord? = nil,
        targetParent: ACPDelegationRecord? = nil,
        manager suppliedManager: ACPSessionManager? = nil
    ) async {
        // A paired Mac's sentinel, not a session: it collects from the outbox.
        guard ACPPeerParent.serverId(from: sessionID) == nil else { return }
        guard deliveringSessions.insert(sessionID).inserted else {
            deliveryRequested.insert(sessionID)
            return
        }
        defer {
            deliveringSessions.remove(sessionID)
            if deliveryRequested.remove(sessionID) != nil {
                Task { @MainActor in
                    await self.deliverPendingMessages(to: sessionID, callerParent: callerParent,
                        targetParent: targetParent, manager: suppliedManager)
                }
            }
        }
        // Hold an already-live queue before the first inbox read can suspend.
        // Its active turn may finish while the persistence actor is busy.
        let liveManager = suppliedManager ?? environment.sessionLocation(sessionID)?.manager
        let session = liveManager?.liveSession(for: sessionID)
        session?.nextPromptWorkCount += 1
        session?.pendingQueuePersistenceCount += 1
        defer {
            session?.nextPromptWorkCount -= 1
            session?.pendingQueuePersistenceCount -= 1
            liveManager?.runners[sessionID]?.flushQueueIfIdle()
        }
        // Read fresh: a caller's snapshot can predate the start transition.
        if ACPSessionOrchestrationPolicy.defersInboxDelivery(
            target: try? await environment.persistence.delegation(childSessionId: sessionID)
        ) { return }
        let manager: ACPSessionManager?
        if let suppliedManager {
            manager = suppliedManager
        } else {
            manager = await resolveDeliveryTarget(sessionID: sessionID, callerParent: callerParent,
                targetParent: targetParent)?.manager
        }
        guard let manager else { return }
        let targetSession = manager.liveSession(for: sessionID)
        // A restored target may have been hydrated by resolveDeliveryTarget.
        let holdsResolvedSession = targetSession !== session
        if holdsResolvedSession {
            targetSession?.nextPromptWorkCount += 1
            targetSession?.pendingQueuePersistenceCount += 1
        }
        defer {
            if holdsResolvedSession {
                targetSession?.nextPromptWorkCount -= 1
                targetSession?.pendingQueuePersistenceCount -= 1
                manager.runners[sessionID]?.flushQueueIfIdle()
            }
        }
        guard let initialMessages = try? await environment.persistence.pendingMessages(targetSessionId: sessionID) else { return }
        targetSession?.hasPendingDelegatedMessages = !initialMessages.isEmpty
        guard !initialMessages.isEmpty else { return }
        guard let children = try? await environment.persistence.children(parentSessionId: sessionID) else { return }
        var childrenByID = Dictionary(uniqueKeysWithValues: children.map { ($0.childSessionId, $0) })
        if initialMessages.contains(where: { $0.kind == .prompt && childrenByID[$0.sourceSessionId] != nil }) {
            await environment.waitForChildResultBatch()
        }
        guard !Task.isCancelled,
              let row = await manager.persistedSessionRow(id: sessionID), !row.archived
        else { return }
        await manager.attach(to: sessionID, freshlyCreated: false)
        guard manager.isWriter(for: sessionID) else {
            manager.notifyDelegatedMessagesAvailable()
            return
        }
        // A message is attempted only once per drain, even if deleting its
        // inbox row fails. New arrivals during persistence join the next pass.
        var attempted: Set<String> = []
        drain: while let pending = try? await environment.persistence.pendingMessages(targetSessionId: sessionID) {
            let messages = pending.filter { !attempted.contains($0.id) }
            guard !messages.isEmpty else { break }
            guard let currentChildren = try? await environment.persistence.children(parentSessionId: sessionID) else { break }
            childrenByID = Dictionary(uniqueKeysWithValues: currentChildren.map { ($0.childSessionId, $0) })
            var childResults: [ACPClaimedDelegatedMessage] = []
            for message in messages {
                attempted.insert(message.id)
                let isChildResult = message.kind == .prompt && childrenByID[message.sourceSessionId] != nil
                if !isChildResult {
                    // Accept earlier reports before a later informational notice.
                    // The queue hold still lets subsequent reports join this wake.
                    guard await deliverChildResults(childResults, childrenByID: childrenByID,
                        into: sessionID, manager: manager) else { break drain }
                    childResults.removeAll()
                }
                guard let claimed = try? await environment.persistence.claimMessage(
                    id: message.id, instanceId: environment.instanceId, token: environment.makeID(),
                    now: environment.now(), staleAfter: 60
                ) else { continue }
                if isChildResult {
                    childResults.append(claimed)
                } else {
                    await deliver(claimed, with: ACPDelegatedPromptSource(message: claimed.message,
                        senderDelegation: childrenByID[claimed.message.sourceSessionId]), to: manager)
                }
            }
            guard await deliverChildResults(childResults, childrenByID: childrenByID,
                into: sessionID, manager: manager) else { break }
        }
        if let remaining = try? await environment.persistence.pendingMessages(targetSessionId: sessionID) {
            targetSession?.hasPendingDelegatedMessages = !remaining.isEmpty
        }
    }

    private func deliverChildResults(
        _ results: [ACPClaimedDelegatedMessage],
        childrenByID: [String: ACPDelegationRecord],
        into sessionID: String,
        manager: ACPSessionManager
    ) async -> Bool {
        guard !results.isEmpty else { return true }
        let accepted = await manager.enqueueDelegatedPrompts(results.map { claimed in
            (claimed.message.prompt, ACPDelegatedPromptSource(message: claimed.message,
                senderDelegation: childrenByID[claimed.message.sourceSessionId]))
        }, into: sessionID, requiringWriter: true)
        for claimed in results { await finishDelivery(claimed, accepted: accepted) }
        return accepted
    }

    private func resolveDeliveryTarget(
        sessionID: String,
        callerParent: ACPDelegationRecord?,
        targetParent: ACPDelegationRecord?
    ) async -> SessionLocation? {
        if let target = environment.sessionLocation(sessionID) {
            guard let row = await target.manager.persistedSessionRow(id: sessionID), !row.archived else {
                return nil
            }
            return target
        }
        let worktreeID = targetParent?.childWorktreeId ?? callerParent?.parentWorktreeId
        guard let worktreeID,
              let worktree = environment.worktree(worktreeID),
              let manager = environment.manager(worktree),
              let row = await manager.persistedSessionRow(id: sessionID),
              !row.archived
        else { return nil }
        _ = manager.placeholderSession(id: sessionID)
        await manager.hydrateIfNeeded(id: sessionID)
        return .init(
            origin: ACPOrchestrationSessionOrigin(
                sessionId: sessionID,
                projectId: worktree.projectId,
                worktreeId: worktree.id
            ),
            manager: manager
        )
    }

    private func deliver(
        _ claimed: ACPClaimedDelegatedMessage,
        with source: ACPDelegatedPromptSource,
        to manager: ACPSessionManager
    ) async {
        let accepted: Bool
        switch claimed.message.kind {
        case .prompt:
            accepted = await manager.enqueueDelegatedPrompt(text: claimed.message.prompt,
                source: source, into: claimed.message.targetSessionId, requiringWriter: true)
        case .notice:
            accepted = await manager.appendDelegatedNotice(text: claimed.message.prompt,
                into: claimed.message.targetSessionId)
        }
        await finishDelivery(claimed, accepted: accepted)
    }

    private func finishDelivery(_ claimed: ACPClaimedDelegatedMessage, accepted: Bool) async {
        guard accepted else {
            try? await environment.persistence.releaseMessageClaim(id: claimed.message.id, claim: claimed.claim)
            return
        }
        try? await environment.persistence.removeDeliveredMessage(id: claimed.message.id, claim: claimed.claim)
        environment.notifyChanged()
    }

    private func sessionSummary(
        sessionId: String,
        relationship: String?,
        agentId: String,
        worktreeId: String,
        phase: ACPDelegationPhase,
        failure: String?,
        createdAt: Int64,
        role: String? = nil
    ) async -> ACPOrchestrationSessionSummary {
        let location = environment.sessionLocation(sessionId)
        let runtime = location?.manager.liveSession(for: sessionId).map(Self.runtimeState)
        let archived: Bool
        if location != nil {
            archived = false
        } else if let worktree = environment.worktree(worktreeId),
                  let manager = environment.manager(worktree),
                  let row = await manager.persistedSessionRow(id: sessionId) {
            archived = row.archived
        } else {
            archived = true
        }
        let state = ACPSessionOrchestrationPolicy.publicState(phase: phase, runtime: runtime, archived: archived)
        return .init(
            sessionId: sessionId,
            relationship: relationship,
            agentId: agentId,
            worktreeId: worktreeId,
            state: state.rawValue,
            failure: failure,
            createdAt: createdAt,
            role: role
        )
    }

    private static func runtimeState(_ session: ACPSession) -> ACPOrchestrationRuntimeState {
        ACPSessionOrchestrationPolicy.runtimeState(activity: session.activity)
    }

    private func json<T: Encodable>(_ value: T) -> AlasCLIResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let line = String(data: data, encoding: .utf8) else {
            return .error("Could not encode session response.")
        }
        return .text([line])
    }
}
