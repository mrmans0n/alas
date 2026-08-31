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
        resolvedRoot = Self.resolvedURL(for: URL(fileURLWithPath: rootPath).standardizedFileURL)
    }

    func managedURL(for path: String) throws -> URL {
        let candidate = Self.resolvedURL(for: URL(fileURLWithPath: path).standardizedFileURL)
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
    private static func resolvedURL(for url: URL) -> URL {
        let candidate = url.standardizedFileURL
        var resolved = URL(fileURLWithPath: "/")
        let fileManager = FileManager.default
        var components = candidate.pathComponents.filter { $0 != "/" }
        var seen = Set<String>()
        while components.isEmpty == false {
            let component = components.removeFirst()
            resolved.appendPathComponent(component)
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: resolved.path) else {
                continue
            }
            guard seen.insert(resolved.path).inserted else { break }
            let target: URL
            if destination.hasPrefix("/") {
                target = URL(fileURLWithPath: destination)
            } else {
                target = resolved.deletingLastPathComponent()
                    .appendingPathComponent(destination)
            }
            components = target.pathComponents.filter { $0 != "/" } + components
            resolved = URL(fileURLWithPath: "/")
        }
        return resolved
    }
}
