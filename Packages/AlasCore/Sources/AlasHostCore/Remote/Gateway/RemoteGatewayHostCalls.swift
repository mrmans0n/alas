import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasAgentKit
import AlasSessions

/// What a gateway asks of the host besides session verbs: the lists it
/// serves and the sessions it creates. `host(_:caller:)` asks the host; tests
/// substitute calls they can hold back to pin ordering.
@_spi(Testing) public struct RemoteGatewayHostCalls {
    /// The session list, given where the app shows each session's tab.
    public var sessionSummaries: @MainActor (_ tabIndex: @MainActor (_ sessionID: String, _ owner: SessionOwnerID) -> Int?) async
        -> [RemoteSessionSummary]
    public var worktrees: @MainActor () async -> [RemoteWorktreeOption]
    public var projects: @MainActor () async -> [RemoteProjectOption]
    public var branches: @MainActor (_ projectID: String) async -> RemoteBranchListResult
    public var agents: @MainActor () -> [RemoteAgentOption]
    public var createSession: @MainActor (_ request: RemoteSessionCreation, _ caller: HostCaller) async -> RemoteCreateSessionResult
    public var createWorktreeSession: @MainActor (_ request: RemoteWorktreeSessionCreation, _ caller: HostCaller) async -> RemoteCreateWorktreeSessionResult
    /// Reads of a session's worktree: changes, diffs, files and commits.
    public var inspection: any RemoteWorktreeInspecting
    /// What `@` offers for a query, given the sessions the last search listed.
    public var mentionCandidates: @MainActor (_ sessionID: String, _ query: String, _ cachedSessions: [ACPSessionMentionCandidate]?) async
        -> (mentions: [RemoteMention], sessions: [ACPSessionMentionCandidate])
    /// The prompt attachments for a client's mentions, or nil when one does
    /// not resolve inside the session's project.
    public var mentionAttachments: @MainActor (_ mentions: [RemoteMention], _ sessionID: String) async -> [ACPMessage.Attachment]?
    /// A tool call's full output, which a loaded transcript keeps only for
    /// its newest messages.
    public var fullToolCallContent: @MainActor (_ sessionID: String, _ toolCallID: String) async -> String?

    public init(
        sessionSummaries: @escaping @MainActor (_ tabIndex: @MainActor (_ sessionID: String, _ owner: SessionOwnerID) -> Int?) async
            -> [RemoteSessionSummary] = { _ in [] },
        worktrees: @escaping @MainActor () async -> [RemoteWorktreeOption],
        projects: @escaping @MainActor () async -> [RemoteProjectOption],
        branches: @escaping @MainActor (_ projectID: String) async -> RemoteBranchListResult,
        agents: @escaping @MainActor () -> [RemoteAgentOption],
        createSession: @escaping @MainActor (_ request: RemoteSessionCreation, _ caller: HostCaller) async -> RemoteCreateSessionResult = { _, _ in
            .failure("Could not create session.")
        },
        createWorktreeSession: @escaping @MainActor (_ request: RemoteWorktreeSessionCreation, _ caller: HostCaller) async -> RemoteCreateWorktreeSessionResult = { _, _ in
            .failure(stage: .worktree, message: "Could not create worktree.", worktreeId: nil)
        },
        inspection: any RemoteWorktreeInspecting,
        mentionCandidates: @escaping @MainActor (_ sessionID: String, _ query: String, _ cachedSessions: [ACPSessionMentionCandidate]?) async
            -> (mentions: [RemoteMention], sessions: [ACPSessionMentionCandidate]) = { _, _, _ in ([], []) },
        mentionAttachments: @escaping @MainActor (_ mentions: [RemoteMention], _ sessionID: String) async -> [ACPMessage.Attachment]? = { mentions, _ in
            mentions.isEmpty ? [] : nil
        },
        fullToolCallContent: @escaping @MainActor (_ sessionID: String, _ toolCallID: String) async -> String? = { _, _ in nil }
    ) {
        self.sessionSummaries = sessionSummaries
        self.worktrees = worktrees
        self.projects = projects
        self.branches = branches
        self.agents = agents
        self.createSession = createSession
        self.createWorktreeSession = createWorktreeSession
        self.inspection = inspection
        self.mentionCandidates = mentionCandidates
        self.mentionAttachments = mentionAttachments
        self.fullToolCallContent = fullToolCallContent
    }

