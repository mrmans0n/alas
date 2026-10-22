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

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        frame: CGRect = .zero,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        children: [ComputerUseAXNode] = []
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
    }
}

public struct ComputerUseInspectElement: Equatable, Sendable {
    public var ref: String
    public var depth: Int
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var description: String?
    public var frame: CGRect
    public var isEnabled: Bool
    public var isFocused: Bool

    public init(
        ref: String,
        depth: Int,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        frame: CGRect = .zero,
        isEnabled: Bool = true,
        isFocused: Bool = false
    ) {
        self.ref = ref
        self.depth = depth
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
    }
}

public enum ComputerUseInspectTree {
    static let maxStringLength = 200

    public static func flatten(
        _ root: ComputerUseAXNode,
        query: String?,
        limit: Int,
        maxDepth: Int
    ) -> (elements: [ComputerUseInspectElement], truncated: Bool) {
        let needle = query.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        var elements: [ComputerUseInspectElement] = []
        var truncated = false

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

        // Returns false once traversal can stop.
        func visit(_ node: ComputerUseAXNode, depth: Int) -> Bool {
            guard depth <= maxDepth else { return true }
            if matches(node) {
                if elements.count >= limit {
                    truncated = true
                    return false
                }
                elements.append(ComputerUseInspectElement(
                    ref: "e\(elements.count + 1)",
                    depth: depth,
                    role: clip(node.role) ?? node.role,
                    subrole: clip(node.subrole),
                    title: clip(node.title),
                    value: isSecure(node) ? nil : clip(node.value),
                    description: clip(node.description),
                    frame: node.frame,
                    isEnabled: node.isEnabled,
                    isFocused: node.isFocused
                ))
            }
            for child in node.children where !visit(child, depth: depth + 1) {
                return false
            }
            return true
        }

        _ = visit(root, depth: 0)
        return (elements, truncated)
    }
}
