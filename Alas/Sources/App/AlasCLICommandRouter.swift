import Foundation

@MainActor
struct AlasCLICommandRouter {
    var sessionWorktreeId: (String) -> String?
    var originatingWorktree: (String) -> Worktree?
    var visibleWorktrees: () -> [Worktree]
    var openRelativeFile: (String, String) -> Void
    var openExternalFile: (URL, String) -> Void
    var activateApp: () -> Void

    func handle(_ request: AlasCLIRequest) -> AlasCLIResponse {
        guard request.command == .open else {
            return .error("Unsupported command.")
        }
        guard let originWorktreeId = sessionWorktreeId(request.sessionId),
              originatingWorktree(originWorktreeId) != nil else {
            return .error("Unknown Alas terminal session.")
        }

        var errors: [String] = []
        var openedAny = false
        for rawPath in request.paths {
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard fileExists(at: url) else {
                errors.append("\(url.path) does not exist.")
                continue
            }
            guard !isDirectory(at: url) else {
                errors.append("\(url.path) is a directory.")
                continue
            }

            if let match = containingWorktree(for: url) {
                openRelativeFile(match.relativePath, match.worktree.id)
            } else {
                openExternalFile(url, originWorktreeId)
            }
            openedAny = true
        }

        if openedAny {
            activateApp()
        }
        return errors.isEmpty ? .ok : .error(errors.joined(separator: " "))
    }

    private func containingWorktree(for url: URL) -> (worktree: Worktree, relativePath: String)? {
        var bestMatch: (worktree: Worktree, relativePath: String, rootComponentCount: Int)?
        for worktree in visibleWorktrees() {
            let rootURL = worktree.path.standardizedFileURL
            guard let match = relativePathAndDepth(for: url, in: rootURL) else { continue }
            if let currentBest = bestMatch,
               match.rootComponentCount <= currentBest.rootComponentCount {
                continue
            }
            bestMatch = (worktree, match.relativePath, match.rootComponentCount)
        }
        guard let bestMatch else { return nil }
        return (bestMatch.worktree, bestMatch.relativePath)
    }

    private func relativePathAndDepth(for url: URL, in rootURL: URL) -> (relativePath: String, rootComponentCount: Int)? {
        if let match = relativePathAndDepth(
            targetComponents: url.standardizedFileURL.pathComponents,
            rootComponents: rootURL.pathComponents
        ) {
            return match
        }

        return relativePathAndDepth(
            targetComponents: url.resolvingSymlinksInPath().standardizedFileURL.pathComponents,
            rootComponents: rootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        )
    }

    private func relativePathAndDepth(
        targetComponents: [String],
        rootComponents: [String]
    ) -> (relativePath: String, rootComponentCount: Int)? {
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        let relative = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        return (relative, rootComponents.count)
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