    /// The host's lists and creations; empty and refused without a host.
    @MainActor public static func host(_ host: AlasHost?) -> RemoteGatewayHostCalls {
        guard let host else {
            return RemoteGatewayHostCalls(
                worktrees: { [] }, projects: { [] },
                branches: { _ in .failure("Repository is no longer available.") }, agents: { [] },
                inspection: NoRemoteWorktreeInspection()
            )
        }
        let core = host.core
        return RemoteGatewayHostCalls(
            sessionSummaries: { [weak core] tabIndex in await core?.remoteSessionSummaries(tabIndex: tabIndex) ?? [] },
            worktrees: { [weak core] in await core?.remoteWorktreeOptions() ?? [] },
            projects: { [weak core] in core?.remoteProjectOptions() ?? [] },
            branches: { [weak core] projectID in
                await core?.remoteBranches(projectID: projectID) ?? .failure("Repository is no longer available.")
            },
            agents: { [weak core] in core?.remoteAgentOptions() ?? [] },
            createSession: { [weak host] request, caller in
                await host?.remoteCreateSession(request, caller: caller) ?? .failure("Could not create session.")
            },
            createWorktreeSession: { [weak host] request, caller in
                await host?.remoteCreateWorktreeSession(request, caller: caller)
                    ?? .failure(stage: .worktree, message: "Could not create worktree.", worktreeId: nil)
            },
            inspection: core,
            mentionCandidates: { [weak core] sessionID, query, cached in
                await core?.remoteMentionCandidates(sessionId: sessionID, query: query, cachedSessions: cached) ?? ([], [])
            },
            mentionAttachments: { [weak core] mentions, sessionID in
                await core?.remoteMentionAttachments(mentions, sessionId: sessionID) ?? (mentions.isEmpty ? [] : nil)
            },
            fullToolCallContent: { [weak host] sessionID, toolCallID in
                await host?.sessions.fullToolCallContent(sessionID, toolCallID: toolCallID)
            }
        )
    }
}

/// Reads of a session's worktree a Remote client asks for. The core reads
/// them; tests substitute reads they can hold back.
@_spi(Testing) @MainActor
public protocol RemoteWorktreeInspecting: AnyObject {
    func remoteChangeList(sessionId: String, comparisonMode: AppConfig.Changes.ChangesComparisonMode?) async -> RemoteChangeListResult
    func remoteFileDiff(
        sessionId: String, path: String, stage: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) async -> RemoteFileDiffResult
    func remoteFileTree(sessionId: String, path: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?) async -> RemoteFileTreeResult
    func remoteCommitFiles(sessionId: String, sha: String) async -> RemoteCommitFilesResult
    func remoteCommitDiff(sessionId: String, sha: String, path: String) async -> RemoteFileDiffResult
    func remoteFileContents(sessionId: String, path: String) async -> RemoteFileContentsResult
}

@_spi(Testing) extension AlasCoreContext: RemoteWorktreeInspecting {}

/// Without a host there is no session to read.
@_spi(Testing) @MainActor
public final class NoRemoteWorktreeInspection: RemoteWorktreeInspecting {
    public init() {}

    public func remoteChangeList(sessionId: String, comparisonMode: AppConfig.Changes.ChangesComparisonMode?) async -> RemoteChangeListResult {
        .failure(reason: .sessionUnknown, message: nil)
    }
    public func remoteFileDiff(
        sessionId: String, path: String, stage: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) async -> RemoteFileDiffResult {
        .failure(reason: .sessionUnknown, message: nil)
    }
    public func remoteFileTree(sessionId: String, path: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?) async -> RemoteFileTreeResult {
        .failure(reason: .sessionUnknown, message: nil)
    }
    public func remoteCommitFiles(sessionId: String, sha: String) async -> RemoteCommitFilesResult {
        .failure(reason: .sessionUnknown, message: nil)
    }
    public func remoteCommitDiff(sessionId: String, sha: String, path: String) async -> RemoteFileDiffResult {
        .failure(reason: .sessionUnknown, message: nil)
    }
    public func remoteFileContents(sessionId: String, path: String) async -> RemoteFileContentsResult {
        .failure(reason: .sessionUnknown, byteSize: nil, message: nil)
    }
}
