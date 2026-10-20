import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// What `@` offers in a session's composer: the files, symbols and other
/// sessions of its project, for the app's composer and for Remote clients.
extension AlasCoreContext {
    /// Files, sessions and symbols of the session's project matching an `@`
    /// query, ranked as the local picker ranks them, and the session list
    /// they used, which a caller passes back while the query grows: a bare
    /// `@` lists sessions afresh, as the local picker does on open.
    @_spi(Testing) public func remoteMentionCandidates(
        sessionId: String, query: String, cachedSessions: [ACPSessionMentionCandidate]? = nil
    ) async -> (mentions: [RemoteMention], sessions: [ACPSessionMentionCandidate]) {
        guard case .found(let worktree) = remoteWorktreeContext(sessionId: sessionId) else { return ([], []) }
        let root = worktree.path
        // A bare `@` opens the picker: list files and sessions afresh then,
        // as the local picker does on open, and reuse both while the query
        // grows.
        let opening = query.trimmingCharacters(in: .whitespaces).isEmpty
        if opening {
            await environment.fileIndex.invalidate(forWorktreePath: root)
        }
        let isFolder = isFolderWorktree(worktree)
        var fileSymbols: [SymbolEntry] = []
        if case .file(let file, _) = MentionSymbolQuery.parse(query.trimmingCharacters(in: .whitespaces)) {
            fileSymbols = await ACPSymbolMentionSource.symbols(
                ofFileMatching: file, root: root, fileIndex: environment.fileIndex, isFolder: isFolder)
        }
        let paths = ((try? await environment.fileIndex.entries(forWorktreePath: root, isFolder: isFolder)) ?? []).map(\.relativePath)
        let sessions: [ACPSessionMentionCandidate]
        if !opening, let cachedSessions {
            sessions = cachedSessions
        } else {
            sessions = await acpSessionMentionCandidates(projectId: worktree.projectId, excluding: sessionId)
        }
        // An SSH worktree's files can't be checked without a round trip per
        // file; a missing one still fails safely, as a dangling link.
        let mentions = RemoteMentions.candidates(
            query: query, root: root, filePaths: paths, sessions: sessions, fileSymbols: fileSymbols,
            fileExists: { root.isRemoteAlasPath || FileManager.default.fileExists(atPath: $0.path) })
        return (mentions, sessions)
    }

    /// The prompt attachments for a viewer's mentions, or nil when any of
    /// them doesn't resolve inside the session's project.
    @_spi(Testing) public func remoteMentionAttachments(_ mentions: [RemoteMention], sessionId: String) async -> [ACPMessage.Attachment]? {
        guard !mentions.isEmpty else { return [] }
        guard case .found(let worktree) = remoteWorktreeContext(sessionId: sessionId) else { return nil }
        let root = worktree.path
        var attachments: [ACPMessage.Attachment] = []
        for mention in mentions {
            guard let attachment = await RemoteMentions.attachment(
                for: mention, worktreeRoot: root, sessionId: sessionId,
                isContainedFile: { path in
                    // Symlinks of an SSH worktree only resolve on its host,
                    // as for the remote file reads.
                    guard root.isRemoteAlasPath else {
                        return RemoteWorktreeFileAccess.resolve(path: path, in: root) != nil
                    }
                    guard let host = RemoteHostRegistry.shared.host(forPath: root.path) else { return false }
                    return (try? await RemotePathContainment.verifyRemoteContainment(
                        host: host, path: root.appendingPathComponent(path).path, worktreeRoot: root.path)) != nil
                },
                isProjectSession: { [weak self] id in
                    await self?.acpSessionMentionCandidate(sessionId: id)?.projectId == worktree.projectId
                })
            else { return nil }
            attachments.append(attachment)
        }
        return attachments
    }

