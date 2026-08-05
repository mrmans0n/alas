import Foundation

/// Entrypoint-neutral facade over the app capabilities the CLI (and, later, an
/// MCP bridge) drive. It speaks domain terms — worktrees, paths, targets — not
/// wire types, so multiple front ends can reuse it.
@MainActor
struct AlasActionService {
    struct FileIdentity: Equatable {
        let systemNumber: UInt64
        let fileNumber: UInt64
    }

    var visibleWorktrees: () -> [Worktree]
    var openRelativeFile: (String, String) -> Void
    var openExternalFile: (URL, String) -> Void
    var openRelativeFileAtLines: (String, String, ClosedRange<Int>) -> Void = { _, _, _ in }
    var openExternalFileAtLines: (URL, String, ClosedRange<Int>) -> Void = { _, _, _ in }
    var focusWorktree: (Worktree) -> Void = { _ in }
    var createWorktree: (Worktree, String, String?) async -> AlasCLIResponse = { _, _, _ in
        .error("Creating worktrees from the terminal is not available yet.")
    }
    var deleteWorktreeAction: (Worktree, Bool, Bool) async -> AlasCLIResponse = { _, _, _ in
        .error("Deleting worktrees from the terminal is not available yet.")
    }
    var openReviewChanges: (Worktree) -> Void = { _ in }
    var openReview: (Worktree, String) async -> AlasCLIResponse = { _, _ in
        .error("Opening provider reviews from the terminal is not available yet.")
    }
    var draftCommentStore: () -> ReviewDraftCommentStore = { ReviewDraftCommentStore() }
    var reviewSessionStore: () -> ReviewSessionStore = { ReviewSessionStore() }
    var notifyReviewCommentsChanged: () -> Void = {
        NotificationCenter.default.post(name: .alasReviewDraftCommentsDidChangeExternally, object: nil)
    }
    var now: () -> Date = Date.init
    var gitStatus: (URL) async throws -> [ChangedFile] = { try await GitService().status(worktreePath: $0) }
    var providerReviewOriginalPath: (ReviewDraftSessionID, String) async -> String? = { _, _ in nil }
    var notifySession: (String?, Worktree, String, String?, AlasCLINotifyLevel) -> AlasCLIResponse = { _, _, _, _, _ in
        .error("Notifications from the terminal are not available yet.")
    }
    var listDelegatedSessions: (ACPOrchestrationSessionOrigin) async -> AlasCLIResponse = { _ in
        .error("Session orchestration is not available yet.")
    }
    var createDelegatedSession: (ACPOrchestrationSessionOrigin, ACPDelegatedSessionNewRequest) async -> AlasCLIResponse = { _, _ in
        .error("Session orchestration is not available yet.")
    }
    var sendDelegatedSessionMessage: (ACPOrchestrationSessionOrigin, ACPDelegatedSessionMessageRequest) async -> AlasCLIResponse = { _, _ in
        .error("Session orchestration is not available yet.")
    }
    var activateApp: () -> Void

    /// Worktree owning `directory`: the worktree rooted exactly at
    /// `directory` itself, or else the worktree the directory sits inside of
    /// (most-specific match wins).
    ///
    /// The exact-root check runs first: a directory that is itself the root
    /// of a nested worktree (a worktree whose root lives inside a parent
    /// worktree's tree) must resolve to that nested worktree, not to the
    /// parent it happens to be a strictly-deeper descendant of.
    func resolveWorktree(forDirectory directory: String) -> Worktree? {
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        // `cwd` comes from the CLI's logical `$PWD`, which preserves symlinks,
        // so the directory may itself be a symlink to a worktree root. Resolve
        // symlinks on both sides before comparing file identities, otherwise a
        // command run from a symlinked checkout root reports "not inside an
        // Alas worktree".
        if let directoryIdentity = Self.fileIdentity(at: url.resolvingSymlinksInPath().path),
           let exactMatch = visibleWorktrees().first(where: { worktree in
               Self.fileIdentity(at: worktree.path.resolvingSymlinksInPath().path) == directoryIdentity
           }) {
            return exactMatch
        }
        return containingWorktree(for: url)?.worktree
    }

