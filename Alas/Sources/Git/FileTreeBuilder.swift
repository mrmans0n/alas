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
            self.name = name
            self.path = path
            self.isDir = isDir
            self.badge = badge
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
        if isLeaf {
            let key = nodeKey(name: head, isDir: false)
            let existing = map[key]
            let badge = badges[fullPath]
            if existing == nil {
                map[key] = TreeBuildNode(name: head, path: nodePath, isDir: false, badge: badge)
            }
        } else {
            let key = nodeKey(name: head, isDir: true)
            let existing = map[key]
            let dir = existing ?? TreeBuildNode(name: head, path: nodePath, isDir: true, badge: nil)
            map[key] = dir
            insert(parts: Array(parts.dropFirst()), into: &dir.children, fullPath: fullPath, badges: badges, prefix: nodePath)
        }
    }

    private static func nodeKey(name: String, isDir: Bool) -> String {
        "\(isDir ? "dir" : "file"):\(name)"
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
