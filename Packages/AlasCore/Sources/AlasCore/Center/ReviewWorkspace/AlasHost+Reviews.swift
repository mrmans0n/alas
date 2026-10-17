import Foundation

extension AlasHost {
    /// Review comments on a worktree's changes, as agents file and answer
    /// them from the CLI.
    public var reviews: ReviewsAPI { ReviewsAPI(core: core) }
}

extension AlasCoreContext {
    /// The review status of `worktree`, created on first use with
    /// `baseBranch` as the branch its review targets.
    // ponytail: kept until the host stops; drop a worktree's entry when it is removed if memory matters.
    public func reviewLoop(for worktree: Worktree, baseBranch: String) -> ReviewLoopState {
        defer { reviewLoopConfiguredBases[worktree.id] = baseBranch }
        if let existing = reviewLoops[worktree.id] {
            // A new configured base replaces the loop's, a pick in the pane
            // included, as the pane resets its own on a settings change.
            if reviewLoopConfiguredBases[worktree.id] != baseBranch { existing.updateBaseBranch(baseBranch) }
            return existing
        }
        let loop = ReviewLoopState(worktreePath: worktree.path, baseBranch: baseBranch)
        reviewLoops[worktree.id] = loop
        return loop
    }

    /// Tells every view showing review comments that they changed.
    public func reviewCommentsDidChange() {
        reviewCommentChanges.send()
        NotificationCenter.default.post(name: .alasReviewDraftCommentsDidChangeExternally, object: nil)
    }
}

/// Every verb acts for `origin`, the worktree the caller works in, and
/// `projectWorktrees`, its project's listed worktrees: a session id may
/// name a review of a sibling worktree, but not one of another project.
@MainActor
public struct ReviewsAPI {
    let core: AlasCoreContext

    /// The pull request and checks last seen for worktree `worktreeID`; nil
    /// until something has loaded them.
    public func status(of worktreeID: String) -> ReviewLoopSnapshot? {
        core.reviewLoops[worktreeID]?.snapshot
    }

    private func gitStatus(_ worktreePath: URL) async throws -> [ChangedFile] {
        if let hook = core.reviewGitStatus { return try await hook(worktreePath) }
        return try await GitService().status(worktreePath: worktreePath)
    }

    private func reviewReplyAdded(_ worktree: Worktree, _ comment: ReviewDraftComment, _ reply: ReviewCommentReply) {
        core.environment.reviewReplyAdded(reply, to: comment, in: worktree)
    }

    /// The worktree a review session id actually targets: `origin` itself
    /// when the session is scoped to it, else searched across the caller's
    /// whole project (not just `origin`) — a `--worktree` override can open
    /// a review session scoped to a sibling worktree. `origin` is checked
    /// directly first because it can be a worktree the user has hidden,
    /// which `projectWorktrees` (built from `visibleWorktrees()`) excludes;
    /// without this, a plain, no-override review session opened and used
    /// from a hidden worktree would fail to resolve even though no sibling
    /// worktree is involved at all. Returns nil when neither `origin` nor
    /// any worktree in the project matches, which callers treat the same as
    /// an unknown/foreign session.
    private static func resolveSessionWorktree(
        for sessionID: ReviewDraftSessionID,
        origin: Worktree,
        projectWorktrees: [Worktree]
    ) -> Worktree? {
        if sessionID.isFor(worktreeID: origin.id) { return origin }
        return projectWorktrees.first { sessionID.isFor(worktreeID: $0.id) }
    }

