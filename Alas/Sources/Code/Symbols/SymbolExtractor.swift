import Foundation
import SwiftTreeSitter

/// Turns one source file into its declarations using the language's tags
/// query. Pure and synchronous; callers choose the thread.
enum SymbolExtractor {
    /// Node types that end a declaration when walking up from a name.
    private static let declarationSuffixes = ["_declaration", "_definition", "_item", "_spec", "_signature", "_declarator"]
    /// Wrappers between a name and its real declaration (Kotlin
    /// `variable_declaration` inside `property_declaration`, JS declarators).
    private static let passThroughTypes: Set<String> = ["variable_declaration", "multi_variable_declaration", "variable_declarator"]
    /// Ancestors whose name becomes a member's container.
    private static let containerTypes: Set<String> = [
        "class_declaration", "protocol_declaration", "class_definition", "interface_declaration",
        "enum_declaration", "object_declaration", "record_declaration", "abstract_class_declaration",
        "struct_item", "enum_item", "trait_item", "impl_item", "mod_item", "internal_module", "module", "class",
    ]
    private static let javaScriptCallables: Set<String> = [
        "function_declaration", "function_expression", "arrow_function", "method_definition",
        "generator_function", "generator_function_declaration", "class_static_block",
    ]
    /// Ancestor node types that make a declaration local, per language: the
    /// bodies of functions, methods, initializers, closures, and accessors.
    /// Upstream tags queries match declarations at any depth, so a `let`
    /// inside a method would otherwise be indexed as a member. Python and
    /// JavaScript list the callables themselves because their body types
    /// (`block`, `statement_block`) also hold class and namespace bodies.
    private static let localScopeTypes: [String: Set<String>] = [
        "swift": ["function_body", "computed_property", "willset_didset_block", "lambda_literal"],
        "javascript": javaScriptCallables,
        "typescript": javaScriptCallables,
        "tsx": javaScriptCallables,
        "python": ["function_definition", "lambda"],
        "go": ["block"],
        "rust": ["block", "closure_expression"],
        "java": ["block", "constructor_body", "lambda_expression"],
        "kotlin": ["function_body", "block", "lambda_literal"],
    ]

    static func symbols(in source: String, relativePath: String) -> [SymbolEntry] {
        guard !source.isEmpty,
              let tags = LanguageRegistry.tagsQuery(forPath: relativePath) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(tags.language)) != nil,
              let tree = parser.parse(source),
              let root = tree.rootNode else { return [] }
        let text = source as NSString
        let localScopes = localScopeTypes[tags.languageID] ?? []
        var seen = Set<NSRange>()
        var result: [SymbolEntry] = []
        let matches = tags.query.execute(node: root, in: tree).resolve(with: .init(string: source))
        for match in matches {
            guard let nameCapture = match.captures.first(where: { $0.nameComponents == ["name"] }),
                  let definition = match.captures.first(where: { $0.nameComponents.first == "definition" }),
                  definition.nameComponents.count >= 2,
                  var kind = SymbolKind(tag: definition.nameComponents[1]) else { continue }
            let nameNode = nameCapture.node
            guard nameNode.range.length > 0, seen.insert(nameNode.range).inserted else { continue }
            let declaration = declarationNode(from: nameNode, limit: definition.node)
            if isLocal(declaration, scopes: localScopes) { continue }
            if declaration.nodeType == "class_declaration", tags.languageID == "swift" {
                switch declaration.child(byFieldName: "declaration_kind").map({ text.substring(with: $0.range) }) {
                case "struct": kind = .struct
                case "enum": kind = .enum
                case "extension": continue
                default: break
                }
            }
            let container = containerName(of: declaration, text: text)
            if kind == .function, container != nil { kind = .method }
            result.append(SymbolEntry(
                name: text.substring(with: nameNode.range),
                kind: kind,
                container: container,
                languageID: tags.languageID,
                relativePath: relativePath,
                nameRange: nameNode.range,
                lineRange: lineRange(of: declaration)
            ))
        }
        return result.sorted { $0.nameRange.location < $1.nameRange.location }
    }

    private static func isDeclaration(_ node: Node) -> Bool {
        guard let type = node.nodeType, !passThroughTypes.contains(type) else { return false }
        return declarationSuffixes.contains { type.hasSuffix($0) }
    }

    private static func isLocal(_ declaration: Node, scopes: Set<String>) -> Bool {
        var current = declaration.parent
        while let node = current {
            if let type = node.nodeType, scopes.contains(type) { return true }
            current = node.parent
        }
        return false
    }

    /// Nearest declaration above the name, never past the captured
    /// definition node. Swift tags capture a method's whole class as the
    /// definition, so the walk must stop at the first declaration instead.
    /// Decorator wrappers (Python `decorated_definition`) are then included:
    /// `@property` or a route decorator is part of the declaration.
    private static func declarationNode(from name: Node, limit: Node) -> Node {
        var current = name.parent
        var found = limit
        while let node = current {
            if isDeclaration(node) || node.range == limit.range {
                found = node
                break
            }
            current = node.parent
        }
        while let parent = found.parent, parent.nodeType == "decorated_definition" { found = parent }
        return found
    }

    private static func containerName(of declaration: Node, text: NSString) -> String? {
        // Go methods name their type in the receiver, `func (s *Server) Start()`.
        if declaration.nodeType == "method_declaration",
           let receiver = declaration.child(byFieldName: "receiver"),
           let type = firstDescendant(of: receiver, type: "type_identifier") {
            return text.substring(with: type.range)
        }
        var current = declaration.parent
        while let node = current {
            if let type = node.nodeType, containerTypes.contains(type),
               let nameNode = node.child(byFieldName: "name") ?? node.child(byFieldName: "type") {
                return text.substring(with: nameNode.range)
            }
            current = node.parent
        }
        return nil
    }

    private static func firstDescendant(of node: Node, type: String) -> Node? {
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if child.nodeType == type { return child }
            if let found = firstDescendant(of: child, type: type) { return found }
        }
        return nil
    }

    private static func lineRange(of node: Node) -> ClosedRange<Int> {
        let start = Int(node.pointRange.lowerBound.row)
        var end = Int(node.pointRange.upperBound.row)
        if node.pointRange.upperBound.column == 0, end > start { end -= 1 }
        return start...end
    }
}
