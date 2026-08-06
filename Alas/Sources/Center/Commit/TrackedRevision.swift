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
        while true {
            let startingBranch = try await branch(worktreePath)
            let startingHEAD = try await resolve(worktreePath, "HEAD")
            let pinnedExpression: String
            if expression == "HEAD" {
                pinnedExpression = startingHEAD
            } else if expression.hasPrefix("HEAD"),
                      TrackedRevision.shouldPinHEADSuffix(expression.dropFirst("HEAD".count)) {
                pinnedExpression = startingHEAD + expression.dropFirst("HEAD".count)
            } else if expression == "@" {
                pinnedExpression = startingHEAD
            } else if expression.hasPrefix("@"),
                      TrackedRevision.shouldPinHEADSuffix(expression.dropFirst("@".count)) {
                pinnedExpression = startingHEAD + expression.dropFirst("@".count)
            } else {
                pinnedExpression = expression
            }
            let resolvedSHA = try await resolve(worktreePath, String(pinnedExpression))
            let endingBranch = try await branch(worktreePath)
            let endingHEAD = try await resolve(worktreePath, "HEAD")
            if startingBranch == endingBranch, startingHEAD == endingHEAD {
                return TrackedRevisionCandidate(branch: endingBranch, sha: resolvedSHA, headSHA: endingHEAD)
            }
            try Task.checkCancellation()
        }
    }
}

private extension TrackedRevision {
    static func shouldPinHEADSuffix(_ suffix: Substring) -> Bool {
        guard let first = suffix.first else { return false }
        return first == "~" || first == "^"
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
