import Foundation

/// A validated node of a plugin-described native view.
struct PluginViewNode: Equatable, Sendable {
    enum Kind: String, Sendable {
        case vstack, hstack, scroll, text, badge, button, textField, menu, card, divider, spacer
        // API 8.
        case progress, link
        // API 9.
        case markdown
        // API 14.
        case progressBar

        /// The plugin API that introduced the kind; an older plugin that sends it renders an invalid tree.
        var api: Int {
            switch self {
            case .progress, .link: 8
            case .markdown: 9
            case .progressBar: 14
            default: 4
            }
        }
    }
    enum Tone: String, Sendable {
        case normal, dim, accent, warn, danger
        // API 13.
        case success

        /// The plugin API that introduced the tone; an older plugin that sends it breaks the message.
        var api: Int { self == .success ? 13 : 4 }
    }
    struct MenuItem: Equatable, Sendable {
        let id: String
        let label: String
    }
    let id: String
    let kind: Kind
    var children: [PluginViewNode] = []   // stacks, card; scroll has exactly one
    var text: String? = nil               // text, badge, progress, markdown
    var label: String? = nil              // button, menu, link
    var url: URL? = nil                   // link: absolute https
    var value: String? = nil              // textField
    var placeholder: String? = nil
    var style: String? = nil              // validated per kind
    var tone: Tone? = nil
    var icon: String? = nil
    var spacing: Int? = nil
    var width: Int? = nil                 // vstack, card: fixed width in points
    var horizontal = false                // scroll axis
    var centered = false                  // hstack: `"align": "center"`, else first text baseline
    var done = 0, running = 0, total = 0  // progressBar: 0 ≤ done + running ≤ total
    var multiline = false
    var disabled = false
    var clickable = false
    var items: [MenuItem] = []

    /// Nothing to show: stacks and scrolls that hold only such trees.
    var isEmpty: Bool { [.vstack, .hstack, .scroll].contains(kind) && children.allSatisfy(\.isEmpty) }
}

struct PluginViewTreeError: Error, Equatable, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

/// Decodes and validates the untrusted `root` JSON a plugin sends with `view/render`.
enum PluginViewTree {
    static let maxNodes = 2_000, maxDepth = 16, maxString = 4_000, maxIDBytes = 64, maxMenuItems = 64, maxURLBytes = 2_048
    static let maxProgressTotal = 10_000
    /// A markdown node's text has its own bound, above `maxString` (API 9).
    static let maxMarkdownBytes = 32 * 1024

