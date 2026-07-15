import Foundation

/// Entrypoint-neutral facade over the app capabilities the CLI (and, later, an
/// MCP bridge) drive. It speaks domain terms — worktrees, paths, targets — not
/// wire types, so multiple front ends can reuse it.
@MainActor
struct AlasActionService {
    private struct FileIdentity: Equatable {
        let systemNumber: UInt64
        let fileNumber: UInt64
    }

    var visibleWorktrees: () -> [Worktree]
    var openRelativeFile: (String, String) -> Void
    var openExternalFile: (URL, String) -> Void
    var focusWorktree: (Worktree) -> Void = { _ in }
    var createWorktree: (Worktree, String, String?) async -> AlasCLIResponse = { _, _, _ in
        .error("Creating worktrees from the terminal is not available yet.")
    }
    var deleteWorktreeAction: (Worktree, Bool, Bool) async -> AlasCLIResponse = { _, _, _ in
        .error("Deleting worktrees from the terminal is not available yet.")
    }
    var openReviewChanges: (Worktree) -> Void = { _ in }
    var openProviderReview: (Worktree, String) async -> AlasCLIResponse = { _, _ in
        .error("Opening provider reviews from the terminal is not available yet.")
    }
    var draftCommentStore: () -> ReviewDraftCommentStore = { ReviewDraftCommentStore() }
    var reviewSessionStore: () -> ReviewSessionStore = { ReviewSessionStore() }
    var notifyReviewCommentsChanged: () -> Void = {
        NotificationCenter.default.post(name: .alasReviewDraftCommentsDidChangeExternally, object: nil)
    }
    var now: () -> Date = Date.init
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
        if let directoryIdentity = fileIdentity(at: url.resolvingSymlinksInPath().path),
           let exactMatch = visibleWorktrees().first(where: { worktree in
               fileIdentity(at: worktree.path.resolvingSymlinksInPath().path) == directoryIdentity
           }) {
            return exactMatch
        }
        return containingWorktree(for: url)?.worktree
    }

    func open(paths: [String], fallbackWorktreeId: String) -> AlasCLIResponse {
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
                openRelativeFile(match.relativePath, match.worktree.id)
            } else {
                openExternalFile(url, fallbackWorktreeId)
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
        return .ok
    }

    func reviewProvider(origin: Worktree, target: String) async -> AlasCLIResponse {
        await openProviderReview(origin, target)
    }

    func reviewComments(origin: Worktree, sessionID: String?, filter: ReviewCommentWireFilter) -> AlasCLIResponse {
        let all: [ReviewDraftComment]
        do {
            all = try draftCommentStore().loadAll()
        } catch {
            return .error("could not read review comments: \(error.localizedDescription)")
        }
        let scoped = all.filter { comment in
            if let sessionID {
                return comment.sessionID.rawValue == sessionID
            }
            return comment.sessionID.isFor(worktreeID: origin.id)
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

    func reviewReply(origin: Worktree, commentID: String, body: String) -> AlasCLIResponse {
        let store = draftCommentStore()
        do {
            guard var comment = try store.find(commentID: commentID),
                  comment.sessionID.isFor(worktreeID: origin.id) else {
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

    func reviewResolve(origin: Worktree, commentID: String, reply: String?, reopen: Bool) -> AlasCLIResponse {
        let store = draftCommentStore()
        do {
            guard var comment = try store.find(commentID: commentID),
                  comment.sessionID.isFor(worktreeID: origin.id) else {
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
            if !reopen {
                try markAddressedHandoffs(worktreeID: origin.id, store: store, timestamp: timestamp)
            }
        } catch {
            return .error("could not update review comment: \(error.localizedDescription)")
        }
        notifyReviewCommentsChanged()
        return .ok
    }

    private func markAddressedHandoffs(worktreeID: String, store: ReviewDraftCommentStore, timestamp: Date) throws {
        let sessions = reviewSessionStore()
        for record in try sessions.list(worktreeID: worktreeID) {
            guard let updated = ReviewHandoffProgress.recomputingAddressed(
                record: record,
                isResolved: { id in (try? store.find(commentID: id))?.state == .resolved },
                now: timestamp
            ) else { continue }
            try sessions.save(updated)
        }
    }

    // MARK: - Worktree matching (moved verbatim from AlasCLICommandRouter)

    private func containingWorktree(for url: URL) -> (worktree: Worktree, relativePath: String)? {
        var bestMatch: (worktree: Worktree, relativePath: String, rootComponentCount: Int)?
        for worktree in visibleWorktrees() {
            let rootURL = worktree.path.standardizedFileURL
            guard let match = relativePathAndDepth(for: url, in: rootURL) else { continue }
            if let currentBest = bestMatch,
               match.rootComponentCount <= currentBest.rootComponentCount {
                continue
            }
            bestMatch = (worktree, match.relativePath, match.rootComponentCount)
        }
        guard let bestMatch else { return nil }
        return (bestMatch.worktree, bestMatch.relativePath)
    }

    private func relativePathAndDepth(for url: URL, in rootURL: URL) -> (relativePath: String, rootComponentCount: Int)? {
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

    private func relativePathAndDepth(
        targetComponents: [String],
        rootComponents: [String]
    ) -> (relativePath: String, rootComponentCount: Int)? {
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        let relative = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        return (relative, rootComponents.count)
    }

    private func fileSystemRelativePathAndDepth(for url: URL, in rootURL: URL) -> (relativePath: String, rootComponentCount: Int)? {
        guard let rootIdentity = fileIdentity(at: rootURL.path) else { return nil }
        var ancestor = url.deletingLastPathComponent()
        var relativeComponents = [url.lastPathComponent]

        while ancestor.path != "/" {
            if fileIdentity(at: ancestor.path) == rootIdentity {
                return (relativeComponents.reversed().joined(separator: "/"), rootURL.pathComponents.count)
            }
            relativeComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return nil
    }

    private func fileIdentity(at path: String) -> FileIdentity? {
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
