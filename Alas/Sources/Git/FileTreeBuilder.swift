import Foundation

enum FileTreeBuilder {
    static func build(
        paths: [String],
        badges: [String: String],
        visibility: [String: FileVisibility] = [:],
        directories: Set<String> = [],
        lazyDirectories: Set<String> = []
    ) -> [FileTreeNode] {
        var roots: [String: TreeBuildNode] = [:]
        let nestedDirectories = nestedDirectoryPaths(paths)
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            insert(
                parts: parts,
                into: &roots,
                fullPath: path,
                badges: badges,
                visibility: visibility,
                directories: directories,
                lazyDirectories: lazyDirectories,
                nestedDirectories: nestedDirectories,
                prefix: ""
            )
        }
        return finalise(roots).sorted(by: nodeOrder)
    }

    private final class TreeBuildNode {
        let name: String
        let path: String
        let isDir: Bool
        var badge: String?
        var visibility: FileVisibility
        var childrenState: DirectoryChildrenState
        var children: [String: TreeBuildNode] = [:]
        init(
            name: String,
            path: String,
            isDir: Bool,
            badge: String?,
            visibility: FileVisibility,
            childrenState: DirectoryChildrenState
        ) {
            self.name = name
            self.path = path
            self.isDir = isDir
            self.badge = badge
            self.visibility = visibility
            self.childrenState = childrenState
        }
    }

    private static func insert(
        parts: [String],
        into map: inout [String: TreeBuildNode],
        fullPath: String,
        badges: [String: String],
        visibility: [String: FileVisibility],
        directories: Set<String>,
        lazyDirectories: Set<String>,
        nestedDirectories: Set<String>,
        prefix: String
    ) {
        guard let head = parts.first else { return }
        let isLeaf = parts.count == 1
        let nodePath = prefix.isEmpty ? head : "\(prefix)/\(head)"
        let hasDirectoryMetadata = isDirectoryPath(
            fullPath,
            directories: directories,
            lazyDirectories: lazyDirectories
        )
        let hasNestedChildren = nestedDirectories.contains(nodePath)
        let explicitDirectory = hasDirectoryMetadata && !hasNestedChildren
        let isDir = !isLeaf || explicitDirectory
        if isLeaf {
            let badge = badges[fullPath]
            if hasDirectoryMetadata && hasNestedChildren {
                upsertDirectory(
                    name: head,
                    path: nodePath,
                    into: &map,
                    visibility: visibility,
                    lazyDirectories: lazyDirectories
                )
                if badge == nil { return }
            }
            let key = nodeKey(name: head, isDir: isDir)
            let existing = map[key]
            if existing == nil {
                map[key] = TreeBuildNode(
                    name: head,
                    path: nodePath,
                    isDir: isDir,
                    badge: badge,
                    visibility: nodeVisibility(nodePath, visibility: visibility),
                    childrenState: childrenState(path: nodePath, isDir: isDir, lazyDirectories: lazyDirectories)
                )
            } else {
                existing?.badge = badge
                existing?.visibility = nodeVisibility(nodePath, visibility: visibility)
                existing?.childrenState = childrenState(path: nodePath, isDir: isDir, lazyDirectories: lazyDirectories)
            }
        } else {
            let key = nodeKey(name: head, isDir: true)
            let existing = map[key]
            let dir = existing ?? TreeBuildNode(
                name: head,
                path: nodePath,
                isDir: true,
                badge: nil,
                visibility: nodeVisibility(nodePath, visibility: visibility),
                childrenState: childrenState(path: nodePath, isDir: true, lazyDirectories: lazyDirectories)
            )
            dir.visibility = nodeVisibility(nodePath, visibility: visibility)
            dir.childrenState = childrenState(path: nodePath, isDir: true, lazyDirectories: lazyDirectories)
            map[key] = dir
            insert(
                parts: Array(parts.dropFirst()),
                into: &dir.children,
                fullPath: fullPath,
                badges: badges,
                visibility: visibility,
                directories: directories,
                lazyDirectories: lazyDirectories,
                nestedDirectories: nestedDirectories,
                prefix: nodePath
            )
        }
    }

    private static func upsertDirectory(
        name: String,
        path: String,
        into map: inout [String: TreeBuildNode],
        visibility: [String: FileVisibility],
        lazyDirectories: Set<String>
    ) {
        let key = nodeKey(name: name, isDir: true)
        let dir = map[key] ?? TreeBuildNode(
            name: name,
            path: path,
            isDir: true,
            badge: nil,
            visibility: nodeVisibility(path, visibility: visibility),
            childrenState: childrenState(path: path, isDir: true, lazyDirectories: lazyDirectories)
        )
        dir.visibility = nodeVisibility(path, visibility: visibility)
        dir.childrenState = childrenState(path: path, isDir: true, lazyDirectories: lazyDirectories)
        map[key] = dir
    }

    private static func nestedDirectoryPaths(_ paths: [String]) -> Set<String> {
        var directories: Set<String> = []
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count > 1 else { continue }
            for index in 1..<parts.count {
                directories.insert(parts.prefix(index).joined(separator: "/"))
            }
        }
        return directories
    }

    private static func isDirectoryPath(
        _ path: String,
        directories: Set<String>,
        lazyDirectories: Set<String>
    ) -> Bool {
        directories.contains(path) || lazyDirectories.contains(path)
    }

    private static func nodeVisibility(_ path: String, visibility: [String: FileVisibility]) -> FileVisibility {
        if let v = visibility[path] { return v }
        // Inherit non-tracked visibility from the nearest ancestor so that
        // nested paths inside an ignored/excluded folder keep the parent's
        // status even when the visibility dict only contains root entries.
        var current = path
        while let slash = current.lastIndex(of: "/") {
            current = String(current[current.startIndex..<slash])
            if let v = visibility[current], v != .tracked {
                return v
            }
        }
        return .tracked
    }

    private static func childrenState(
        path: String,
        isDir: Bool,
        lazyDirectories: Set<String>
    ) -> DirectoryChildrenState {
        isDir && lazyDirectories.contains(path) ? .notLoaded : .loaded
    }

    private static func nodeKey(name: String, isDir: Bool) -> String {
        "\(isDir ? "dir" : "file"):\(name)"
    }

    private static func finalise(_ map: [String: TreeBuildNode]) -> [FileTreeNode] {
        map.values.map { node -> FileTreeNode in
            let kids = node.isDir && node.childrenState != .notLoaded
                ? finalise(node.children).sorted(by: nodeOrder)
                : nil
            return FileTreeNode(
                name: node.name,
                path: node.path,
                kind: node.isDir ? .dir : .file,
                children: kids,
                badge: node.badge,
                visibility: node.visibility,
                childrenState: node.childrenState
            )
        }
    }

    private static func nodeOrder(_ a: FileTreeNode, _ b: FileTreeNode) -> Bool {
        if a.kind != b.kind { return a.kind == .dir }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
