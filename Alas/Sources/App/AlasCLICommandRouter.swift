import Foundation

@MainActor
struct AlasCLICommandRouter {
    private struct FileIdentity: Equatable {
        let systemNumber: UInt64
        let fileNumber: UInt64
    }

    var sessionWorktreeId: (String) -> String?
    var originatingWorktree: (String) -> Worktree?
    var visibleWorktrees: () -> [Worktree]
    var openRelativeFile: (String, String) -> Void
    var openExternalFile: (URL, String) -> Void
    var focusWorktree: (Worktree) -> Void = { _ in }
    var createWorktree: (Worktree, String, String?) async -> AlasCLIResponse = { _, _, _ in
        .error("Creating worktrees from the terminal is not available yet.")
    }
    var deleteWorktree: (Worktree, Bool, Bool) async -> AlasCLIResponse = { _, _, _ in
        .error("Deleting worktrees from the terminal is not available yet.")
    }
    var openReviewChanges: (Worktree) -> Void = { _ in }
    var openProviderReview: (Worktree, String) async -> AlasCLIResponse = { _, _ in
        .error("Opening provider reviews from the terminal is not available yet.")
    }
    var activateApp: () -> Void

    func handle(_ request: AlasCLIRequest) async -> AlasCLIResponse {
        guard let sessionId = request.sessionId,
              let originWorktreeId = sessionWorktreeId(sessionId),
              let origin = originatingWorktree(originWorktreeId) else {
            return .error("Unknown Alas terminal session.")
        }

        switch request.command {
        case .open(let paths):
            return handleOpen(paths: paths, originWorktreeId: originWorktreeId)
        case .worktree(let command):
            return await handleWorktree(command, origin: origin)
        case .review(let command):
            return await handleReview(command, origin: origin)
        case .resolve:
            return .error("resolve is not available yet.")
        }
    }

    private func handleOpen(paths: [String], originWorktreeId: String) -> AlasCLIResponse {
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

    private func handleWorktree(_ command: AlasCLIRequest.WorktreeCommand, origin: Worktree) async -> AlasCLIResponse {
        let projectWorktrees = visibleWorktrees().filter { $0.projectId == origin.projectId }
        switch command {
        case .list:
            return .text(AlasCLIWorktreeResolver.rows(worktrees: projectWorktrees, currentWorktreeId: origin.id))
        case .switch(let target):
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
        case .new(let branch, let base):
            return await createWorktree(origin, branch, base)
        case .delete(let target, let force, let keepBranch):
            switch AlasCLIWorktreeResolver.resolve(target: target, worktrees: projectWorktrees) {
            case .matched(let worktree):
                return await deleteWorktree(worktree, force, keepBranch)
            case .missing(let target):
                return .error("unknown worktree \"\(target)\"")
            case .ambiguous(let labels):
                return .error("ambiguous worktree \"\(target)\"; matches: \(labels.joined(separator: ", "))")
            }
        }
    }

    private func handleReview(_ command: AlasCLIRequest.ReviewCommand, origin: Worktree) async -> AlasCLIResponse {
        switch command {
        case .localChanges:
            openReviewChanges(origin)
            activateApp()
            return .ok
        case .provider(let target):
            return await openProviderReview(origin, target)
        }
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
        ) ?? fileSystemRelativePathAndDepth(for: url, in: rootURL)
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

    private func fileSystemRelativePathAndDepth(for url: URL, in rootURL: URL) -> (relativePath: String, rootComponentCount: Int)? {
        guard let rootIdentity = fileIdentity(at: rootURL.path) else { return nil }
        var ancestor = url.deletingLastPathComponent()
        var relativeComponents = [url.lastPathComponent]

        while ancestor.path != "/" {
            if fileIdentity(at: ancestor.path) == rootIdentity {
                return (relativeComponents.reversed().joined(separator: "/"), rootURL.pathComponents.count)
            }
            relativeComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return nil
    }

    private func fileIdentity(at path: String) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return FileIdentity(systemNumber: systemNumber.uint64Value, fileNumber: fileNumber.uint64Value)
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
