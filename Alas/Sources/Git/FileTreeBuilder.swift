import Foundation

enum FileTreeBuilder {
    static func build(paths: [String], badges: [String: String]) -> [FileTreeNode] {
        var roots: [String: TreeBuildNode] = [:]
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            insert(parts: parts, into: &roots, fullPath: path, badges: badges, prefix: "")
        }
        return finalise(roots).sorted(by: nodeOrder)
    }

    private final class TreeBuildNode {
        let name: String
        let path: String
        let isDir: Bool
        var badge: String?
        var children: [String: TreeBuildNode] = [:]
        init(name: String, path: String, isDir: Bool, badge: String?) {
            self.name = name; self.path = path; self.isDir = isDir; self.badge = badge
        }
    }

    private static func insert(
        parts: [String],
        into map: inout [String: TreeBuildNode],
        fullPath: String,
        badges: [String: String],
        prefix: String
    ) {
        guard let head = parts.first else { return }
        let isLeaf = parts.count == 1
        let nodePath = prefix.isEmpty ? head : "\(prefix)/\(head)"
        let existing = map[head]
        if isLeaf {
            let badge = badges[fullPath]
            if existing == nil {
                map[head] = TreeBuildNode(name: head, path: nodePath, isDir: false, badge: badge)
            }
        } else {
            let dir = existing ?? TreeBuildNode(name: head, path: nodePath, isDir: true, badge: nil)
            map[head] = dir
            insert(parts: Array(parts.dropFirst()), into: &dir.children, fullPath: fullPath, badges: badges, prefix: nodePath)
        }
    }

    private static func finalise(_ map: [String: TreeBuildNode]) -> [FileTreeNode] {
        map.values.map { node -> FileTreeNode in
            let kids = node.isDir ? finalise(node.children).sorted(by: nodeOrder) : nil
            return FileTreeNode(
                name: node.name,
                path: node.path,
                kind: node.isDir ? .dir : .file,
                children: kids,
                badge: node.badge
            )
        }
    }

    private static func nodeOrder(_ a: FileTreeNode, _ b: FileTreeNode) -> Bool {
        if a.kind != b.kind { return a.kind == .dir }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
