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

/// Why an Accessibility read stopped before it read every element within its depth.
public enum ComputerUseReadCut: String, Sendable, Equatable {
    /// It read as many elements as it may (a limit's worth, or a query's node budget).
    case nodeBudget = "node_budget"
    /// Its time limit passed.
    case timeLimit = "time_limit"
    /// The app stopped answering, or left elements unanswered.
    case appNotResponding = "app_not_responding"
    /// The app answered, but some elements' children couldn't be read.
    case elementsUnreadable = "elements_unreadable"
    /// A Chromium or Electron window read without the web content an earlier read of it showed,
    /// which the app was rebuilding (`ComputerUseWebContent.mayLackContent`).
    case webContentMissing = "web_content_missing"

    /// Elements in a row the app may leave unanswered (an AX message that timed out) before the
    /// read stops: one slow element, a source editor's whole text, doesn't end the walk.
    public static let unansweredLimit = 3

    /// The reason a read reports; nil when it read everything. An app that didn't answer explains
    /// the rest, a time limit explains elements it left unread, and both explain a node budget
    /// the read may not have reached otherwise.
    public static func reason(
        appNotResponding: Bool, timedOut: Bool, elementsUnreadable: Bool, budgetSpent: Bool
    ) -> Self? {
        if appNotResponding { return .appNotResponding }
        if timedOut { return .timeLimit }
        if elementsUnreadable { return .elementsUnreadable }
        return budgetSpent ? .nodeBudget : nil
    }

    /// What a read of one element's attributes says about its children.
    public enum ChildrenRead: Equatable, Sendable {
        /// The children entry holds a value.
        case read
        /// The element has no children: the attribute is absent or unsupported.
        case none
        /// The element no longer exists: it isn't on screen, and has no place in the tree.
        case gone
        /// The app didn't answer (`appNotResponding`).
        case unanswered
        /// The app answered, but not with the children (`elementsUnreadable`).
        case unreadable
        /// The batch read is unusable: read the attributes one at a time, and ask again with the
        /// children's own result.
        case perAttribute
    }

    /// Classifies a batch attribute read (`batchResult`, an `AXError`'s raw value; `batchComplete`,
    /// whether it returned one entry per attribute asked) and its children entry's error
    /// (`childrenError`, nil or 0 when it holds a value). A read one attribute at a time passes
    /// 0 and true, with the children read's own error.
    public static func children(batchResult: Int32, batchComplete: Bool, childrenError: Int32?) -> ChildrenRead {
        switch batchResult {
        case 0: if !batchComplete { return .perAttribute }
        case -25204: return .unanswered // cannotComplete
        case -25202: return .gone // invalidUIElement
        default: return .perAttribute
        }
        switch childrenError {
        case nil, 0: return .read
        case -25212, -25205, -25208: return .none // noValue, attributeUnsupported, notImplemented
        case -25202: return .gone
        case -25204: return .unanswered
        default: return .unreadable
        }
    }
}

public enum ComputerUseInspectTree {
    /// What `truncated_by` says about a truncated result: "limit" when it had more elements than
    /// `limit`, else why the read stopped; nil for a result that isn't truncated.
    public static func truncation(limitReached: Bool, cut: ComputerUseReadCut?) -> String? {
        limitReached ? "limit" : cut?.rawValue
    }

    static let maxStringLength = 200
    /// The warning next to `depth_limited`: only what would read deeper. A read at 32 levels, or
    /// one that takes no max_depth (computer_wait), can't; a query is suggested only when none was given.
    public static func depthHint(maxDepth: Int, queryGiven: Bool, takesMaxDepth: Bool) -> String {
        if maxDepth >= 32 || !takesMaxDepth {
            return "Some elements are deeper than \(maxDepth) levels, the deepest this read goes."
        }
        if queryGiven { return "Some elements are deeper than max_depth; pass a higher max_depth (up to 32)." }
        return "Some elements are deeper than max_depth; pass a higher max_depth (up to 32), or a query, which reads "
            + "32 levels unless max_depth is given."
    }

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
            ComputerUseInputGeometry.isShown(node.frame, clippedTo: clips)
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