    func open(paths: [String], fallbackWorktreeId: String) -> AlasCLIResponse {
        open(paths: paths, fallbackWorktreeId: fallbackWorktreeId, lineRange: nil)
    }

    func openAt(path: String, line: Int, endLine: Int?, fallbackWorktreeId: String) -> AlasCLIResponse {
        let start = line - 1
        return open(
            paths: [path],
            fallbackWorktreeId: fallbackWorktreeId,
            lineRange: start ... ((endLine ?? line) - 1)
        )
    }

    private func open(
        paths: [String],
        fallbackWorktreeId: String,
        lineRange: ClosedRange<Int>?
    ) -> AlasCLIResponse {
        var errors: [String] = []
        var openedAny = false
        for rawPath in paths {
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard fileExists(at: url) else {
                errors.append("\(url.path) does not exist.")
                continue
            }
            guard !isDirectory(at: url) else {
                errors.append("\(url.path) is a directory.")
                continue
            }
            if let match = containingWorktree(for: url) {
                if let lineRange {
                    openRelativeFileAtLines(match.relativePath, match.worktree.id, lineRange)
                } else {
                    openRelativeFile(match.relativePath, match.worktree.id)
                }
            } else {
                if let lineRange {
                    openExternalFileAtLines(url, fallbackWorktreeId, lineRange)
                } else {
                    openExternalFile(url, fallbackWorktreeId)
                }
            }
            openedAny = true
        }
        if openedAny { activateApp() }
        return errors.isEmpty ? .ok : .error(errors.joined(separator: " "))
    }

    func list(origin: Worktree, projectWorktrees: [Worktree]) -> AlasCLIResponse {
        .text(AlasCLIWorktreeResolver.rows(worktrees: projectWorktrees, currentWorktreeId: origin.id))
    }

    func `switch`(target: String, projectWorktrees: [Worktree]) -> AlasCLIResponse {
        switch AlasCLIWorktreeResolver.resolve(target: target, worktrees: projectWorktrees) {
        case .matched(let worktree):
            focusWorktree(worktree)
            activateApp()
            return .ok
        case .missing(let target):
            return .error("unknown worktree \"\(target)\"")
        case .ambiguous(let labels):
            return .error("ambiguous worktree \"\(target)\"; matches: \(labels.joined(separator: ", "))")
        }
    }

    func notify(
        sessionId: String?,
        origin: Worktree,
        body: String,
        title: String?,
        level: AlasCLINotifyLevel
    ) -> AlasCLIResponse {
        notifySession(sessionId, origin, body, title, level)
    }

    func sessionList(origin: ACPOrchestrationSessionOrigin) async -> AlasCLIResponse {
        await listDelegatedSessions(origin)
    }

    func sessionNew(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionNewRequest
    ) async -> AlasCLIResponse {
        await createDelegatedSession(origin, request)
    }

    func sessionSend(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionMessageRequest
    ) async -> AlasCLIResponse {
        await sendDelegatedSessionMessage(origin, request)
    }

    func new(origin: Worktree, branch: String, base: String?) async -> AlasCLIResponse {
        await createWorktree(origin, branch, base)
    }

    func delete(target: String, projectWorktrees: [Worktree], force: Bool, keepBranch: Bool) async -> AlasCLIResponse {
        switch AlasCLIWorktreeResolver.resolve(target: target, worktrees: projectWorktrees) {
        case .matched(let worktree):
            return await deleteWorktreeAction(worktree, force, keepBranch)
        case .missing(let target):
            return .error("unknown worktree \"\(target)\"")
        case .ambiguous(let labels):
            return .error("ambiguous worktree \"\(target)\"; matches: \(labels.joined(separator: ", "))")
        }
    }

    func reviewLocal(origin: Worktree) -> AlasCLIResponse {
        openReviewChanges(origin)
        activateApp()
        let sessionID = ReviewDraftSessionID.localChanges(
            worktreeID: origin.id,
            worktreePath: origin.path,
            scope: .all
        )
        return .text([
            "Opened review of local changes in Alas.",
            Self.jsonLine(["session_id": sessionID.rawValue]),
        ])
    }

    func reviewTarget(origin: Worktree, target: String) async -> AlasCLIResponse {
        await openReview(origin, target)
    }

