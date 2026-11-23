import Foundation
import AlasPlatform

/// The review instruction layers that sit between the global prompt and the
/// Alas section. Each layer adds to the ones before it.
public struct CodeReviewInstructions: Equatable, Sendable {
    /// `.alas/code-review.md`.
    public var repoFile: String?
    public var project: String?
    /// `.alas/code-review.local.md`.
    public var localFile: String?

    public static let repoFilePath = ".alas/code-review.md"
    public static let localFilePath = ".alas/code-review.local.md"

    public init(repoFile: String? = nil, project: String? = nil, localFile: String? = nil) {
        self.repoFile = repoFile
        self.project = project
        self.localFile = localFile
    }
}

public enum CodeReviewInstructionsResolver {
    /// Reads both files under `worktreePath`, over ssh for a remote worktree.
    /// Only a missing file is nil: a read that fails throws, so a review never
    /// runs without instructions the repo asked for.
    public static func load(worktreePath: URL, projectInstructions: String?) async throws -> CodeReviewInstructions {
        let host = RemoteHostRegistry.shared.host(forPath: worktreePath.path)
        let repoFile = try await RepoTextFileReader.read(
            worktreePath.appendingPathComponent(CodeReviewInstructions.repoFilePath), host: host
        )
        let localFile = try await RepoTextFileReader.read(
            worktreePath.appendingPathComponent(CodeReviewInstructions.localFilePath), host: host
        )
        let project = projectInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CodeReviewInstructions(
            repoFile: nonBlank(repoFile),
            project: project?.isEmpty == false ? project : nil,
            localFile: nonBlank(localFile)
        )
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
