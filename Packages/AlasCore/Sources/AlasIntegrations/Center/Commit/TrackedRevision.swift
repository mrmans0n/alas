import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public enum TrackedRevisionTransition: Equatable, Sendable {
    case unchanged(TrackedRevision)
    case follow(TrackedRevision)
    case pause(TrackedRevision)
    /// The target could not be resolved but the tab keeps its last commit
    /// instead of erroring or unfollowing.
    case stall(TrackedRevision)
}

public enum TrackedRevisionPolicy: Sendable {
    /// Maps a resolve failure to a transition. Only a stack entry that left
    /// the stack stalls; every other error stays on the caller's error path.
    public static func evaluate(current: TrackedRevision, error: any Error) -> TrackedRevisionTransition? {
        guard let resolverError = error as? TrackedRevisionResolverError,
              case .stackEntryNotFound = resolverError
        else { return nil }
        return .stall(current.stalled(reason: .stackEntryMissing))
    }

    public static func evaluate(
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

public struct TrackedRevisionResolver: Sendable {
    public var resolve: @Sendable (URL, String) async throws -> String
    public var branch: @Sendable (URL) async throws -> String
    public var stack: @Sendable (URL) async throws -> GGStack? = { _ in nil }

    public static let live = TrackedRevisionResolver(
        resolve: { try await GitService().resolveRevision(at: $0, ref: $1) },
        branch: { try await GitService().currentBranch(worktreePath: $0) },
        stack: { worktreePath in
            try await GGStackCache.shared.stack(at: worktreePath) {
                try await GGService().currentStack(worktreePath: worktreePath.path)
            }
        }
    )

    public func resolve(at worktreePath: URL, expression: String) async throws -> TrackedRevisionCandidate {
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

    public func resolve(at worktreePath: URL, target: TrackedRevisionTarget) async throws -> TrackedRevisionCandidate {
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

    public init(resolve: @escaping @Sendable (URL, String) async throws -> String, branch: @escaping @Sendable (URL) async throws -> String, stack: @escaping @Sendable (URL) async throws -> GGStack? = { _ in nil }) {
        self.resolve = resolve
        self.branch = branch
        self.stack = stack
    }
}

public enum TrackedRevisionResolverError: LocalizedError, Equatable, Sendable {
    case unsupportedReflogExpression(String)
    case stackEntryNotFound(String)

    public var errorDescription: String? {
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
        if selector.allSatisfy(\.isNumber) { return true }
        if selector.first == "-", selector.dropFirst().allSatisfy(\.isNumber) {
            return true
        }
        return false
    }
}

public struct TrackedRevisionRetargetingResult: Sendable {
    public let record: ReviewSessionRecord
    public let oldRecordID: ReviewSessionID
    public let oldDraftSessionID: ReviewDraftSessionID
    public let newDraftSessionID: ReviewDraftSessionID

    public init(record: ReviewSessionRecord, oldRecordID: ReviewSessionID, oldDraftSessionID: ReviewDraftSessionID, newDraftSessionID: ReviewDraftSessionID) {
        self.record = record
        self.oldRecordID = oldRecordID
        self.oldDraftSessionID = oldDraftSessionID
        self.newDraftSessionID = newDraftSessionID
    }
}

public enum TrackedRevisionRetargeter: Sendable {
    public static func follow(
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

    public static func stop(
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

public enum RevisionFollowPresentation: Equatable, Sendable {
    case fixed(sha: String)
    case following(expression: String, resolvedSHA: String)
    case paused(expression: String, resolvedSHA: String, candidateSHA: String, message: String)
    /// The followed target could not be resolved (e.g. a stack entry left
    /// the stack), but the tab keeps its last commit instead of erroring.
    case stalled(expression: String, resolvedSHA: String, message: String)
    case failed(expression: String, resolvedSHA: String, message: String)

    public init(fixedSHA: String, revision: TrackedRevision?, refreshError: String?) {
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

    public var pauseMessage: String? {
        guard case .paused(_, _, _, let message) = self else { return nil }
        return message
    }

    public static func shouldPulse(previousSHA: String?, resolvedSHA: String, reduceMotion: Bool) -> Bool {
        guard !reduceMotion, let previousSHA else { return false }
        return previousSHA != resolvedSHA
    }

    private static func shortSHA(_ sha: String) -> String {
        String(sha.prefix(10))
    }
}

public struct FollowRevisionEditorRequest: Equatable, Sendable {
    public let worktreeID: String
    public let tabID: TabID
    public var expression: String
    public let isEditing: Bool
    public var isSubmitting = false
    public var errorMessage: String?

    public var submissionExpression: String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func matches(worktreeID: String, tabID: TabID) -> Bool {
        self.worktreeID == worktreeID && self.tabID == tabID
    }

    public init(worktreeID: String, tabID: TabID, expression: String, isEditing: Bool, isSubmitting: Bool = false, errorMessage: String? = nil) {
        self.worktreeID = worktreeID
        self.tabID = tabID
        self.expression = expression
        self.isEditing = isEditing
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
    }
}