    /// Sessions of `projectId` the composer can attach, most recent first.
    /// Covers every worktree of the project, including ones not opened in
    /// this run, whose stores are read on demand.
    public func acpSessionMentionCandidates(projectId: String, excluding sessionId: String?) async -> [ACPSessionMentionCandidate] {
        var candidates: [(candidate: ACPSessionMentionCandidate, updatedAt: Int64)] = []
        for (worktree, manager) in await acpProjectManagers(projectId: projectId, loadingRecentRows: true) {
            let recentIds = Set(manager.sessionRows.map(\.id))
            for entry in acpMentionableSessions(in: manager, worktree: worktree) where entry.candidate.id != sessionId {
                // A live session missing from the just-reloaded recent rows
                // may have been archived by another instance, which its
                // cached row cannot show: confirm it in the store.
                if !recentIds.contains(entry.candidate.id) {
                    guard let stored = try? await manager.persistence.loadSession(id: entry.candidate.id),
                          !stored.archived, stored.ephemeralParentId == nil
                    else { continue }
                }
                candidates.append(entry)
            }
        }
        return candidates.sorted { $0.updatedAt > $1.updatedAt }.map(\.candidate)
    }

    /// A manager for every worktree of `projectId`, created when the worktree
    /// was not opened in this run. With `loadingRecentRows`, every manager's
    /// recent rows are reloaded first, since another instance may have
    /// created or archived sessions since they were cached.
    @_spi(AppHost) public func acpProjectManagers(
        projectId: String, loadingRecentRows: Bool
    ) async -> [(worktree: Worktree, manager: ACPSessionManager)] {
        var result: [(worktree: Worktree, manager: ACPSessionManager)] = []
        for worktree in projects.worktrees(projectId: projectId) {
            // The environment may replace a loaded manager whose worktree
            // moved to another project; one busy with an operation stays.
            guard let manager = (try? environment.sessionManager(for: worktree, in: self))
                ?? sessionManagers[.worktree(worktree.id)]
            else { continue }
            if loadingRecentRows {
                // Queued local writes (an archive, a new session) land first,
                // so the reload cannot bring back an older row.
                await manager.flushPersistence()
                await manager.refreshRecentNow()
            }
            result.append((worktree, manager))
        }
        return result
    }

    /// The attachable session `sessionId`, confirmed in its store like the
    /// picker's candidates: a cached row cannot show another instance's
    /// archive.
    public func acpSessionMentionCandidate(sessionId: String) async -> ACPSessionMentionCandidate? {
        for (owner, manager) in sessionManagers {
            guard let worktreeId = owner.worktreeID, let worktree = listedWorktree(id: worktreeId),
                  let match = acpMentionableSessions(in: manager, worktree: worktree)
                    .first(where: { $0.candidate.id == sessionId })
            else { continue }
            await manager.flushPersistence()
            guard let stored = try? await manager.persistence.loadSession(id: sessionId),
                  !stored.archived, stored.ephemeralParentId == nil
            else { return nil }
            return match.candidate
        }
        return nil
    }

    /// `manager`'s non-archived, non-side-question sessions. Like the agent
    /// sidebar, this unions stored rows with live sessions: the rows are a
    /// lazily refreshed snapshot that can briefly miss a live session.
    private func acpMentionableSessions(
        in manager: ACPSessionManager, worktree: Worktree
    ) -> [(candidate: ACPSessionMentionCandidate, updatedAt: Int64)] {
        func candidate(id: String, agentId: String, title: String) -> ACPSessionMentionCandidate {
            ACPSessionMentionCandidate(
                id: id,
                projectId: worktree.projectId,
                title: title,
                agentName: environment.agent(id: agentId)?.displayName ?? agentId,
                worktreeName: worktree.name
            )
        }
        var result: [(candidate: ACPSessionMentionCandidate, updatedAt: Int64)] = []
        var seen = Set<String>()
        for row in manager.sessionRows {
            seen.insert(row.id)
            guard !row.archived, row.ephemeralParentId == nil else { continue }
            let title = manager.liveSession(for: row.id)?.title ?? row.title
            result.append((candidate(id: row.id, agentId: row.agentId, title: title), row.updatedAt))
        }
        for session in manager.sessions.values where !seen.contains(session.id) && !session.readOnlyRestricted {
            // A cached session can outlive its row's place among the recent
            // rows after being archived, e.g. by another instance.
            if let row = manager.cachedPersistedSessionRow(id: session.id),
               row.archived || row.ephemeralParentId != nil { continue }
            result.append((
                candidate(id: session.id, agentId: session.agentId, title: session.title),
                Int64(session.createdAt.timeIntervalSince1970)
            ))
        }
        return result
    }

    private func listedWorktree(id: String) -> Worktree? {
        for project in projects.projects {
            if let worktree = projects.worktrees(projectId: project.id).first(where: { $0.id == id }) { return worktree }
        }
        return nil
    }
}
