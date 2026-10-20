import Foundation
import AlasFoundation

public struct ReviewDraftSessionID: Codable, Equatable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public let sourceKind: ReviewDraftSourceKind

    public init(rawValue: String, sourceKind: ReviewDraftSourceKind) {
        self.rawValue = rawValue
        self.sourceKind = sourceKind
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first,
              let sourceKind = ReviewDraftSourceKind(rawValue: first)
        else { return nil }
        self.rawValue = rawValue
        self.sourceKind = sourceKind
    }

    public static func localChanges(worktreeID: String, worktreePath: URL, scope: ReviewDraftLocalChangesScope) -> Self {
        make(.localChanges, [worktreeID, worktreePath.standardizedFileURL.path, scope.rawValue])
    }

    public static func commit(worktreeID: String, repositoryPath: URL, sha: String) -> Self {
        make(.commit, [worktreeID, repositoryPath.standardizedFileURL.path, sha])
    }

    public static func trackedCommit(worktreeID: String, repositoryPath: URL, targetKey: String) -> Self {
        make(.trackedCommit, [worktreeID, repositoryPath.standardizedFileURL.path, targetKey])
    }

    public static func commitRange(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.commitRange, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    public static func draftCommit(worktreeID: String, repositoryPath: URL) -> Self {
        make(.draftCommit, [worktreeID, repositoryPath.standardizedFileURL.path])
    }

    public static func branch(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.branch, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    public static func branchWithLocalChanges(worktreeID: String, repositoryPath: URL, base: String) -> Self {
        make(.branchWithLocalChanges, [worktreeID, repositoryPath.standardizedFileURL.path, base])
    }

    public static func sinceSnapshot(worktreeID: String, repositoryPath: URL, tree: String) -> Self {
        make(.sinceSnapshot, [worktreeID, repositoryPath.standardizedFileURL.path, tree])
    }

    public static func reviewRequest(
        worktreeID: String,
        provider: CodeHostKind,
        host: String,
        repositorySlug: String,
        number: Int
    ) -> Self {
        make(.reviewRequest, [worktreeID, provider.rawValue, host.lowercased(), repositorySlug, "\(number)"])
    }

    public static func draftReviewRequest(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.draftReviewRequest, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    public func matchesDraftReviewRequest(worktreeID: String, base: String, head: String) -> Bool {
        guard sourceKind == .draftReviewRequest else { return false }
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        return parts.count == 5
            && parts[1] == Self.escape(worktreeID)
            && parts[3] == Self.escape(base)
            && parts[4] == Self.escape(head)
    }

    /// Every factory puts the worktree ID in field 1, so a session ID can be
    /// scoped to a worktree without decoding the rest of its fields.
    public func isFor(worktreeID: String) -> Bool {
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        return parts[1] == Self.escape(worktreeID)
    }

    /// The code host for a `.reviewRequest` session id, decoded from its raw
    /// fields (`reviewRequest`'s second field is always `provider.rawValue`).
    /// nil for any other `sourceKind`.
    public var reviewRequestProvider: CodeHostKind? {
        guard sourceKind == .reviewRequest else { return nil }
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        return CodeHostKind(rawValue: parts[2])
    }

    /// The scope for a `.localChanges` session id, decoded from its raw
    /// fields (`localChanges`'s third field is always `scope.rawValue`).
    /// nil for any other `sourceKind`.
    public var localChangesScope: ReviewDraftLocalChangesScope? {
        guard sourceKind == .localChanges else { return nil }
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        return ReviewDraftLocalChangesScope(rawValue: parts[3])
    }

    private static let separator: Character = "\u{1f}"

    private static func make(_ kind: ReviewDraftSourceKind, _ fields: [String]) -> Self {
        let escapedFields = ([kind.rawValue] + fields).map(escape)
        return ReviewDraftSessionID(rawValue: escapedFields.joined(separator: String(separator)), sourceKind: kind)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: String(separator), with: "\\u001f")
    }
}