    /// Failure detail for `reviewOrigin`: a single message describing why the
    /// `--worktree` override couldn't be resolved.
    struct ReviewOriginResolutionError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The worktree a review command operates on: the explicit `--worktree`
    /// override when given (resolved against the origin's project), else the
    /// origin itself.
    func reviewOrigin(
        origin: Worktree,
        override: String?,
        projectWorktrees: [Worktree]
    ) -> Swift.Result<Worktree, ReviewOriginResolutionError> {
        guard let override else { return .success(origin) }
        switch AlasCLIWorktreeResolver.resolve(target: override, worktrees: projectWorktrees) {
        case .matched(let worktree):
            return .success(worktree)
        case .missing(let target):
            let available = projectWorktrees.map(\.branch).joined(separator: ", ")
            return .failure(ReviewOriginResolutionError(message: "unknown worktree \"\(target)\"; available: \(available)"))
        case .ambiguous(let labels):
            return .failure(ReviewOriginResolutionError(
                message: "ambiguous worktree \"\(override)\"; matches: \(labels.joined(separator: ", "))"
            ))
        }
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

    func reviewComments(
        origin: Worktree,
        sessionID: String?,
        filter: ReviewCommentWireFilter,
        projectWorktrees: [Worktree]
    ) -> AlasCLIResponse {
        let all: [ReviewDraftComment]
        do {
            all = try draftCommentStore().loadAll()
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
    static let cliAgentAuthor = ReviewDraftCommentAuthor.agent(name: "Agent")

    /// One deterministic JSON line for machine-readable CLI/MCP output.
    static func jsonLine(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    func reviewCommentAdd(
        origin: Worktree,
        path: String,
        startLine: Int,
        endLine: Int?,
        side: String?,
        body: String,
        sessionID: String?,
        projectWorktrees: [Worktree]
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
            originalPath = await providerReviewOriginalPath(targetSessionID, relativePath)
        } else {
            originalPath = nil
        }
        let timestamp = now()
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
            author: Self.cliAgentAuthor
        )
        do {
            try draftCommentStore().save(comment)
        } catch {
            return .error("could not save review comment: \(error.localizedDescription)")
        }
        notifyReviewCommentsChanged()
        return .text([
            "Filed review comment.",
            Self.jsonLine(["comment_id": comment.id]),
        ])
    }

    func reviewFinish(
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

        let sessions = reviewSessionStore()
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
                let timestamp = now()
                record = ReviewSessionRecord(
                    id: target.id,
                    target: target,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }
            try sessions.save(record.markedReviewed(verdict: verdict, summary: summary, now: now()))
        } catch {
            return .error("could not finish review: \(error.localizedDescription)")
        }
        notifyReviewCommentsChanged()
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
    static func worktreeRelativePath(_ path: String, worktreeRoot: URL) -> String? {
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
        guard let rootIdentity = fileIdentity(at: worktreeRoot.path) else { return nil }
        var ancestor = url.deletingLastPathComponent()
        var relativeComponents = [url.lastPathComponent]
        while ancestor.path != "/" {
            if fileIdentity(at: ancestor.path) == rootIdentity {
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

    func reviewReply(
        origin: Worktree,
        commentID: String,
        body: String,
        projectWorktrees: [Worktree]
    ) -> AlasCLIResponse {
        let store = draftCommentStore()
        do {
            guard var comment = try store.find(commentID: commentID),
                  Self.resolveSessionWorktree(for: comment.sessionID, origin: origin, projectWorktrees: projectWorktrees) != nil else {
                return .error("unknown review comment id \"\(commentID)\"")
            }
            let timestamp = now()
            var replies = comment.allReplies
            replies.append(ReviewCommentReply(
                id: UUID().uuidString,
                author: Self.cliAgentAuthor,
                bodyMarkdown: body,
                createdAt: timestamp
            ))
            comment.replies = replies
            comment.updatedAt = timestamp
            try store.save(comment)
        } catch {
            return .error("could not update review comment: \(error.localizedDescription)")
        }
        notifyReviewCommentsChanged()
        return .ok
    }

    func reviewResolve(
        origin: Worktree,
        commentID: String,
        reply: String?,
        reopen: Bool,
        projectWorktrees: [Worktree]
    ) -> AlasCLIResponse {
        let store = draftCommentStore()
        do {
            guard var comment = try store.find(commentID: commentID),
                  let commentWorktree = Self.resolveSessionWorktree(for: comment.sessionID, origin: origin, projectWorktrees: projectWorktrees) else {
                return .error("unknown review comment id \"\(commentID)\"")
            }
            let timestamp = now()
            if let reply {
                var replies = comment.allReplies
                replies.append(ReviewCommentReply(
                    id: UUID().uuidString,
                    author: Self.cliAgentAuthor,
                    bodyMarkdown: reply,
                    createdAt: timestamp
                ))
                comment.replies = replies
            }
            comment.state = reopen ? .active : .resolved
            comment.resolvedBy = reopen ? nil : Self.cliAgentAuthor
            comment.updatedAt = timestamp
            try store.save(comment)
            // Best-effort: the comment mutation above already succeeded and
            // must not be retried, so a failure recomputing handoff/session
            // status (a separate store) is swallowed rather than reported
            // as an overall failure a caller would retry.
            try? ReviewHandoffProgress.recomputeAndPersist(
                worktreeID: commentWorktree.id,
                sessionStore: reviewSessionStore(),
                isResolved: { id in (try? store.find(commentID: id))?.state == .resolved },
                now: timestamp
            )
        } catch {
            return .error("could not update review comment: \(error.localizedDescription)")
        }
        notifyReviewCommentsChanged()
        return .ok
    }

    // MARK: - Worktree matching (moved verbatim from AlasCLICommandRouter)

    private func containingWorktree(for url: URL) -> (worktree: Worktree, relativePath: String)? {
        var bestMatch: (worktree: Worktree, relativePath: String, rootComponentCount: Int)?
        for worktree in visibleWorktrees() {
            let rootURL = worktree.path.standardizedFileURL
            guard let match = Self.relativePathAndDepth(for: url, in: rootURL) else { continue }
            if let currentBest = bestMatch,
               match.rootComponentCount <= currentBest.rootComponentCount {
                continue
            }
            bestMatch = (worktree, match.relativePath, match.rootComponentCount)
        }
        guard let bestMatch else { return nil }
        return (bestMatch.worktree, bestMatch.relativePath)
    }

    /// Widened from `private` to `nonisolated static` so `AlasCLIWorktreeResolver`
    /// (a stateless enum with no `AlasActionService` instance to call
    /// `visibleWorktrees()` on) can reuse the same containing-worktree lookup
    /// logic against its own `worktrees: [Worktree]` parameter.
    nonisolated static func relativePathAndDepth(for url: URL, in rootURL: URL) -> (relativePath: String, rootComponentCount: Int)? {
        if let match = relativePathAndDepth(
            targetComponents: url.standardizedFileURL.pathComponents,
            rootComponents: rootURL.pathComponents
        ) {
            return match
        }

        return relativePathAndDepth(
            targetComponents: url.resolvingSymlinksInPath().standardizedFileURL.pathComponents,
            rootComponents: rootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        ) ?? fileSystemRelativePathAndDepth(for: url, in: rootURL)
    }

    nonisolated static func relativePathAndDepth(
        targetComponents: [String],
        rootComponents: [String]
    ) -> (relativePath: String, rootComponentCount: Int)? {
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        let relative = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        return (relative, rootComponents.count)
    }

    private nonisolated static func fileSystemRelativePathAndDepth(for url: URL, in rootURL: URL) -> (relativePath: String, rootComponentCount: Int)? {
        guard let rootIdentity = Self.fileIdentity(at: rootURL.path) else { return nil }
        var ancestor = url.deletingLastPathComponent()
        var relativeComponents = [url.lastPathComponent]

        while ancestor.path != "/" {
            if Self.fileIdentity(at: ancestor.path) == rootIdentity {
                return (relativeComponents.reversed().joined(separator: "/"), rootURL.pathComponents.count)
            }
            relativeComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated static func fileIdentity(at path: String) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return FileIdentity(systemNumber: systemNumber.uint64Value, fileNumber: fileNumber.uint64Value)
    }

    private func fileExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    }

    private func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }
}
