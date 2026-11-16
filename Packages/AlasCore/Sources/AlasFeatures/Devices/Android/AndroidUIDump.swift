import Foundation

/// `uiautomator dump` XML as a `DeviceSnapshot`, frames in dp.
public enum AndroidUIDump {
    /// `displaySize` is the display's natural size in pixels (`wm size`); the
    /// dump's rotation turns it. Without it the first node's bounds stand in,
    /// which is only the display when no dialog or inset window is on top.
    public static func parse(
        _ xml: Data, density: Double, displaySize: (width: Double, height: Double)? = nil, generation: Int
    ) throws -> DeviceSnapshot {
        // A scan, not XMLParser: Linux keeps that in FoundationXML, and the dump is flat.
        let text = String(decoding: xml, as: UTF8.self)
        let nodes = nodeAttributes(text)
        guard let root = nodes.first, let rootBounds = bounds(root["bounds"]) else {
            throw DeviceSnapshotError(message: "The device did not describe its screen.")
        }
        let screen: CGRectLike
        if let displaySize {
            let turned = (rotation(text) ?? 0) % 2 == 1
            screen = CGRectLike(
                minX: 0, minY: 0,
                width: turned ? displaySize.height : displaySize.width, height: turned ? displaySize.width : displaySize.height
            )
        } else {
            screen = rootBounds
        }
        let dp = 160 / max(density, 1)
        var elements: [DeviceElement] = []
        for node in nodes.dropFirst() {
            guard let frame = bounds(node["bounds"]), frame.width > 0, frame.height > 0 else { continue }
            let password = node["password"] == "true"
            let label = nonEmpty(password ? nil : node["text"]) ?? nonEmpty(node["content-desc"])
            let id = nonEmpty(node["resource-id"])
            let isControl = node["clickable"] == "true" || node["checkable"] == "true"
                || (node["class"] ?? "").hasSuffix("EditText")
            // Android gives containers ids too, so an id alone doesn't make an element worth a ref.
            guard label != nil || isControl else { continue }
            elements.append(DeviceElement(
                ref: "s\(generation)e\(elements.count + 1)", role: role(ofClass: node["class"] ?? ""),
                label: label, value: nil, id: id,
                x: frame.minX * dp, y: frame.minY * dp, width: frame.width * dp, height: frame.height * dp,
                enabled: node["enabled"] != "false", isControl: isControl
            ))
        }
        return DeviceSnapshot(
            generation: generation, screenWidth: screen.width * dp, screenHeight: screen.height * dp, elements: elements
        )
    }

    /// `android.widget.ImageButton` → "image button".
    public static func role(ofClass name: String) -> String {
        let last = name.split(separator: ".").last.map(String.init) ?? name
        var words = ""
        for character in last {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(Character(character.lowercased()))
        }
        return words.isEmpty ? "view" : words
    }

    /// `[x1,y1][x2,y2]`; anything else isn't a frame.
    static func bounds(_ text: String?) -> CGRectLike? {
        guard let text else { return nil }
        let parts = text.split(whereSeparator: { "[],".contains($0) })
        let numbers = parts.compactMap { Double($0) }
        guard parts.count == 4, numbers.count == 4 else { return nil }
        return CGRectLike(minX: numbers[0], minY: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }

    /// `<hierarchy rotation="1">`'s quarter turns.
    static func rotation(_ xml: String) -> Int? {
        guard let start = xml.range(of: "<hierarchy "),
              let end = xml[start.upperBound...].firstIndex(of: ">") else { return nil }
        return attributes(xml[start.upperBound..<end])["rotation"].flatMap { Int($0) }
    }

    /// The display's size from `wm size`: "Override size" when set, else "Physical size".
    public static func displaySize(_ output: String) -> (width: Double, height: Double)? {
        func size(_ label: String) -> (width: Double, height: Double)? {
            guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(label) }) else { return nil }
            let parts = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        return size("Override size:") ?? size("Physical size:")
    }

    /// Each `<node …>` tag's attributes, in document order.
    static func nodeAttributes(_ xml: String) -> [[String: String]] {
        var nodes: [[String: String]] = []
        var rest = xml[...]
        while let open = rest.range(of: "<node ") {
            guard let close = rest[open.upperBound...].firstIndex(of: ">") else { break }
            nodes.append(attributes(rest[open.upperBound..<close]))
            rest = rest[close...]
        }
        return nodes
    }

    /// `name="value"` pairs; values are quoted with `"`, as uiautomator writes them.
    private static func attributes(_ tag: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = tag
        while let equals = rest.range(of: "=\"") {
            let name = rest[..<equals.lowerBound].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            guard let end = rest[equals.upperBound...].firstIndex(of: "\"") else { break }
            result[name] = decodeEntities(rest[equals.upperBound..<end])
            rest = rest[rest.index(after: end)...]
        }
        return result
    }

    static func decodeEntities(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        var out = ""
        var rest = text
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";") else { break }
            let entity = rest[rest.index(after: amp)..<semi]
            switch entity {
            case "amp": out += "&"
            case "lt": out += "<"
            case "gt": out += ">"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                let code = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16)
                    : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
                if let code, let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) } else { out += "&\(entity);" }
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    struct CGRectLike {
        let minX, minY, width, height: Double
    }
}
