import Foundation
import CoreGraphics

public struct ComputerUseAXNode: Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var description: String?
    public var frame: CGRect
    public var isEnabled: Bool
    public var isFocused: Bool
    public var children: [ComputerUseAXNode]
    /// Opaque index into the app-side handle table; never serialized.
    public var handle: Int?
    /// The read stopped at its depth limit here, and the element has children it didn't read.
    public var childrenUnread: Bool

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        frame: CGRect = .zero,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        children: [ComputerUseAXNode] = [],
        handle: Int? = nil,
        childrenUnread: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.children = children
        self.handle = handle
        self.childrenUnread = childrenUnread
    }
}

public struct ComputerUseInspectElement: Equatable, Sendable {
    public var ref: String
    public var depth: Int
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    /// The full value's length in characters when `value` was clipped; nil when it wasn't.
    public var valueLength: Int?
    public var description: String?
    public var frame: CGRect
    public var isEnabled: Bool
    public var isFocused: Bool
    /// False when no part of its frame shows: outside the window, or scrolled out of (or under
    /// another part of the window next to) an enclosing scroll area. True when it can't tell.
    public var isVisible: Bool
    /// Opaque handle copied from the node; never serialized.
    public var handle: Int?

    public init(
        ref: String,
        depth: Int,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        valueLength: Int? = nil,
        description: String? = nil,
        frame: CGRect = .zero,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        isVisible: Bool = true,
        handle: Int? = nil
    ) {
        self.ref = ref
        self.depth = depth
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.valueLength = valueLength
        self.description = description
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isVisible = isVisible
        self.handle = handle
    }
}

public enum ComputerUseInspectTree {
    static let maxStringLength = 200
    public static let depthHint =
        "Some elements are deeper than max_depth; pass a higher max_depth (up to 32) or a query."

    /// Refs are the pre-order index of each node among all nodes visited (root is `e1`),
    /// so a query or limit never renumbers them: the same element has the same ref in a
    /// filtered and an unfiltered listing of the same tree. `refs` maps the ref of every
    /// visited node with a handle, listed or not, so a filtered read keeps the others usable.
    /// `depthLimited`: elements were left out for being deeper than `maxDepth`, here or in the read.
    public static func flatten(
        _ root: ComputerUseAXNode,
        query: String?,
        limit: Int,
        maxDepth: Int
    ) -> (elements: [ComputerUseInspectElement], truncated: Bool, refs: [String: Int], depthLimited: Bool) {
        let needle = query.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        var elements: [ComputerUseInspectElement] = []
        var refs: [String: Int] = [:]
        var truncated = false
        var depthLimited = false
        var visited = 0

        func isSecure(_ node: ComputerUseAXNode) -> Bool {
            node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField"
        }

        func matches(_ node: ComputerUseAXNode) -> Bool {
            guard let needle else { return true }
            var fields: [String?] = [node.role, node.subrole, node.title, node.description]
            if !isSecure(node) { fields.append(node.value) }
            return fields.contains { $0?.lowercased().contains(needle) == true }
        }

        func clip(_ string: String?) -> String? {
            string.map { String($0.prefix(maxStringLength)) }
        }

        /// Whether any of the node's frame shows inside `clips` (the window and enclosing scroll
        /// areas); a node without a frame counts as shown.
        func isVisible(_ node: ComputerUseAXNode, clips: [CGRect]) -> Bool {
            guard node.frame.width > 0, node.frame.height > 0 else { return true }
            return ComputerUseInputGeometry.visibleCenter(of: node.frame, clippedTo: clips, requireOwnCenter: false) != nil
        }

        // Past the limit the walk goes on only to name the remaining nodes' refs.
        func visit(_ node: ComputerUseAXNode, depth: Int, clips: [CGRect]) {
            guard depth <= maxDepth else { return }
            visited += 1
            let ref = "e\(visited)"
            if let handle = node.handle { refs[ref] = handle }
            if matches(node) {
                if elements.count >= limit {
                    truncated = true
                } else {
                    let value = isSecure(node) ? nil : node.value
                    let length = value?.count ?? 0
                    elements.append(ComputerUseInspectElement(
                        ref: ref,
                        depth: depth,
                        role: clip(node.role) ?? node.role,
                        subrole: clip(node.subrole),
                        title: clip(node.title),
                        value: clip(value),
                        valueLength: length > maxStringLength ? length : nil,
                        description: clip(node.description),
                        frame: node.frame,
                        isEnabled: node.isEnabled,
                        isFocused: node.isFocused,
                        isVisible: isVisible(node, clips: clips),
                        handle: node.handle
                    ))
                }
            }
            if node.childrenUnread || (depth == maxDepth && !node.children.isEmpty) { depthLimited = true }
            // The window and every scroll area clip what they hold.
            let clipsChildren = (depth == 0 || node.role == "AXScrollArea") && node.frame.width > 0 && node.frame.height > 0
            let childClips = clipsChildren ? clips + [node.frame] : clips
            for child in node.children {
                visit(child, depth: depth + 1, clips: childClips)
            }
        }

        visit(root, depth: 0, clips: [])
        return (elements, truncated, refs, depthLimited)
    }
}
