import Foundation

struct TrackedRevisionCandidate: Codable, Equatable, Hashable, Sendable {
    let branch: String
    let sha: String
    let headSHA: String

    private enum CodingKeys: String, CodingKey {
        case branch
        case sha
        case headSHA
    }

    init(branch: String, sha: String, headSHA: String? = nil) {
        self.branch = branch
        self.sha = sha
        self.headSHA = headSHA ?? sha
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let branch = try container.decode(String.self, forKey: .branch)
        let sha = try container.decode(String.self, forKey: .sha)
        self.init(
            branch: branch,
            sha: sha,
            headSHA: try container.decodeIfPresent(String.self, forKey: .headSHA)
        )
    }
}

enum TrackedRevisionUnresolvedReason: String, Codable, Equatable, Hashable, Sendable {
    /// The GG-ID is not in the worktree's current stack: it landed, it was
    /// dropped, or a different stack is checked out.
    case stackEntryMissing
}

struct TrackedRevision: Codable, Equatable, Hashable, Sendable {
    let target: TrackedRevisionTarget
    var baselineBranch: String
    var baselineHEAD: String
    var resolvedSHA: String
    var pendingCheckout: TrackedRevisionCandidate?
    var unresolvedReason: TrackedRevisionUnresolvedReason?

    private enum CodingKeys: String, CodingKey {
        case target
        case expression
        case baselineBranch
        case baselineHEAD
        case resolvedSHA
        case pendingCheckout
        case unresolvedReason
    }

    init?(
        target: TrackedRevisionTarget,
        baselineBranch: String,
        baselineHEAD: String? = nil,
        resolvedSHA: String
    ) {
        guard let normalized = target.normalized() else { return nil }
        self.target = normalized
        self.baselineBranch = baselineBranch
        self.baselineHEAD = baselineHEAD ?? resolvedSHA
        self.resolvedSHA = resolvedSHA
        self.pendingCheckout = nil
        self.unresolvedReason = nil
    }

    init?(
        expression: String,
        baselineBranch: String,
        baselineHEAD: String? = nil,
        resolvedSHA: String
    ) {
        self.init(
            target: .expression(expression),
            baselineBranch: baselineBranch,
            baselineHEAD: baselineHEAD,
            resolvedSHA: resolvedSHA
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let target: TrackedRevisionTarget
        if let decoded = try container.decodeIfPresent(TrackedRevisionTarget.self, forKey: .target) {
            target = decoded
        } else {
            // Records written before targets existed carry a bare expression.
            target = .expression(try container.decode(String.self, forKey: .expression))
        }
        let baselineBranch = try container.decode(String.self, forKey: .baselineBranch)
        let baselineHEAD = try container.decodeIfPresent(String.self, forKey: .baselineHEAD)
        let resolvedSHA = try container.decode(String.self, forKey: .resolvedSHA)
        guard var revision = Self(
            target: target,
            baselineBranch: baselineBranch,
            baselineHEAD: baselineHEAD,
            resolvedSHA: resolvedSHA
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .target,
                in: container,
                debugDescription: "Tracked revision target must not be empty."
            )
        }
        revision.pendingCheckout = try container.decodeIfPresent(
            TrackedRevisionCandidate.self,
            forKey: .pendingCheckout
        )
        revision.unresolvedReason = try container.decodeIfPresent(
            TrackedRevisionUnresolvedReason.self,
            forKey: .unresolvedReason
        )
        self = revision
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        // Legacy mirror: a build that predates targets reads this key. A
        // stack entry degrades to a commit pinned at its last resolved SHA
        // rather than failing to decode the whole record.
        try container.encode(target.expressionValue ?? resolvedSHA, forKey: .expression)
        try container.encode(baselineBranch, forKey: .baselineBranch)
        try container.encode(baselineHEAD, forKey: .baselineHEAD)
        try container.encode(resolvedSHA, forKey: .resolvedSHA)
        try container.encodeIfPresent(pendingCheckout, forKey: .pendingCheckout)
        try container.encodeIfPresent(unresolvedReason, forKey: .unresolvedReason)
    }

    var dependsOnWorktreeHEAD: Bool {
        guard let expression = target.expressionValue else { return false }
        return Self.usesWorktreeHEADAlias(expression)
    }

    var unresolvedMessage: String? {
        switch unresolvedReason {
        case .none:
            return nil
        case .stackEntryMissing:
            return "Stack entry \(target.displayLabel) is not in the current stack."
        }
    }