    /// Decodes and validates `root` (the raw JSON of the `root` field) from a plugin of manifest `api`. Returns the
    /// reason on failure.
    static func decode(_ json: Data, api: Int) -> Result<PluginViewNode, PluginViewTreeError> {
        // Reject hostile nesting on the raw bytes, before any recursive decoding runs.
        guard bracketDepthWithinBudget(json) else { return fail("tree is deeper than \(maxDepth) levels") }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: json) else { return fail("not a valid view tree") }
        var ids = Set<String>()
        var count = 0
        do {
            return .success(try validate(raw, depth: 1, api: api, ids: &ids, count: &count))
        } catch let error as PluginViewTreeError {
            return .failure(error)
        } catch {
            return fail("not a valid view tree")
        }
    }

    private static func fail(_ reason: String) -> Result<PluginViewNode, PluginViewTreeError> {
        .failure(PluginViewTreeError(reason: reason))
    }

    /// A node nested through `children` costs two brackets (`{`, `[`); through `scroll.child` one.
    private static func bracketDepthWithinBudget(_ json: Data) -> Bool {
        let budget = 2 * maxDepth + 2
        var depth = 0
        var inString = false
        var escaped = false
        for byte in json {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth > budget { return false }
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
            default: break
            }
        }
        return true
    }

    private final class Box: Decodable {
        let raw: Raw
        init(from decoder: Decoder) throws { raw = try Raw(from: decoder) }
    }

    private struct RawItem: Decodable {
        var id: String?
        var label: String?
    }

    private struct Raw: Decodable {
        var id: String?
        var kind: String?
        var children: [Raw]?
        var child: Box?
        var axis: String?
        var text: String?
        var label: String?
        var url: String?
        var value: String?
        var placeholder: String?
        var style: String?
        var tone: String?
        var icon: String?
        var spacing: Int?
        var width: Int?
        var multiline: Bool?
        var disabled: Bool?
        var clickable: Bool?
        var items: [RawItem]?
        var align: String?
        var done: Int?
        var running: Int?
        var total: Int?
    }

    private static func validate(_ raw: Raw, depth: Int, api: Int, ids: inout Set<String>, count: inout Int) throws -> PluginViewNode {
        func err(_ reason: String) -> PluginViewTreeError { PluginViewTreeError(reason: reason) }
        guard let id = raw.id, (1...maxIDBytes).contains(id.utf8.count) else { throw err("node ids must be 1 to \(maxIDBytes) bytes") }
        guard ids.insert(id).inserted else { throw err("duplicate id \"\(id)\"") }
        count += 1
        guard count <= maxNodes else { throw err("tree has more than \(maxNodes) nodes") }
        guard depth <= maxDepth else { throw err("tree is deeper than \(maxDepth) levels") }
        guard let kindName = raw.kind, let kind = PluginViewNode.Kind(rawValue: kindName) else {
            throw err("unknown kind \"\(raw.kind ?? "")\"")
        }
        guard kind.api <= api else { throw err("kind \"\(kindName)\" needs \"api\": \(kind.api)") }
        let prefix = "\(kind.rawValue) \"\(id)\""
        var node = PluginViewNode(id: id, kind: kind)

        if let toneName = raw.tone {
            guard let tone = PluginViewNode.Tone(rawValue: toneName) else { throw err("\(prefix) has unknown tone \"\(toneName)\"") }
            guard tone.api <= api else { throw err("tone \"\(toneName)\" needs \"api\": \(tone.api)") }
            node.tone = tone
        }
        if let spacing = raw.spacing {
            guard (0...32).contains(spacing) else { throw err("\(prefix) spacing must be 0 to 32") }
            node.spacing = spacing
        }
        if let width = raw.width, kind == .vstack || kind == .card {
            guard (40...1000).contains(width) else { throw err("\(prefix) width must be 40 to 1000") }
            node.width = width
        }
        let allowedStyles: [String] = switch kind {
        case .text: ["body", "caption", "title", "monospaced"]
        case .button: ["normal", "primary", "plain"]
        default: []
        }
        if let style = raw.style {
            guard allowedStyles.contains(style) else { throw err("\(prefix) has unknown style \"\(style)\"") }
            node.style = style
        }

        func string(_ value: String?, required field: String? = nil) throws -> String? {
            guard let value else {
                if let field { throw err("\(prefix) needs \(field)") }
                return nil
            }
            guard value.unicodeScalars.count <= maxString else { throw err("\(prefix) is longer than \(maxString) characters") }
            return value
        }
        switch kind {
        case .text, .badge: node.text = try string(raw.text, required: "text")
        case .button: node.label = try string(raw.label, required: "label")
        case .progress: node.text = try string(raw.text)
        case .progressBar:
            node.text = try string(raw.text)
            let done = raw.done ?? 0, running = raw.running ?? 0
            // Subtraction, not `done + running`: untrusted counts near `Int.max` would overflow.
            guard let total = raw.total, (1...maxProgressTotal).contains(total),
                  done >= 0, running >= 0, running <= total, done <= total - running else {
                throw err("\(prefix) needs a total of 1 to \(maxProgressTotal), and done and running of at least 0 that add up to at most total")
            }
            (node.done, node.running, node.total) = (done, running, total)
        case .markdown:
            guard let text = raw.text else { throw err("\(prefix) needs text") }
            guard text.utf8.count <= maxMarkdownBytes else { throw err("\(prefix) text is longer than \(maxMarkdownBytes) bytes") }
            node.text = text
        case .link:
            node.label = try string(raw.label, required: "label")
            guard let rawURL = raw.url else { throw err("\(prefix) needs url") }
            guard rawURL.utf8.count <= maxURLBytes, let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
                  url.host?.isEmpty == false
            else { throw err("\(prefix) url must be an absolute https URL of at most \(maxURLBytes) bytes") }
            node.url = url
        case .textField: node.value = try string(raw.value, required: "value")
        case .menu:
            node.label = try string(raw.label, required: "label")
            guard let items = raw.items else { throw err("\(prefix) needs items") }
            guard items.count <= maxMenuItems else { throw err("\(prefix) has more than \(maxMenuItems) items") }
            var itemIDs = Set<String>()
            for item in items {
                guard let itemID = item.id, (1...maxIDBytes).contains(itemID.utf8.count) else {
                    throw err("menu item ids must be 1 to \(maxIDBytes) bytes")
                }
                guard itemIDs.insert(itemID).inserted else { throw err("\(prefix) has duplicate item id \"\(itemID)\"") }
                guard let itemLabel = item.label else { throw err("\(prefix) needs item labels") }
                guard itemLabel.unicodeScalars.count <= maxString else {
                    throw err("menu item label is longer than \(maxString) characters")
                }
                node.items.append(.init(id: itemID, label: itemLabel))
            }
        default: break
        }
        node.placeholder = try string(raw.placeholder)
        node.icon = try string(raw.icon)
        node.multiline = raw.multiline ?? false
        node.disabled = raw.disabled ?? false
        node.clickable = raw.clickable ?? false
        if let align = raw.align, kind == .hstack {
            // Not gated on API 14: older Alas versions ignore the field, so any plugin may send it.
            guard align == "center" || align == "baseline" else { throw err("\(prefix) has unknown align \"\(align)\"") }
            node.centered = align == "center"
        }

        switch kind {
        case .vstack, .hstack, .card:
            guard let children = raw.children else { throw err("\(prefix) needs children") }
            node.children = try children.map { try validate($0, depth: depth + 1, api: api, ids: &ids, count: &count) }
        case .scroll:
            guard raw.axis == "vertical" || raw.axis == "horizontal" else { throw err("\(prefix) needs an axis") }
            guard let child = raw.child else { throw err("\(prefix) needs child") }
            node.horizontal = raw.axis == "horizontal"
            node.children = [try validate(child.raw, depth: depth + 1, api: api, ids: &ids, count: &count)]
        default: break
        }
        return node
    }
}