    public func comments(
        origin: Worktree,
        sessionID: String?,
        filter: ReviewCommentWireFilter,
        projectWorktrees: [Worktree]
    ) -> AlasCLIResponse {
        let all: [ReviewDraftComment]
        do {
            all = try core.reviewDrafts.loadAll()
        } catch {
            return .error("could not read review comments: \(error.localizedDescription)")
        }
        let scoped: [ReviewDraftComment]
        if let sessionID {
            // A session id resolving to any worktree in the caller's project
            // (not just `origin`) is in-project and its comments can be
            // listed outright; a session that doesn't resolve at all is
            // foreign and falls back to the origin-only scoping below, which
            // naturally yields nothing for it.
            if let parsed = ReviewDraftSessionID(rawValue: sessionID),
               Self.resolveSessionWorktree(for: parsed, origin: origin, projectWorktrees: projectWorktrees) != nil {
                scoped = all.filter { $0.sessionID.rawValue == sessionID }
            } else {
                scoped = all.filter { $0.sessionID.isFor(worktreeID: origin.id) && $0.sessionID.rawValue == sessionID }
            }
        } else {
            scoped = all.filter { $0.sessionID.isFor(worktreeID: origin.id) }
        }
        let filtered = scoped.filter { comment in
            switch filter {
            case .all: return true
            case .active: return comment.state == .active
            case .resolved: return comment.state == .resolved
            case .dismissed: return comment.state == .dismissed
            }
        }
        return .text([ReviewCommentWireDTO.jsonLine(filtered.map(ReviewCommentWireDTO.init))])
    }

    /// The author identity CLI/MCP mutations write. Phase 2+ can thread a
    /// real agent name through the wire; the enum already supports it.
    public static let cliAgentAuthor = ReviewDraftCommentAuthor.agent(name: "Agent")