    func stalled(reason: TrackedRevisionUnresolvedReason) -> Self {
        var revision = self
        revision.unresolvedReason = reason
        return revision
    }

    static func usesWorktreeHEADAlias(_ expression: String) -> Bool {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if expression == "HEAD" || expression == "@" { return true }
        if expression.hasPrefix("HEAD") {
            return isSupportedHEADSuffix(expression.dropFirst("HEAD".count))
        }
        if expression.hasPrefix("@") {
            return isSupportedHEADSuffix(expression.dropFirst("@".count))
        }
        return false
    }

    fileprivate static func isSupportedHEADSuffix(_ suffix: Substring) -> Bool {
        guard let first = suffix.first else { return false }
        return first == "~" || first == "^" || first == "{" || suffix.hasPrefix("@{")
    }

    func resolving(_ candidate: TrackedRevisionCandidate) -> Self {
        var revision = self
        revision.baselineBranch = candidate.branch
        revision.baselineHEAD = candidate.headSHA
        revision.resolvedSHA = candidate.sha
        revision.pendingCheckout = nil
        revision.unresolvedReason = nil
        return revision
    }

    func withPendingCheckout(_ candidate: TrackedRevisionCandidate) -> Self {
        var revision = self
        revision.pendingCheckout = candidate
        return revision
    }

    func acceptingPendingCheckout() -> Self? {
        guard let pendingCheckout else { return nil }
        return resolving(pendingCheckout)
    }

    func preparingPendingCheckoutAcceptance() -> Self? {
        guard let pendingCheckout else { return nil }
        var revision = self
        revision.baselineBranch = pendingCheckout.branch
        revision.baselineHEAD = pendingCheckout.headSHA
        revision.pendingCheckout = nil
        return revision
    }
}

enum TrackedRevisionTransition: Equatable {
    case unchanged(TrackedRevision)
    case follow(TrackedRevision)
    case pause(TrackedRevision)
    /// The target could not be resolved but the tab keeps its last commit
    /// instead of erroring or unfollowing.
    case stall(TrackedRevision)
}

enum TrackedRevisionPolicy {
    /// Maps a resolve failure to a transition. Only a stack entry that left
    /// the stack stalls; every other error stays on the caller's error path.
    static func evaluate(current: TrackedRevision, error: any Error) -> TrackedRevisionTransition? {
        guard let resolverError = error as? TrackedRevisionResolverError,
              case .stackEntryNotFound = resolverError
        else { return nil }
        return .stall(current.stalled(reason: .stackEntryMissing))
    }

    static func evaluate(
        current: TrackedRevision,
        candidate: TrackedRevisionCandidate
    ) -> TrackedRevisionTransition {
        guard candidate.sha != current.resolvedSHA else {
            return .unchanged(current.resolving(candidate))
        }

        guard current.dependsOnWorktreeHEAD else {
            return .follow(current.resolving(candidate))
        }

        if candidate.branch != current.baselineBranch {
            return .pause(current.withPendingCheckout(candidate))
        }

        if current.baselineBranch.isEmpty,
           candidate.branch.isEmpty,
           candidate.headSHA != current.baselineHEAD {
            return .pause(current.withPendingCheckout(candidate))
        }

        return .follow(current.resolving(candidate))
    }
}

struct TrackedRevisionResolver {
    var resolve: (URL, String) async throws -> String
    var branch: (URL) async throws -> String
    var stack: (URL) async throws -> GGStack? = { _ in nil }

    static let live = TrackedRevisionResolver(
        resolve: { try await GitService().resolveRevision(at: $0, ref: $1) },
        branch: { try await GitService().currentBranch(worktreePath: $0) },
        stack: { worktreePath in
            try await GGStackCache.shared.stack(at: worktreePath) {
                try await GGService().currentStack(worktreePath: worktreePath.path)
            }
        }
    )

