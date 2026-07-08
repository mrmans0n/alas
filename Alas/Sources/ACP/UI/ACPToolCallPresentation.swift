import Foundation

struct ACPToolCallPresentation: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case generic
        case webSearch
        case image
        case mcp
        case review
    }

    let label: String
    let iconSystemName: String
    let style: Style

    static func resolve(_ toolCall: ACPMessage.ToolCall) -> ACPToolCallPresentation {
        let title = toolCall.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = title.lowercased()
        let kind = toolCall.kind?.lowercased()

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

        if kind == "read", toolCall.referencesImage {
            return .init(label: "Viewed Image", iconSystemName: "photo.on.rectangle", style: .image)
        }

        if toolCall.isMCPToolCall || lowerTitle.hasPrefix("mcp.") || lowerTitle.hasPrefix("mcp__") {
            return .init(
                label: "MCP",
                iconSystemName: "point.3.connected.trianglepath.dotted",
                style: .mcp
            )
        }

        if kind == "think" || lowerTitle == "guardian review" {
            return .init(label: "Review", iconSystemName: "checkmark.shield", style: .review)
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

private func metadataObject(_ value: AnyCodable?) -> [String: AnyCodable]? {
    if let dict = value?.value as? [String: AnyCodable] { return dict }
    if let dict = value?.value as? [String: Any] {
        return dict.mapValues { raw in
            (raw as? AnyCodable) ?? AnyCodable(raw)
        }
    }
    if let dict = value?.value as? NSDictionary {
        var result: [String: AnyCodable] = [:]
        for (rawKey, rawValue) in dict {
            guard let key = rawKey as? String else { continue }
            result[key] = (rawValue as? AnyCodable) ?? AnyCodable(rawValue)
        }
        return result
    }
    return nil
}

private func boolValue(_ value: AnyCodable?) -> Bool? {
    guard let raw = value?.value, !(raw is NSNull) else { return nil }
    if let bool = raw as? Bool { return bool }
    if let string = raw as? String {
        switch string.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
    return nil
}

private func imagePath(_ value: String) -> Bool {
    let lower = value.lowercased()
    return [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif", ".tiff", ".bmp"].contains {
        lower.hasSuffix($0) || lower.contains("\($0)?")
    }
}
