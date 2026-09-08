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
        resolvedRoot = Self.resolvedURL(for: URL(fileURLWithPath: rootPath))
    }

    func managedURL(for path: String) throws -> URL {
        let candidate = Self.resolvedURL(for: URL(fileURLWithPath: path))
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
        let fileManager = FileManager.default
        var components = normalizedComponents(url.pathComponents.filter { $0 != "/" })
        var resolvedComponents: [String] = []
        var seen = Set<String>()
        var symlinkDepth = 0

        while components.isEmpty == false {
            let component = components.removeFirst()
            if component == "." || component.isEmpty {
                continue
            }
            if component == ".." {
                if resolvedComponents.isEmpty == false {
                    resolvedComponents.removeLast()
                }
                continue
            }

            let candidateComponents = resolvedComponents + [component]
            let candidatePath = "/" + candidateComponents.joined(separator: "/")
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: candidatePath) else {
                resolvedComponents.append(component)
                continue
            }

            guard seen.insert(candidatePath).inserted, symlinkDepth < 40 else { break }
            symlinkDepth += 1

            if destination.hasPrefix("/") {
                components = normalizedComponents(URL(fileURLWithPath: destination).pathComponents.filter { $0 != "/" } + components)
            } else {
                components = normalizedComponents(resolvedComponents + destination.split(separator: "/").map(String.init) + components)
            }
            resolvedComponents = []
        }

        return URL(fileURLWithPath: "/" + resolvedComponents.joined(separator: "/"))
    }

    private static func normalizedComponents(_ components: [String]) -> [String] {
        var result: [String] = []
        for component in components {
            switch component {
            case "", ".":
                continue
            case "..":
                if result.isEmpty == false {
                    result.removeLast()
                }
            default:
                result.append(component)
            }
        }
        return result
    }
}
