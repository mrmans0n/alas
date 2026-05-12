import Foundation

enum ChangesTreeBuilder {
    static func build(files: [ChangedFile]) -> [FileTreeNode] {
        var roots: [String: TreeBuildNode] = [:]
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            insert(parts: parts, into: &roots, file: file, prefix: "")
        }
        return compact(finalise(roots)).sorted(by: nodeOrder)
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
        file: ChangedFile,
        prefix: String
    ) {
        guard let head = parts.first else { return }

        let isLeaf = parts.count == 1
        let nodePath = prefix.isEmpty ? head : "\(prefix)/\(head)"

        if isLeaf {
            let key = nodeKey(name: head, isDir: false)
            let existing = map[key]
            if existing == nil {
                map[key] = TreeBuildNode(
                    name: head,
                    path: file.path,
                    isDir: false,
                    badge: file.status.isEmpty ? nil : file.status
                )
            }
        } else {
            let key = nodeKey(name: head, isDir: true)
            let existing = map[key]
            let dir = existing ?? TreeBuildNode(name: head, path: nodePath, isDir: true, badge: nil)
            map[key] = dir
            insert(parts: Array(parts.dropFirst()), into: &dir.children, file: file, prefix: nodePath)
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

    private static func compact(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.map { node in
            guard node.kind == .dir else { return node }

            var compacted = FileTreeNode(
                name: node.name,
                path: node.path,
                kind: node.kind,
                children: compact(node.children ?? []),
                badge: node.badge
            )

            while
                let children = compacted.children,
                children.count == 1,
                let child = children.first,
                child.kind == .dir
            {
                compacted = FileTreeNode(
                    name: "\(compacted.name)/\(child.name)",
                    path: child.path,
                    kind: .dir,
                    children: child.children,
                    badge: nil
                )
            }

            return compacted
        }
    }

    private static func nodeOrder(_ a: FileTreeNode, _ b: FileTreeNode) -> Bool {
        if a.kind != b.kind { return a.kind == .dir }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