    /// One deterministic JSON line for machine-readable CLI/MCP output.
    public static func jsonLine(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public func addComment(
        origin: Worktree,
        path: String,
        startLine: Int,
        endLine: Int?,
        side: String?,
        body: String,
        sessionID: String?,
        projectWorktrees: [Worktree],
        author: ReviewDraftCommentAuthor = ReviewsAPI.cliAgentAuthor
    ) async -> AlasCLIResponse {
        let targetSessionID: ReviewDraftSessionID
        let worktreeForPath: Worktree
        if let sessionID {
            guard let parsed = ReviewDraftSessionID(rawValue: sessionID),
                  let resolved = Self.resolveSessionWorktree(for: parsed, origin: origin, projectWorktrees: projectWorktrees) else {
                return .error("unknown review session id")
            }
            targetSessionID = parsed
            worktreeForPath = resolved
        } else {
            targetSessionID = .localChanges(worktreeID: origin.id, worktreePath: origin.path, scope: .all)
            worktreeForPath = origin
        }
        // The CLI always absolutizes `path` against the calling terminal's
        // own cwd (`origin`), never against `worktreeForPath` — so when a
        // `--worktree` override put the session on a sibling worktree, a
        // perfectly ordinary relative path the user typed arrives here as an
        // absolute path rooted in `origin`, not the sibling. Falling back to
        // relativizing against `origin` recovers that original relative form
        // whenever the primary attempt (against the session's own worktree)
        // fails and an override is actually in play; the recovered string is
        // already worktree-agnostic, so no further resolution is needed.
        guard let relativePath = Self.worktreeRelativePath(path, worktreeRoot: worktreeForPath.path)
            ?? (worktreeForPath.id != origin.id
                ? Self.worktreeRelativePath(path, worktreeRoot: origin.path)
                : nil),
              !relativePath.isEmpty else {
            return .error("review comment path must point at a file inside the worktree")
        }
        let namespace: String
        switch await fileIDNamespace(for: targetSessionID, path: relativePath, worktreePath: worktreeForPath.path) {
        case .resolved(let resolved):
            namespace = resolved
        case .failed(let message):
            return .error(message)
        }
        // Only GitLab publishing consumes `originalPath` (`oldPath` for a
        // renamed file); GitHub's review-comment API keys off the post-rename
        // path only. Resolving it loads the provider diff, so gating to
        // GitLab keeps `review_comment_add` on a GitHub PR from waiting on an
        // unnecessary `gh pr diff` fetch that would publish identically.
        let originalPath: String?
        if targetSessionID.sourceKind == .reviewRequest,
           targetSessionID.reviewRequestProvider == .gitlab {
            originalPath = await core.environment.providerReviewOriginalPath(targetSessionID, path: relativePath)
        } else {
            originalPath = nil
        }
        let timestamp = Date()
        let comment = ReviewDraftComment(
            id: UUID().uuidString,
            sessionID: targetSessionID,
            fileID: DiffReviewFileID(namespace: namespace, path: relativePath),
            path: relativePath,
            originalPath: originalPath,
            side: side == "old" ? .old : .new,
            startLine: startLine,
            endLine: endLine,
            selectedText: nil,
            bodyMarkdown: body,
            state: .active,
            createdAt: timestamp,
            updatedAt: timestamp,
            author: author
        )
        do {
            try core.reviewDrafts.save(comment)
        } catch {
            return .error("could not save review comment: \(error.localizedDescription)")
        }
        core.reviewCommentsDidChange()
        return .text([
            "Filed review comment.",
            Self.jsonLine(["comment_id": comment.id]),
        ])
    }

    public func finish(
        origin: Worktree,
        sessionID: String?,
        verdict: ReviewVerdict,
        summary: String,
        projectWorktrees: [Worktree]
    ) -> AlasCLIResponse {
        // The worktree the finished session actually lives in — `origin`
        // when there's no explicit session (or it's the origin's own), else
        // the sibling worktree a `--worktree` override opened the session
        // against.
        let sessionWorktree: Worktree
        let draftSessionID: ReviewDraftSessionID
        if let sessionID {
            guard let parsed = ReviewDraftSessionID(rawValue: sessionID),
                  let resolved = Self.resolveSessionWorktree(for: parsed, origin: origin, projectWorktrees: projectWorktrees) else {
                return .error("unknown review session id")
            }
            draftSessionID = parsed
            sessionWorktree = resolved
        } else {
            sessionWorktree = origin
            draftSessionID = ReviewDraftSessionID.localChanges(
                worktreeID: origin.id,
                worktreePath: origin.path,
                scope: .all
            )
        }
        let defaultSessionID = ReviewDraftSessionID.localChanges(
            worktreeID: sessionWorktree.id,
            worktreePath: sessionWorktree.path,
            scope: .all
        )
        guard verdict != .requestChanges
            || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("request_changes requires a non-empty summary")
        }

        let sessions = core.reviewSessions
        do {
            let record: ReviewSessionRecord
            if let existing = try sessions.list(worktreeID: sessionWorktree.id).first(where: {
                $0.target.draftSessionID == draftSessionID
            }) {
                record = existing
            } else {
                // `review` opens local changes in the dedicated changes tab,
                // which does not create a ReviewSessionRecord. Materialize its
                // canonical session only when finishing that default review.
                guard draftSessionID == defaultSessionID else {
                    return .error("unknown review session id")
                }
                let target = ReviewSessionTarget.localChanges(
                    worktreeID: sessionWorktree.id,
                    repositoryPath: sessionWorktree.path,
                    scope: .all
                )
                let timestamp = Date()
                record = ReviewSessionRecord(
                    id: target.id,
                    target: target,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }
            try sessions.save(record.markedReviewed(verdict: verdict, summary: summary, now: Date()))
        } catch {
            return .error("could not finish review: \(error.localizedDescription)")
        }
        core.reviewCommentsDidChange()
        return .ok
    }

    /// Worktree-relative form of `path`: absolute paths under the worktree
    /// root are relativized; already-relative paths are lexically
    /// normalized (collapsing `.`/`..`/repeated separators) and treated as
    /// already worktree-relative — MCP callers may send `./Sources/App.swift`
    /// or `Sources/../Sources/App.swift`, and an unnormalized form would
    /// miss the exact-match `gitStatus`/`DiffReviewFileID` lookups downstream.
    /// Absolute paths try the path as given first, then with symlinks
    /// resolved on both sides — the CLI absolutizes against the caller's
    /// logical `$PWD`, which preserves a symlinked checkout path, while
    /// `worktreeRoot` may be the resolved real path Alas tracks (same
    /// two-step pattern `relativePathAndDepth` already uses for `open`).
    /// Returns nil when an absolute path is outside the worktree root even
    /// after symlink resolution and a file-identity walk-up, so callers
    /// don't file a comment against a path that can never match a file in
    /// the review.
    public static func worktreeRelativePath(_ path: String, worktreeRoot: URL) -> String? {
        guard path.hasPrefix("/") else { return normalizedRelativePath(path) }
        if let relative = relativePath(path, against: worktreeRoot.standardizedFileURL.path) {
            return relative
        }
        let resolvedRoot = worktreeRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if let relative = relativePath(resolvedPath, against: resolvedRoot) {
            return relative
        }
        // Falls back to comparing filesystem identity (inode + device)
        // instead of path strings — the default case-insensitive-but-
        // case-preserving macOS volume can give the CLI's cwd and the
        // tracked worktree root different casing for the same directory,
        // which a string prefix check would reject as "outside the
        // worktree" even though it's the identical file. Mirrors the
        // `open` command's `fileSystemRelativePathAndDepth` fallback.
        return fileSystemRelativePath(URL(fileURLWithPath: path), worktreeRoot: worktreeRoot)
    }

    private static func fileSystemRelativePath(_ url: URL, worktreeRoot: URL) -> String? {
        guard let rootIdentity = WorktreePaths.fileIdentity(at: worktreeRoot.path) else { return nil }
        var ancestor = url.deletingLastPathComponent()
        var relativeComponents = [url.lastPathComponent]
        while ancestor.path != "/" {
            if WorktreePaths.fileIdentity(at: ancestor.path) == rootIdentity {
                return relativeComponents.reversed().joined(separator: "/")
            }
            relativeComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return nil
    }

    /// Collapses `.`/`..`/repeated separators in a relative path purely
    /// lexically (no filesystem access, no process cwd involved). A leading
    /// `..` that would climb above the path's own root is dropped rather
    /// than followed, since this path is already meant to be worktree-root
    /// relative.
    private static func normalizedRelativePath(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(String(component))
        }
        return components.joined(separator: "/")
    }

    private static func relativePath(_ path: String, against rootPath: String) -> String? {
        if path == rootPath { return "" }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return nil
    }

    /// The `DiffReviewFileID` namespace matching how each review surface
    /// loads files for a session, so an agent-filed comment lands in the
    /// same file bucket the UI reads from instead of becoming an orphan
    /// (`DiffReviewSurface` matches on the exact namespace+path). Every
    /// session kind except `.localChanges` carries enough in its own
    /// `sourceKind` (and, for `.reviewRequest`, its encoded provider) to
    /// resolve without touching the filesystem; local changes need a live
    /// git-status lookup because the same path can be staged and unstaged
    /// at once (partial staging) — unstaged wins when both are present,
    /// since it reflects the more current working-tree state.
    private enum FileIDNamespaceResolution {
        case resolved(String)
        case failed(String)
    }

    private func fileIDNamespace(
        for sessionID: ReviewDraftSessionID,
        path: String,
        worktreePath: URL
    ) async -> FileIDNamespaceResolution {
        switch sessionID.sourceKind {
        case .commit, .trackedCommit:
            return .resolved("commit")
        case .commitRange, .branch:
            return .resolved("range")
        case .draftCommit:
            return .resolved(ChangeStage.staged.rawValue)
        case .draftReviewRequest:
            return .resolved("draft-review-request")
        case .reviewRequest:
            switch sessionID.reviewRequestProvider {
            case .github: return .resolved("github-pr")
            case .gitlab: return .resolved("gitlab-mr")
            case nil: return .failed("could not resolve the code host for that review session")
            }
        case .localChanges:
            do {
                let files = try await gitStatus(worktreePath)
                let stages = Set(files.filter { $0.path == path }.map(\.stage))
                switch sessionID.localChangesScope {
                case .staged:
                    guard stages.contains(.staged) else {
                        return .failed("no staged changes found for \"\(path)\"")
                    }
                    return .resolved(ChangeStage.staged.rawValue)
                case .unstaged:
                    guard stages.contains(.unstaged) else {
                        return .failed("no unstaged changes found for \"\(path)\"")
                    }
                    return .resolved(ChangeStage.unstaged.rawValue)
                case .all, nil:
                    if stages.contains(.unstaged) {
                        return .resolved(ChangeStage.unstaged.rawValue)
                    }
                    if stages.contains(.staged) {
                        return .resolved(ChangeStage.staged.rawValue)
                    }
                    return .failed("no local changes found for \"\(path)\"")
                }
            } catch {
                return .failed("could not read git status: \(error.localizedDescription)")
            }
        }
    }

    public func reply(
        origin: Worktree,
        commentID: String,
        body: String,
        projectWorktrees: [Worktree]
    ) -> AlasCLIResponse {
        let store = core.reviewDrafts
        do {
            guard var comment = try store.find(commentID: commentID),
                  let commentWorktree = Self.resolveSessionWorktree(for: comment.sessionID, origin: origin, projectWorktrees: projectWorktrees) else {
                return .error("unknown review comment id \"\(commentID)\"")
            }
            let timestamp = Date()
            var replies = comment.allReplies
            let reply = ReviewCommentReply(
                id: UUID().uuidString,
                author: Self.cliAgentAuthor,
                bodyMarkdown: body,
                createdAt: timestamp
            )
            replies.append(reply)
            comment.replies = replies
            comment.updatedAt = timestamp
            try store.save(comment)
            reviewReplyAdded(commentWorktree, comment, reply)
        } catch {
            return .error("could not update review comment: \(error.localizedDescription)")
        }
        core.reviewCommentsDidChange()
        return .ok
    }

    public func resolve(
        origin: Worktree,
        commentID: String,
        reply: String?,
        reopen: Bool,
        projectWorktrees: [Worktree]
    ) -> AlasCLIResponse {
        let store = core.reviewDrafts
        do {
            guard var comment = try store.find(commentID: commentID),
                  let commentWorktree = Self.resolveSessionWorktree(for: comment.sessionID, origin: origin, projectWorktrees: projectWorktrees) else {
                return .error("unknown review comment id \"\(commentID)\"")
            }
            let timestamp = Date()
            var appendedReply: ReviewCommentReply?
            if let reply {
                var replies = comment.allReplies
                let entry = ReviewCommentReply(
                    id: UUID().uuidString,
                    author: Self.cliAgentAuthor,
                    bodyMarkdown: reply,
                    createdAt: timestamp
                )
                replies.append(entry)
                appendedReply = entry
                comment.replies = replies
            }
            comment.state = reopen ? .active : .resolved
            comment.resolvedBy = reopen ? nil : Self.cliAgentAuthor
            comment.updatedAt = timestamp
            try store.save(comment)
            if let appendedReply {
                reviewReplyAdded(commentWorktree, comment, appendedReply)
            }
            // Best-effort: the comment mutation above already succeeded and
            // must not be retried, so a failure recomputing handoff/session
            // status (a separate store) is swallowed rather than reported
            // as an overall failure a caller would retry.
            try? ReviewHandoffProgress.recomputeAndPersist(
                worktreeID: commentWorktree.id,
                sessionStore: core.reviewSessions,
                isResolved: { id in (try? store.find(commentID: id))?.state == .resolved },
                now: timestamp
            )
        } catch {
            return .error("could not update review comment: \(error.localizedDescription)")
        }
        core.reviewCommentsDidChange()
        return .ok
    }
}
