import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

public struct ACPToolCallPresentation: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case generic
        case webSearch
        case image
        case mcp
        case review
    }

    public let label: String
    public let iconSystemName: String
    public let style: Style

    /// A `visual_show` call: the rule `resolve` labels "Visual aid". The call's
    /// content and raw input carry the visual's HTML.
    public static func isVisualShow(_ toolCall: ACPMessage.ToolCall) -> Bool {
        isVisualShow(name: toolCall.nonEmptyName, title: toolCall.title)
    }

    /// The `toolCallId`s of finished `visual_show` calls whose visual is embedded: the visual flows
    /// straight out of the prose, so their tool chip is not shown. The call does not carry the
    /// presentation, so each visual row is linked to the nearest earlier `visual_show` call in its
    /// turn (stopping at the user message) that no other visual has claimed. Card visuals claim their
    /// call too but keep its chip, as do visuals stored before `presentation` existed (they decode as
    /// cards). A claimed call is hidden only while its latest snapshot here is `completed`, so an
    /// in-flight or failed call keeps its chip. Replayed duplicates of a visual claim nothing.
    public static func hiddenVisualShowToolCallIds(
        in messages: some BidirectionalCollection<ACPMessage>
    ) -> Set<String> {
        var claimed = Set<String>()
        var embeddedCalls = Set<String>()
        var linkedVisuals = Set<UUID>()
        for index in messages.indices {
            guard case .visualAid(let visual) = messages[index],
                  linkedVisuals.insert(visual.id).inserted
            else { continue }
            var cursor = index
            scan: while cursor != messages.startIndex {
                cursor = messages.index(before: cursor)
                switch messages[cursor] {
                case .user:
                    break scan
                case .toolCall(let toolCall)
                    where !claimed.contains(toolCall.toolCallId) && isVisualShow(toolCall):
                    claimed.insert(toolCall.toolCallId)
                    if visual.presentation == .embedded { embeddedCalls.insert(toolCall.toolCallId) }
                    break scan
                default:
                    continue
                }
            }
        }
        guard !embeddedCalls.isEmpty else { return [] }
        var latestStatus: [String: String] = [:]
        for message in messages {
            if case .toolCall(let toolCall) = message, embeddedCalls.contains(toolCall.toolCallId) {
                latestStatus[toolCall.toolCallId] = toolCall.status
            }
        }
        return embeddedCalls.filter { latestStatus[$0] == "completed" }
    }

    /// The same match for fields that arrive outside a `ToolCall`, such as a
    /// permission request's tool call. A stable tool name decides on its own
    /// (any component of it may be the tool). The title is only consulted when
    /// the adapter sent no name, and then only its leading word counts, so an
    /// ordinary call whose title merely mentions `visual_show` (`rg visual_show
    /// Alas/`) is not mistaken for the visual tool.
    public static func isVisualShow(name: String?, title: String?) -> Bool {
        // Every match contains the tool name. Checking that first skips
        // tokenizing long shell-command titles on every transcript update.
        func mentionsTool(_ text: String?) -> Bool {
            text?.range(of: "visual_show", options: .caseInsensitive) != nil
        }
        guard mentionsTool(name) || mentionsTool(title) else { return false }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { return namesVisualShowTool(trimmedName) }
        return titleLeadsWithVisualShowTool(title ?? "")
    }

    private static func isToolNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }

    private static func isToolNameComponent(_ component: Substring) -> Bool {
        component == "visual_show" || component.hasSuffix("__visual_show")
    }

    /// True when a token of `text` is exactly `visual_show` or an MCP-qualified
    /// `…__visual_show`. Tokens split on every character outside `[a-z0-9_]`, so
    /// `alas.visual_show` matches while `visual_showcase` and `visual_show_backup` do not.
    private static func namesVisualShowTool(_ text: String) -> Bool {
        text.lowercased()
            .split(whereSeparator: { !isToolNameCharacter($0) })
            .contains(where: isToolNameComponent)
    }

    /// True when the title's first word is a qualified visual tool name, with
    /// or without trailing call syntax: `alas.visual_show`, `mcp__alas__visual_show`,
    /// `alas.visual_show({…})`. The qualifier may be separated by `.`, `/`, `:` or `-`.
    private static func titleLeadsWithVisualShowTool(_ title: String) -> Bool {
        let word = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .first ?? ""
        let qualified = word.prefix { isToolNameCharacter($0) || ".:/-".contains($0) }
        guard let last = qualified.split(whereSeparator: { ".:/-".contains($0) }).last else { return false }
        return isToolNameComponent(last)
    }

    public static func resolve(_ toolCall: ACPMessage.ToolCall) -> ACPToolCallPresentation {
        let title = toolCall.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = title.lowercased()
        let kind = toolCall.kind?.lowercased()
        let name = toolCall.nonEmptyName

        if kind == "search" {
            if lowerTitle.hasPrefix("web search") {
                return .init(label: "Web Search", iconSystemName: "globe", style: .webSearch)
            }
            if lowerTitle.hasPrefix("open page") {
                return .init(label: "Opened Page", iconSystemName: "safari", style: .webSearch)
            }
            if lowerTitle.hasPrefix("find in page") {
                return .init(label: "Find", iconSystemName: "text.magnifyingglass", style: .webSearch)
            }
        }

        if lowerTitle.hasPrefix("image generation"),
           toolCall.hasImageAsset || rawOutputLooksLikeImageResult(toolCall.rawOutput) {
            return .init(label: "Image", iconSystemName: "photo", style: .image)
        }

        if name == "view_image" || (kind == "read" && toolCall.referencesImage) {
            return .init(label: "Viewed Image", iconSystemName: "photo.on.rectangle", style: .image)
        }

        if isVisualShow(toolCall) {
            return .init(label: "Visual aid", iconSystemName: "rectangle.on.rectangle", style: .mcp)
        }

        if toolCall.isMCPToolCall || name?.hasPrefix("mcp__") == true
            || lowerTitle.hasPrefix("mcp.") || lowerTitle.hasPrefix("mcp__") {
            return .init(
                label: "MCP",
                iconSystemName: "point.3.connected.trianglepath.dotted",
                style: .mcp
            )
        }

        if kind == "think" || lowerTitle == "guardian review" {
            return .init(label: "Review", iconSystemName: "checkmark.shield", style: .review)
        }

        // Stable tool identifiers (ACP 1.22+) take priority over the
        // kind/title heuristics below: they're the SDK/adapter's own tool
        // names and don't drift when a title is reformatted. Adapters that
        // omit `name` (nil here) fall straight through unchanged.
        switch name {
        case "Bash", "exec_command", "write_stdin":
            return .init(label: "Ran", iconSystemName: "terminal", style: .generic)
        case "Edit", "MultiEdit", "Write":
            return .init(label: "Edit", iconSystemName: "pencil", style: .generic)
        case "Read":
            return .init(label: "Read", iconSystemName: "doc.text", style: .generic)
        default:
            break
        }

        switch kind {
        case "read":
            return .init(label: "Read", iconSystemName: "doc.text", style: .generic)
        case "search":
            return .init(label: "Searched", iconSystemName: "magnifyingglass", style: .generic)
        case "execute", "run":
            return .init(label: "Ran", iconSystemName: "terminal", style: .generic)
        case "edit":
            return .init(label: "Edit", iconSystemName: "pencil", style: .generic)
        default:
            return .init(label: toolCall.kind?.capitalized ?? "Tool", iconSystemName: "gearshape", style: .generic)
        }
    }

    /// What a one-line row names after the verb: the title without a
    /// leading copy of the verb, or the first location when the title adds
    /// nothing.
    public static func target(for toolCall: ACPMessage.ToolCall, label: String) -> String? {
        let title = toolCall.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = label.lowercased() + " "
        let stripped = title.lowercased().hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
        let target = stripped.trimmingCharacters(in: .whitespaces)
        if !target.isEmpty, target.lowercased() != label.lowercased() { return target }
        return toolCall.locations.first { !$0.isEmpty }
    }

    private static func rawOutputLooksLikeImageResult(_ rawOutput: String?) -> Bool {
        guard let rawOutput else { return false }
        let lower = rawOutput.lowercased()
        return lower.contains("\"type\":\"image\"")
            || lower.contains("\"type\": \"image\"")
            || lower.contains("\"mimetype\":\"image/")
            || lower.contains("\"mimetype\": \"image/")
            || lower.contains("\"mime_type\":\"image/")
            || lower.contains("\"mime_type\": \"image/")
            || lower.contains("\"b64_json\"")
            || lower.contains("\"revised_prompt\"")
            || lower.contains("data:image/")
    }

    public init(label: String, iconSystemName: String, style: Style) {
        self.label = label
        self.iconSystemName = iconSystemName
        self.style = style
    }
}

private extension ACPMessage.ToolCall {
    var hasImageAsset: Bool {
        assets.contains { $0.isImageReference }
    }

    var referencesImage: Bool {
        hasImageAsset
            || imagePath(title)
            || locations.contains(where: imagePath)
    }

    var isMCPToolCall: Bool {
        guard let root = metadataObject(metadata) else { return false }
        return boolValue(root["is_mcp_tool_call"]) == true
    }
}

private extension ACPMessage.ToolCallAsset {
    var isImageReference: Bool {
        kind == .image
            || mimeType?.lowercased().hasPrefix("image/") == true
            || uri.map(imagePath) == true
            || name.map(imagePath) == true
    }
}
