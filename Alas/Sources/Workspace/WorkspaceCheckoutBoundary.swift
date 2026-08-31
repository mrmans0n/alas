import Foundation

/// The physical containment boundary for files Alas manages on behalf of a
/// Workspace Checkout. Shells are intentionally not covered: they retain the
/// user's normal host permissions. Paths are resolved before comparison so a
/// symlink inside a checkout cannot be used to reach outside it.
struct WorkspaceCheckoutBoundary: Sendable {
    enum Error: Swift.Error, Equatable {
        case outsideCheckout
    }

    private let resolvedRoot: URL

    init(rootPath: String) {
        resolvedRoot = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    func managedURL(for path: String) throws -> URL {
        let candidate = resolvedURL(for: URL(fileURLWithPath: path).standardizedFileURL)
        let root = resolvedRoot.path
        let candidatePath = candidate.path
        guard candidatePath == root || candidatePath.hasPrefix(root + "/") else {
            throw Error.outsideCheckout
        }
        return candidate
    }

    func contains(_ path: String) -> Bool {
        (try? managedURL(for: path)) != nil
    }

    /// `URL.resolvingSymlinksInPath()` stops at a non-existent final file,
    /// which is exactly the common write case. Resolve the nearest existing
    /// ancestor first, then rebuild the not-yet-created suffix below it.
    private func resolvedURL(for url: URL) -> URL {
        let candidate = url.standardizedFileURL
        var resolved = URL(fileURLWithPath: "/")
        let fileManager = FileManager.default
        for component in candidate.pathComponents where component != "/" {
            resolved.appendPathComponent(component)
            // `fileExists` follows links and therefore misses dangling
            // symlinks. Ask the filesystem for link metadata at every path
            // component before a write creates its remaining leaf.
            resolved = Self.resolvingSymlinkChain(from: resolved, fileManager: fileManager)
        }
        return resolved.standardizedFileURL
    }

    private static func resolvingSymlinkChain(from url: URL, fileManager: FileManager) -> URL {
        var current = url.standardizedFileURL
        var seen = Set<String>()
        while let destination = try? fileManager.destinationOfSymbolicLink(atPath: current.path) {
            guard seen.insert(current.path).inserted else { break }
            if destination.hasPrefix("/") {
                current = URL(fileURLWithPath: destination).standardizedFileURL
            } else {
                current = URL(fileURLWithPath: destination, relativeTo: current.deletingLastPathComponent()).standardizedFileURL
            }
        }
        return current
    }
}
