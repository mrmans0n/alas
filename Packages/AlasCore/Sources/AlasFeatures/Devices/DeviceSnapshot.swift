import Foundation

/// One element of a simulator screen, with its frame in screen points.
public struct DeviceElement: Equatable, Sendable {
    /// `s<snapshot>e<index>`: valid until the device's next snapshot.
    public let ref: String
    public let role: String
    public let label: String?
    public let value: String?
    public let id: String?
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let enabled: Bool

    public init(
        ref: String, role: String, label: String?, value: String?, id: String?,
        x: Double, y: Double, width: Double, height: Double, enabled: Bool
    ) {
        self.ref = ref
        self.role = role
        self.label = label
        self.value = value
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.enabled = enabled
    }
}

public struct DeviceSnapshotError: Error, Equatable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// A simulator screen's accessibility elements, read from serve-sim's
/// `describeUI` JSON: an array whose first node is the application, whose
/// frame is the screen in points.
public struct DeviceSnapshot: Equatable, Sendable {
    /// Numbers this device's snapshots, so refs from an older one are refused.
    public let generation: Int
    public let screenWidth: Double
    public let screenHeight: Double
    public let elements: [DeviceElement]

    /// Element types worth a ref even without a label.
    private static let interactiveTypes: Set<String> = [
        "Button", "TextField", "SecureTextField", "SearchField", "Switch", "Slider", "Cell", "Link", "Tab",
    ]

    public static func parse(_ json: Data, generation: Int) throws -> DeviceSnapshot {
        guard let nodes = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]],
              let root = nodes.first,
              let screen = frame(of: root), screen.width > 0, screen.height > 0
        else { throw DeviceSnapshotError(message: "The simulator did not describe its screen.") }

        var elements: [DeviceElement] = []
        func visit(_ node: [String: Any]) {
            let type = node["type"] as? String ?? ""
            let label = text(node["AXLabel"])
            let value = text(node["AXValue"])
            let id = text(node["AXUniqueId"])
            if label != nil || value != nil || id != nil || interactiveTypes.contains(type), let frame = frame(of: node) {
                elements.append(DeviceElement(
                    ref: "s\(generation)e\(elements.count + 1)",
                    role: text(node["role_description"]) ?? type.lowercased(),
                    label: label, value: value, id: id,
                    x: frame.x, y: frame.y, width: frame.width, height: frame.height,
                    enabled: node["enabled"] as? Bool ?? true
                ))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { visit(child) }
        }
        // The root application node is the screen itself.
        for child in root["children"] as? [[String: Any]] ?? [] { visit(child) }
        for node in nodes.dropFirst() { visit(node) }
        return DeviceSnapshot(
            generation: generation, screenWidth: screen.width, screenHeight: screen.height, elements: elements
        )
    }

    public func filtered(query: String?, limit: Int) -> (elements: [DeviceElement], truncated: Bool) {
        let matching: [DeviceElement]
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            matching = elements.filter { element in
                [element.role, element.label, element.value, element.id].contains {
                    $0?.range(of: query, options: .caseInsensitive) != nil
                }
            }
        } else {
            matching = elements
        }
        return (Array(matching.prefix(limit)), matching.count > limit)
    }

    public func element(ref: String) -> DeviceElement? {
        elements.first { $0.ref == ref }
    }

    /// The element's center, 0 to 1 across the screen.
    public func center(of element: DeviceElement) -> DeviceScreenPoint {
        DeviceScreenPoint(
            x: min(max((element.x + element.width / 2) / screenWidth, 0), 1),
            y: min(max((element.y + element.height / 2) / screenHeight, 0), 1)
        )
    }

    /// The `device_snapshot` reply.
    public func json(query: String?, limit: Int) -> String {
        let (shown, truncated) = filtered(query: query, limit: limit)
        // Whole points are precise enough to tap, and print without float noise.
        func rounded(_ value: Double) -> Int { Int(value.rounded()) }
        let payload: [String: Any] = [
            "screen": ["width": rounded(screenWidth), "height": rounded(screenHeight)],
            "elements": shown.map { element -> [String: Any] in
                var entry: [String: Any] = [
                    "ref": element.ref,
                    "role": element.role,
                    "frame": [
                        "x": rounded(element.x), "y": rounded(element.y),
                        "width": rounded(element.width), "height": rounded(element.height),
                    ],
                ]
                if let label = element.label { entry["label"] = label }
                if let value = element.value { entry["value"] = value }
                if let id = element.id { entry["id"] = id }
                if !element.enabled { entry["enabled"] = false }
                return entry
            },
            "truncated": truncated,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func frame(of node: [String: Any]) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let frame = node["frame"] as? [String: Any],
              let x = number(frame["x"]), let y = number(frame["y"]),
              let width = number(frame["width"]), let height = number(frame["height"])
        else { return nil }
        return (x, y, width, height)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// A non-blank string, or a number written as one.
    private static func text(_ value: Any?) -> String? {
        let string: String?
        switch value {
        case let value as String: string = value
        case let value as NSNumber: string = value.stringValue
        default: string = nil
        }
        guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }
}
