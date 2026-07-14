import Foundation

/// Entrypoint-neutral facade over the app capabilities the CLI (and, later, an
/// MCP bridge) drive. It speaks domain terms — worktrees, paths, targets — not
/// wire types, so multiple front ends can reuse it.
@MainActor
struct AlasActionService {
    private struct FileIdentity: Equatable {
        let systemNumber: UInt64
        let fileNumber: UInt64
    }

    var visibleWorktrees: () -> [Worktree]
    var openRelativeFile: (String, String) -> Void
    var openExternalFile: (URL, String) -> Void
    var focusWorktree: (Worktree) -> Void = { _ in }
    var createWorktree: (Worktree, String, String?) async -> AlasCLIResponse = { _, _, _ in
        .error("Creating worktrees from the terminal is not available yet.")
    }
    var deleteWorktreeAction: (Worktree, Bool, Bool) async -> AlasCLIResponse = { _, _, _ in
        .error("Deleting worktrees from the terminal is not available yet.")
    }
    var openReviewChanges: (Worktree) -> Void = { _ in }
    var openProviderReview: (Worktree, String) async -> AlasCLIResponse = { _, _ in
        .error("Opening provider reviews from the terminal is not available yet.")
    }
    var activateApp: () -> Void

    /// Worktree owning `directory`: either the worktree the directory sits
    /// inside of (most-specific match wins), or the worktree rooted exactly
    /// at `directory` itself.
    func resolveWorktree(forDirectory directory: String) -> Worktree? {
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        if let match = containingWorktree(for: url) {
            return match.worktree
        }
        guard let directoryIdentity = fileIdentity(at: url.path) else { return nil }
        return visibleWorktrees().first { worktree in
            fileIdentity(at: worktree.path.standardizedFileURL.path) == directoryIdentity
        }
    }

    func open(paths: [String], fallbackWorktreeId: String) -> AlasCLIResponse {
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
                openExternalFile(url, fallbackWorktreeId)
            }
            openedAny = true
        }
        if openedAny { activateApp() }
        return errors.isEmpty ? .ok : .error(errors.joined(separator: " "))
    }

    func list(origin: Worktree, projectWorktrees: [Worktree]) -> AlasCLIResponse {
        .text(AlasCLIWorktreeResolver.rows(worktrees: projectWorktrees, currentWorktreeId: origin.id))
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

    func new(origin: Worktree, branch: String, base: String?) async -> AlasCLIResponse {
        await createWorktree(origin, branch, base)
    }

    func delete(target: String, projectWorktrees: [Worktree], force: Bool, keepBranch: Bool) async -> AlasCLIResponse {
        switch AlasCLIWorktreeResolver.resolve(target: target, worktrees: projectWorktrees) {
        case .matched(let worktree):
            return await deleteWorktreeAction(worktree, force, keepBranch)
        case .missing(let target):
            return .error("unknown worktree \"\(target)\"")
        case .ambiguous(let labels):
            return .error("ambiguous worktree \"\(target)\"; matches: \(labels.joined(separator: ", "))")
        }
    }

    func reviewLocal(origin: Worktree) -> AlasCLIResponse {
        openReviewChanges(origin)
        activateApp()
        return .ok
    }

    func reviewProvider(origin: Worktree, target: String) async -> AlasCLIResponse {
        await openProviderReview(origin, target)
    }

    // MARK: - Worktree matching (moved verbatim from AlasCLICommandRouter)

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
