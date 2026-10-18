import Foundation

/// The presentation the CLI (and, later, an MCP bridge) drives: opening
/// files and reviews and switching worktrees. Domain commands go to
/// `AlasHost`; this only shows their results.
@MainActor
struct AlasActionService {
    var visibleWorktrees: () -> [Worktree]
    var openRelativeFile: (String, String) -> Void
    var openExternalFile: (URL, String) -> Void
    var openRelativeFileAtLines: (String, String, ClosedRange<Int>) -> Void = { _, _, _ in }
    var openExternalFileAtLines: (URL, String, ClosedRange<Int>) -> Void = { _, _, _ in }
    var focusWorktree: (Worktree) -> Void = { _ in }
    var openReviewChanges: (Worktree) -> Void = { _ in }
    var openReview: (Worktree, String, HostCaller) async -> AlasCLIResponse = { _, _, _ in
        .error("Opening provider reviews from the terminal is not available yet.")
    }
    var activateApp: () -> Void

    func open(paths: [String], fallbackWorktreeId: String) -> AlasCLIResponse {
        open(paths: paths, fallbackWorktreeId: fallbackWorktreeId, lineRange: nil)
    }

    func openAt(path: String, line: Int, endLine: Int?, fallbackWorktreeId: String) -> AlasCLIResponse {
        let start = line - 1
        return open(
            paths: [path],
            fallbackWorktreeId: fallbackWorktreeId,
            lineRange: start ... ((endLine ?? line) - 1)
        )
    }

    private func open(
        paths: [String],
        fallbackWorktreeId: String,
        lineRange: ClosedRange<Int>?
    ) -> AlasCLIResponse {
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
            if let match = WorktreePaths.containing(url, in: visibleWorktrees()) {
                if let lineRange {
                    openRelativeFileAtLines(match.relativePath, match.worktree.id, lineRange)
                } else {
                    openRelativeFile(match.relativePath, match.worktree.id)
                }
            } else {
                if let lineRange {
                    openExternalFileAtLines(url, fallbackWorktreeId, lineRange)
                } else {
                    openExternalFile(url, fallbackWorktreeId)
                }
            }
            openedAny = true
        }
        if openedAny { activateApp() }
        return errors.isEmpty ? .ok : .error(errors.joined(separator: " "))
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

    func reviewLocal(origin: Worktree) -> AlasCLIResponse {
        openReviewChanges(origin)
        activateApp()
        let sessionID = ReviewDraftSessionID.localChanges(
            worktreeID: origin.id,
            worktreePath: origin.path,
            scope: .all
        )
        return .text([
            "Opened review of local changes in Alas.",
            ReviewsAPI.jsonLine(["session_id": sessionID.rawValue]),
        ])
    }

    func reviewTarget(origin: Worktree, target: String, caller: HostCaller) async -> AlasCLIResponse {
        await openReview(origin, target, caller)
    }

    /// Failure detail for `reviewOrigin`: a single message describing why the
    /// `--worktree` override couldn't be resolved.
    struct ReviewOriginResolutionError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The worktree a review command operates on: the explicit `--worktree`
    /// override when given (resolved against the origin's project), else the
    /// origin itself.
    func reviewOrigin(
        origin: Worktree,
        override: String?,
        projectWorktrees: [Worktree]
    ) -> Swift.Result<Worktree, ReviewOriginResolutionError> {
        guard let override else { return .success(origin) }
        switch AlasCLIWorktreeResolver.resolve(target: override, worktrees: projectWorktrees) {
        case .matched(let worktree):
            return .success(worktree)
        case .missing(let target):
            let available = projectWorktrees.map(\.branch).joined(separator: ", ")
            return .failure(ReviewOriginResolutionError(message: "unknown worktree \"\(target)\"; available: \(available)"))
        case .ambiguous(let labels):
            return .failure(ReviewOriginResolutionError(
                message: "ambiguous worktree \"\(override)\"; matches: \(labels.joined(separator: ", "))"
            ))
        }
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
