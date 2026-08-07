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

struct TrackedRevision: Codable, Equatable, Hashable, Sendable {
    let expression: String
    var baselineBranch: String
    var baselineHEAD: String
    var resolvedSHA: String
    var pendingCheckout: TrackedRevisionCandidate?

    private enum CodingKeys: String, CodingKey {
        case expression
        case baselineBranch
        case baselineHEAD
        case resolvedSHA
        case pendingCheckout
    }

    init?(expression: String, baselineBranch: String, baselineHEAD: String? = nil, resolvedSHA: String) {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return nil }

        self.expression = expression
        self.baselineBranch = baselineBranch
        self.baselineHEAD = baselineHEAD ?? resolvedSHA
        self.resolvedSHA = resolvedSHA
        self.pendingCheckout = nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let expression = try container.decode(String.self, forKey: .expression)
        let baselineBranch = try container.decode(String.self, forKey: .baselineBranch)
        let baselineHEAD = try container.decodeIfPresent(String.self, forKey: .baselineHEAD)
        let resolvedSHA = try container.decode(String.self, forKey: .resolvedSHA)
        guard var revision = Self(
            expression: expression,
            baselineBranch: baselineBranch,
            baselineHEAD: baselineHEAD,
            resolvedSHA: resolvedSHA
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expression,
                in: container,
                debugDescription: "Tracked revision expression must not be empty."
            )
        }
        revision.pendingCheckout = try container.decodeIfPresent(
            TrackedRevisionCandidate.self,
            forKey: .pendingCheckout
        )
        self = revision
    }

    var dependsOnWorktreeHEAD: Bool {
        Self.usesWorktreeHEADAlias(expression)
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
}

enum TrackedRevisionPolicy {
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

    static let live = TrackedRevisionResolver(
        resolve: { try await GitService().resolveRevision(at: $0, ref: $1) },
        branch: { try await GitService().currentBranch(worktreePath: $0) }
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
}

enum TrackedRevisionResolverError: LocalizedError, Equatable {
    case unsupportedReflogExpression(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedReflogExpression(let selector):
            if selector.lowercased() == "push" {
                "Followed revisions do not support @{push}; use an explicit remote-tracking ref instead."
            } else {
                "Time-relative reflog expressions like @{\(selector)} are not supported for followed revisions."
            }
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
    case failed(expression: String, resolvedSHA: String, message: String)

    init(fixedSHA: String, revision: TrackedRevision?, refreshError: String?) {
        guard let revision else {
            self = .fixed(sha: Self.shortSHA(fixedSHA))
            return
        }
        if let refreshError, !refreshError.isEmpty {
            self = .failed(
                expression: revision.expression,
                resolvedSHA: Self.shortSHA(revision.resolvedSHA),
                message: refreshError
            )
        } else if let pending = revision.pendingCheckout {
            self = .paused(
                expression: revision.expression,
                resolvedSHA: Self.shortSHA(revision.resolvedSHA),
                candidateSHA: Self.shortSHA(pending.sha),
                message: pending.branch.isEmpty
                    ? "Paused: detached HEAD moved"
                    : "Paused: HEAD moved to \(pending.branch)"
            )
        } else {
            self = .following(
                expression: revision.expression,
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
