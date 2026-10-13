import Foundation
@testable import AlasCore

/// Builders shared by the shepherd suites. Values go through the real
/// initializers so the fixtures break loudly when a model changes.
enum ShepherdFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let earlier = now.addingTimeInterval(-600)
    static let head = "a3f9c1e5b2d4f6a8c0e2"
    static let newHead = "b7c2d90e11aa33cc55ee"
    static let failing = check("unit-tests", .fail)
    static let pending = check("lint", .pending)
    static let trustedThread = thread("PRRT_1")

    static func remote(_ kind: CodeHostKind = .github) -> CodeHostRemote {
        switch kind {
        case .github:
            CodeHostRemote(kind: .github, host: "github.com", owner: "acme", repository: "app",
                           remoteName: "origin", webURL: URL(string: "https://github.com/acme/app")!)
        case .gitlab:
            CodeHostRemote(kind: .gitlab, host: "gitlab.com", owner: "acme", repository: "app",
                           remoteName: "origin", webURL: URL(string: "https://gitlab.com/acme/app")!)
        }
    }

    static func check(_ id: String, _ bucket: ReviewCheckBucket) -> ReviewCheck {
        ReviewCheck(id: id, name: id, workflow: "CI", bucket: bucket,
                    detailURL: URL(string: "https://ci.example/\(id)"), completedAt: nil)
    }

    static func comment(
        _ id: String, author: String, body: String, trust: ReviewAuthorTrust, viewer: Bool = false
    ) -> ReviewComment {
        ReviewComment(id: id, author: author, body: body, url: nil, createdAt: nil,
                      viewerCanUpdate: viewer, viewerCanDelete: viewer, isPending: false,
                      authorTrust: trust, viewerDidAuthor: viewer)
    }

    static func thread(
        _ id: String,
        trust: ReviewAuthorTrust = .trusted,
        comments: [ReviewComment]? = nil
    ) -> ReviewThread {
        ReviewThread(
            id: id, path: "Sources/App.swift", line: 12, startLine: nil, originalLine: nil,
            diffHunk: nil, isResolved: false, isOutdated: false, isFileLevel: false,
            comments: comments ?? [comment("\(id)-c1", author: "maintainer", body: "Please fix \(id).", trust: trust)],
            viewerCanResolve: true, viewerCanReply: true,
            url: URL(string: "https://github.com/acme/app/pull/7#\(id)")
        )
    }

    static func request(
        kind: CodeHostKind = .github,
        state: ReviewRequestState = .open,
        head: String? = ShepherdFixtures.head,
        mergeState: ReviewMergeState = .clean,
        checks: [ReviewCheck] = [ShepherdFixtures.check("build", .pass)],
        threads: [ReviewThread] = [],
        threadsComplete: Bool = true,
        isMergeQueueEnabled: Bool = false,
        isInMergeQueue: Bool = false
    ) -> ReviewRequest {
        let host = remote(kind)
        return ReviewRequest(
            remote: host, number: 7, title: "Fix login", url: host.reviewRequestURL(number: 7),
            state: state, isDraft: false, headRefName: "fix-login", baseRefName: "main",
            headSHA: head, reviewDecision: .approved, mergeState: mergeState,
            checks: checks, threads: threads, areThreadsComplete: threadsComplete,
            isMergeQueueEnabled: isMergeQueueEnabled, isInMergeQueue: isInMergeQueue
        )
    }

    static func snapshot(
        _ request: ReviewRequest?,
        localHead: String = ShepherdFixtures.head,
        dirty: Bool = false
    ) -> ReviewLoopSnapshot {
        let local = ReviewLoopLocalState(
            branchName: "fix-login", headSHA: localHead, baseBranch: "main",
            hasWorkingTreeChanges: dirty, hasStagedChanges: false, aheadCommitCount: 1,
            hasUpstream: true, upstreamRemoteName: "origin", upstreamBranchName: "fix-login",
            needsPush: false
        )
        return ReviewLoopSnapshot(
            local: local, remote: request?.remote ?? remote(), reviewRequest: request,
            providerAvailable: true, providerAuthenticated: true,
            providerCapabilities: .githubCLI, errorMessage: nil
        )
    }

    static func record(
        kind: CodeHostKind = .github,
        phase: ShepherdPhase = .watching,
        autoFix: Bool = true,
        autoMerge: Bool = false,
        fixAttempts: Int = 0,
        lastDispatched: ShepherdFingerprint? = nil,
        viewerCommentIDs: [String]? = nil,
        handled: [String]? = nil,
        lastSeenHead: String? = nil,
        stablePolls: Int = 0,
        notifiedReady: String? = nil
    ) -> ShepherdRecord {
        let host = remote(kind)
        var record = ShepherdRecord(
            id: ShepherdRecordID(worktreeID: "wt-1", providerKind: kind, host: host.host,
                                 repositorySlug: host.repositorySlug, requestNumber: 7),
            sessionID: "session-1", remote: host, branch: "fix-login", baseBranch: "main",
            autoFix: autoFix, autoMerge: autoMerge, now: earlier
        )
        record.phase = phase
        record.fixAttempts = fixAttempts
        record.lastDispatchedFingerprint = lastDispatched
        record.viewerCommentIDsAtDispatch = viewerCommentIDs
        record.handledThreadRevisions = handled
        record.lastSeenHeadSHA = lastSeenHead
        record.stableHeadPolls = stablePolls
        record.notifiedReadyHeadSHA = notifiedReady
        return record
    }

    static func observation(
        _ snapshot: ReviewLoopSnapshot,
        session: ShepherdSessionState = .idle,
        rules: ShepherdRules = .none,
        headReviewers: Set<String>? = nil
    ) -> ShepherdObservation {
        ShepherdObservation(snapshot: snapshot, headReviewers: headReviewers,
                            session: session, rules: rules, now: now)
    }

    static func fingerprint(_ fix: ShepherdFixRequest, head: String = ShepherdFixtures.head) -> ShepherdFingerprint {
        fix.fingerprint(headSHA: head)
    }
}
