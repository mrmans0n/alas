import Foundation

/// Finds the pre-rename/pre-copy path for a file in a loaded provider review's
/// file list, so a CLI/MCP-filed review comment can carry `originalPath` the
/// way UI-created drafts already do (from `DiffReviewFileSummary.originalPath`).
/// Returns nil when the path isn't in the review or the file isn't a
/// rename/copy — in which case GitLab publishing correctly falls back to
/// `originalPath ?? path`.
enum ProviderReviewOriginalPathResolver {
    static func originalPath(forRelativePath relativePath: String, in files: [DiffReviewFileSummary]) -> String? {
        files.first(where: { $0.path == relativePath })?.originalPath
    }
}