    func resolve(at worktreePath: URL, expression: String) async throws -> TrackedRevisionCandidate {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selector = TrackedRevision.unsupportedReflogSelector(in: expression) {
            throw TrackedRevisionResolverError.unsupportedReflogExpression(selector)
        }
        let dependsOnWorktreeHEAD = TrackedRevision.usesWorktreeHEADAlias(expression)
        while true {
            let startingBranch = try await branch(worktreePath)
            let startingHEAD: String?
            do {
                startingHEAD = try await resolve(worktreePath, "HEAD")
            } catch {
                guard !dependsOnWorktreeHEAD else { throw error }
                startingHEAD = nil
            }
            let pinnedExpression: String
            if expression == "HEAD", let startingHEAD {
                pinnedExpression = startingHEAD
            } else if expression.hasPrefix("HEAD"),
                      let startingHEAD,
                      TrackedRevision.shouldPinHEADSuffix(expression.dropFirst("HEAD".count)) {
                pinnedExpression = startingHEAD + expression.dropFirst("HEAD".count)
            } else if expression == "@", let startingHEAD {
                pinnedExpression = startingHEAD
            } else if expression.hasPrefix("@"),
                      let startingHEAD,
                      TrackedRevision.shouldPinHEADSuffix(expression.dropFirst("@".count)) {
                pinnedExpression = startingHEAD + expression.dropFirst("@".count)
            } else {
                pinnedExpression = expression
            }
            let resolvedSHA = try await resolve(worktreePath, String(pinnedExpression))
            let endingBranch = try await branch(worktreePath)
            let endingHEAD: String?
            do {
                endingHEAD = try await resolve(worktreePath, "HEAD")
            } catch {
                guard !dependsOnWorktreeHEAD else { throw error }
                endingHEAD = nil
            }
            if startingBranch == endingBranch, startingHEAD == endingHEAD {
                return TrackedRevisionCandidate(branch: endingBranch, sha: resolvedSHA, headSHA: endingHEAD ?? "")
            }
            try Task.checkCancellation()
        }
    }

    func resolve(at worktreePath: URL, target: TrackedRevisionTarget) async throws -> TrackedRevisionCandidate {
        switch target {
        case .expression(let expression):
            return try await resolve(at: worktreePath, expression: expression)
        case .stackEntry(let ggID):
            return try await resolveStackEntry(at: worktreePath, ggID: ggID)
        }
    }

    private func resolveStackEntry(at worktreePath: URL, ggID: String) async throws -> TrackedRevisionCandidate {
        while true {
            let startingBranch = try await branch(worktreePath)
            let startingHEAD = try await resolve(worktreePath, "HEAD")
            guard let entry = try await stack(worktreePath)?
                .entries
                .first(where: { $0.ggId == ggID })
            else {
                throw TrackedRevisionResolverError.stackEntryNotFound(ggID)
            }
            // gg reports abbreviated SHAs; the rest of Alas carries full ones.
            let resolvedSHA = try await resolve(worktreePath, entry.sha)
            let endingBranch = try await branch(worktreePath)
            let endingHEAD = try await resolve(worktreePath, "HEAD")
            if startingBranch == endingBranch, startingHEAD == endingHEAD {
                return TrackedRevisionCandidate(
                    branch: endingBranch,
                    sha: resolvedSHA,
                    headSHA: endingHEAD
                )
            }
            try Task.checkCancellation()
        }
    }
}

enum TrackedRevisionResolverError: LocalizedError, Equatable {
    case unsupportedReflogExpression(String)
    case stackEntryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedReflogExpression(let selector):
            if selector.lowercased() == "push" {
                "Followed revisions do not support @{push}; use an explicit remote-tracking ref instead."
            } else {
                "Time-relative reflog expressions like @{\(selector)} are not supported for followed revisions."
            }
        case .stackEntryNotFound(let ggID):
            "Stack entry \(ggID) is not in the current stack."
        }
    }
}

private extension TrackedRevision {
    static func shouldPinHEADSuffix(_ suffix: Substring) -> Bool {
        guard let first = suffix.first else { return false }
        return first == "~" || first == "^"
    }

