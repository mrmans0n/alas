import Foundation
import AlasFoundation

public struct TrackedRevision: Codable, Equatable, Hashable, Sendable {
    public let target: TrackedRevisionTarget
    public var baselineBranch: String
    public var baselineHEAD: String
    public var resolvedSHA: String
    public var pendingCheckout: TrackedRevisionCandidate?
    public var unresolvedReason: TrackedRevisionUnresolvedReason?

    private enum CodingKeys: String, CodingKey {
        case target
        case expression
        case baselineBranch
        case baselineHEAD
        case resolvedSHA
        case pendingCheckout
        case unresolvedReason
    }

    public init?(
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

    public init?(
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

    public init(from decoder: any Decoder) throws {
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

    public func encode(to encoder: any Encoder) throws {
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

    public var dependsOnWorktreeHEAD: Bool {
        guard let expression = target.expressionValue else { return false }
        return Self.usesWorktreeHEADAlias(expression)
    }

    public var unresolvedMessage: String? {
        switch unresolvedReason {
        case .none:
            return nil
        case .stackEntryMissing:
            return "Stack entry \(target.displayLabel) is not in the current stack."
        }
    }

    public func stalled(reason: TrackedRevisionUnresolvedReason) -> Self {
        var revision = self
        revision.unresolvedReason = reason
        return revision
    }

    public static func usesWorktreeHEADAlias(_ expression: String) -> Bool {
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

    public func resolving(_ candidate: TrackedRevisionCandidate) -> Self {
        var revision = self
        revision.baselineBranch = candidate.branch
        revision.baselineHEAD = candidate.headSHA
        revision.resolvedSHA = candidate.sha
        revision.pendingCheckout = nil
        revision.unresolvedReason = nil
        return revision
    }

    public func withPendingCheckout(_ candidate: TrackedRevisionCandidate) -> Self {
        var revision = self
        revision.pendingCheckout = candidate
        return revision
    }

    public func acceptingPendingCheckout() -> Self? {
        guard let pendingCheckout else { return nil }
        return resolving(pendingCheckout)
    }

    public func preparingPendingCheckoutAcceptance() -> Self? {
        guard let pendingCheckout else { return nil }
        var revision = self
        revision.baselineBranch = pendingCheckout.branch
        revision.baselineHEAD = pendingCheckout.headSHA
        revision.pendingCheckout = nil
        return revision
    }
}

public struct TrackedRevisionCandidate: Codable, Equatable, Hashable, Sendable {
    public let branch: String
    public let sha: String
    public let headSHA: String

    private enum CodingKeys: String, CodingKey {
        case branch
        case sha
        case headSHA
    }

    public init(branch: String, sha: String, headSHA: String? = nil) {
        self.branch = branch
        self.sha = sha
        self.headSHA = headSHA ?? sha
    }

    public init(from decoder: any Decoder) throws {
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

public enum TrackedRevisionUnresolvedReason: String, Codable, Equatable, Hashable, Sendable {
    /// The GG-ID is not in the worktree's current stack: it landed, it was
    /// dropped, or a different stack is checked out.
    case stackEntryMissing
}

/// What a followed tab is tracking. `.expression` is a git revision
/// expression re-resolved on each refresh; `.stackEntry` is a gg `GG-ID`
/// trailer, which survives the rebases and reorders that shift `HEAD~n`.
public enum TrackedRevisionTarget: Equatable, Hashable, Sendable {
    case expression(String)
    case stackEntry(ggID: String)

    /// Stable key for persisted identity — review-session IDs, review-draft
    /// IDs, and commit-tab IDs are derived from it. For `.expression` it must
    /// stay byte-identical to the raw expression, which is what those IDs
    /// were built from before targets existed. Git refs cannot contain `:`,
    /// so the `gg:` namespace cannot collide with an expression.
    public var identityKey: String {
        switch self {
        case .expression(let expression): expression
        case .stackEntry(let ggID): "gg:\(ggID)"
        }
    }

    /// What the revision row shows to the left of `-> <sha>`.
    public var displayLabel: String {
        switch self {
        case .expression(let expression): expression
        case .stackEntry(let ggID): ggID
        }
    }

    public var expressionValue: String? {
        guard case .expression(let expression) = self else { return nil }
        return expression
    }

    public var ggID: String? {
        guard case .stackEntry(let ggID) = self else { return nil }
        return ggID
    }

    public var isStackEntry: Bool { ggID != nil }

    /// Trims surrounding whitespace and rejects an empty payload.
    public func normalized() -> TrackedRevisionTarget? {
        switch self {
        case .expression(let expression):
            let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .expression(trimmed)
        case .stackEntry(let ggID):
            let trimmed = ggID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .stackEntry(ggID: trimmed)
        }
    }
}
