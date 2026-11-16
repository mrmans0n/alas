import Foundation

/// `uiautomator dump` XML as a `DeviceSnapshot`, frames in dp.
public enum AndroidUIDump {
    public static func parse(_ xml: Data, density: Double, generation: Int) throws -> DeviceSnapshot {
        // `uiautomator dump /dev/tty` prints a line after the document.
        var data = xml
        if let end = data.range(of: Data("</hierarchy>".utf8)) { data = data.prefix(upTo: end.upperBound) }
        let collector = NodeCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), let root = collector.nodes.first, let screen = bounds(root["bounds"]) else {
            throw DeviceSnapshotError(message: "The device did not describe its screen.")
        }
        let dp = 160 / max(density, 1)
        var elements: [DeviceElement] = []
        for node in collector.nodes.dropFirst() {
            guard let frame = bounds(node["bounds"]), frame.width > 0, frame.height > 0 else { continue }
            let password = node["password"] == "true"
            let label = nonEmpty(password ? nil : node["text"]) ?? nonEmpty(node["content-desc"])
            let id = nonEmpty(node["resource-id"])
            let isControl = node["clickable"] == "true" || node["checkable"] == "true"
                || (node["class"] ?? "").hasSuffix("EditText")
            guard label != nil || id != nil || isControl else { continue }
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

    /// `[x1,y1][x2,y2]`.
    static func bounds(_ text: String?) -> CGRectLike? {
        guard let text else { return nil }
        let numbers = text.split(whereSeparator: { "[],".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRectLike(minX: numbers[0], minY: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    struct CGRectLike {
        let minX, minY, width, height: Double
    }

    private final class NodeCollector: NSObject, XMLParserDelegate {
        var nodes: [[String: String]] = []

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            if name == "node" { nodes.append(attributes) }
        }
    }
}