    static func unsupportedReflogSelector(in expression: String) -> String? {
        var searchStart = expression.startIndex
        while let openRange = expression.range(of: "@{", range: searchStart..<expression.endIndex) {
            guard let closeIndex = expression[openRange.upperBound...].firstIndex(of: "}") else {
                return nil
            }
            let selector = String(expression[openRange.upperBound..<closeIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !isStableReflogSelector(selector) {
                return selector
            }
            searchStart = expression.index(after: closeIndex)
        }
        return nil
    }

    static func isStableReflogSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty else { return false }
        let lowercased = selector.lowercased()
        if selector.allSatisfy(\.isNumber) { return true }
        if selector.first == "-", selector.dropFirst().allSatisfy(\.isNumber) {
            return true
        }
        return false
    }
}

struct TrackedRevisionRetargetingResult {
    let record: ReviewSessionRecord
    let oldRecordID: ReviewSessionID
    let oldDraftSessionID: ReviewDraftSessionID
    let newDraftSessionID: ReviewDraftSessionID
}

enum TrackedRevisionRetargeter {
    static func follow(
        record: ReviewSessionRecord,
        revision: TrackedRevision,
        title: String,
        now: Date
    ) -> TrackedRevisionRetargetingResult? {
        guard case .commit(let oldSHA) = record.target.payload else {
            guard case .trackedCommit(let oldRevision) = record.target.payload else { return nil }
            let oldDraftSessionID = record.target.draftSessionID
            let target = record.target.updatingTrackedRevision(revision, title: title)
            return TrackedRevisionRetargetingResult(
                record: record.retargetingCommit(
                    to: target,
                    resolvedSHAChanged: oldRevision.resolvedSHA != revision.resolvedSHA,
                    now: now
                ),
                oldRecordID: record.id,
                oldDraftSessionID: oldDraftSessionID,
                newDraftSessionID: target.draftSessionID
            )
        }
        let target = ReviewSessionTarget.trackedCommit(
            worktreeID: record.target.worktreeID,
            repositoryPath: record.target.repositoryPath,
            revision: revision,
            title: title
        )
        return TrackedRevisionRetargetingResult(
            record: record.retargetingCommit(
                to: target,
                resolvedSHAChanged: oldSHA != revision.resolvedSHA,
                now: now
            ),
            oldRecordID: record.id,
            oldDraftSessionID: record.target.draftSessionID,
            newDraftSessionID: target.draftSessionID
        )
    }

    static func stop(
        record: ReviewSessionRecord,
        title: String,
        now: Date
    ) -> TrackedRevisionRetargetingResult? {
        guard let target = record.target.freezingTrackedRevision(title: title) else { return nil }
        return TrackedRevisionRetargetingResult(
            record: record.retargetingCommit(to: target, resolvedSHAChanged: false, now: now),
            oldRecordID: record.id,
            oldDraftSessionID: record.target.draftSessionID,
            newDraftSessionID: target.draftSessionID
        )
    }
}

enum RevisionFollowPresentation: Equatable {
    case fixed(sha: String)
    case following(expression: String, resolvedSHA: String)
    case paused(expression: String, resolvedSHA: String, candidateSHA: String, message: String)
    /// The followed target could not be resolved (e.g. a stack entry left
    /// the stack), but the tab keeps its last commit instead of erroring.
    case stalled(expression: String, resolvedSHA: String, message: String)
    case failed(expression: String, resolvedSHA: String, message: String)

    init(fixedSHA: String, revision: TrackedRevision?, refreshError: String?) {
        guard let revision else {
            self = .fixed(sha: Self.shortSHA(fixedSHA))
            return
        }
        if let pending = revision.pendingCheckout {
            self = .paused(
                expression: revision.target.displayLabel,
                resolvedSHA: Self.shortSHA(revision.resolvedSHA),
                candidateSHA: Self.shortSHA(pending.sha),
                message: pending.branch.isEmpty
                    ? "Paused: detached HEAD moved"
                    : "Paused: HEAD moved to \(pending.branch)"
            )
        } else if let unresolvedMessage = revision.unresolvedMessage {
            self = .stalled(
                expression: revision.target.displayLabel,
                resolvedSHA: Self.shortSHA(revision.resolvedSHA),
                message: unresolvedMessage
            )
        } else if let refreshError, !refreshError.isEmpty {
            self = .failed(
                expression: revision.target.displayLabel,
                resolvedSHA: Self.shortSHA(revision.resolvedSHA),
                message: refreshError
            )
        } else {
            self = .following(
                expression: revision.target.displayLabel,
                resolvedSHA: Self.shortSHA(revision.resolvedSHA)
            )
        }
    }

    var pauseMessage: String? {
        guard case .paused(_, _, _, let message) = self else { return nil }
        return message
    }

    static func shouldPulse(previousSHA: String?, resolvedSHA: String, reduceMotion: Bool) -> Bool {
        guard !reduceMotion, let previousSHA else { return false }
        return previousSHA != resolvedSHA
    }

    private static func shortSHA(_ sha: String) -> String {
        String(sha.prefix(10))
    }
}

struct FollowRevisionEditorRequest: Equatable {
    let worktreeID: String
    let tabID: TabID
    var expression: String
    let isEditing: Bool
    var isSubmitting = false
    var errorMessage: String?

    var submissionExpression: String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func matches(worktreeID: String, tabID: TabID) -> Bool {
        self.worktreeID == worktreeID && self.tabID == tabID
    }
}
