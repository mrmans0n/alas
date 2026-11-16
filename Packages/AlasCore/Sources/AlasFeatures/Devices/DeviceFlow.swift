import Foundation

public struct DeviceFlowError: Error, Equatable, LocalizedError {
    /// The line in the flow file, from 1.
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var errorDescription: String? { "Line \(line): \(message)" }
}

/// A flow: steps on a device in the subset of Maestro's YAML that Alas reads,
/// writes and runs itself. Steps name elements by text or id, so a flow
/// survives layout changes and runs on any simulator or Android device.
public struct DeviceFlow: Equatable, Sendable {
    public enum Selector: Equatable, Sendable {
        case text(String)
        case id(String)
        /// 0…1 across each axis of the upright screen.
        case point(x: Double, y: Double)
    }

    public enum Key: String, CaseIterable, Sendable {
        case home = "Home", back = "Back", enter = "Enter"
    }

    public enum Direction: String, CaseIterable, Sendable {
        case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT"
    }

    public enum Step: Equatable, Sendable {
        /// The flow's `appId` when nil.
        case launchApp(String?)
        case tapOn(Selector)
        case inputText(String)
        case pressKey(Key)
        /// Scrolls the content down: a swipe up.
        case scroll
        case swipe(Direction)
        case assertVisible(Selector)
        case assertNotVisible(Selector)
        case openLink(String)
        case waitForAnimationToEnd
    }

    public var appID: String?
    public var steps: [Step]
    /// Each step's line in the file it was read from; empty for a flow built in code.
    public var lines: [Int]

    public init(appID: String?, steps: [Step], lines: [Int] = []) {
        self.appID = appID
        self.steps = steps
        self.lines = lines
    }

    private static let commands = [
        "launchApp", "tapOn", "inputText", "pressKey", "scroll", "swipe", "assertVisible", "assertNotVisible",
        "openLink", "waitForAnimationToEnd",
    ]

    // MARK: Reading

    public static func parse(_ yaml: String) throws(DeviceFlowError) -> DeviceFlow {
        let lines = yaml.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        let separator = lines.firstIndex { stripComment($0).trimmingCharacters(in: .whitespaces) == "---" }
        var appID: String?
        for (index, raw) in lines.enumerated() where separator.map({ index < $0 }) ?? false {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (key, value) = try keyValue(line, line: index + 1)
            if key == "appId" { appID = value }
        }
        var steps: [Step] = []
        var stepLines: [Int] = []
        var index = separator.map { $0 + 1 } ?? 0
        while index < lines.count {
            let raw = stripComment(lines[index])
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                index += 1
                continue
            }
            guard trimmed.hasPrefix("- ") || trimmed == "-" else {
                throw DeviceFlowError(line: index + 1, message: "Expected a command, such as \"- tapOn: Save\".")
            }
            let indent = raw.prefix { $0 == " " }.count
            let command = String(trimmed.dropFirst(trimmed == "-" ? 1 : 2)).trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1
            var name = command
            var scalar: String?
            // The command's own `key: value` pairs: inline in braces, or on lines indented under it.
            var map: [String: (value: String, line: Int)] = [:]
            if let colon = command.firstIndex(of: ":") {
                name = String(command[..<colon]).trimmingCharacters(in: .whitespaces)
                let rest = String(command[command.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("{") {
                    guard rest.hasSuffix("}") else {
                        throw DeviceFlowError(line: lineNumber, message: "A { map } isn't closed on its line.")
                    }
                    for pair in splitOutsideQuotes(String(rest.dropFirst().dropLast()), on: ",") {
                        let trimmed = pair.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        let (key, entry) = try keyValue(trimmed, line: lineNumber)
                        map[key] = (entry, lineNumber)
                    }
                } else if !rest.isEmpty {
                    scalar = try value(rest, line: lineNumber)
                }
            }
            index += 1
            while index < lines.count {
                let next = stripComment(lines[index])
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty {
                    index += 1
                    continue
                }
                guard next.prefix(while: { $0 == " " }).count > indent, !nextTrimmed.hasPrefix("- ") else { break }
                let (key, entry) = try keyValue(nextTrimmed, line: index + 1)
                map[key] = (entry, index + 1)
                index += 1
            }
            steps.append(try step(name, scalar: scalar, map: map, line: lineNumber))
            stepLines.append(lineNumber)
        }
        return DeviceFlow(appID: appID, steps: steps, lines: stepLines)
    }

    private static func step(
        _ name: String, scalar: String?, map: [String: (value: String, line: Int)], line: Int
    ) throws(DeviceFlowError) -> Step {
        func required(_ what: String) throws(DeviceFlowError) -> String {
            guard let scalar else { throw DeviceFlowError(line: line, message: "\(name) needs \(what).") }
            return scalar
        }
        func selector() throws(DeviceFlowError) -> Selector {
            if let scalar { return .text(scalar) }
            // An id is the more specific of the two.
            if let id = map["id"] { return .id(id.value) }
            if let text = map["text"] { return .text(text.value) }
            if let point = map["point"] { return try parsePoint(point.value, line: point.line) }
            throw DeviceFlowError(line: line, message: "\(name) needs text, an id or a point.")
        }
        switch name {
        case "launchApp": return .launchApp(scalar ?? map["appId"]?.value)
        case "tapOn": return .tapOn(try selector())
        case "inputText": return .inputText(try required("the text to type"))
        case "pressKey":
            let key = try required("a key: Home, Back or Enter")
            guard let found = Key.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw DeviceFlowError(line: line, message: "pressKey takes Home, Back or Enter, not \(key).")
            }
            return .pressKey(found)
        case "scroll": return .scroll
        case "swipe":
            let direction = scalar ?? map["direction"]?.value ?? ""
            guard let found = Direction(rawValue: direction.uppercased()) else {
                throw DeviceFlowError(line: line, message: "swipe takes a direction: UP, DOWN, LEFT or RIGHT, not \(direction).")
            }
            return .swipe(found)
        case "assertVisible": return .assertVisible(try selector())
        case "assertNotVisible": return .assertNotVisible(try selector())
        case "openLink": return .openLink(try required("a URL"))
        case "waitForAnimationToEnd": return .waitForAnimationToEnd
        default:
            throw DeviceFlowError(
                line: line,
                message: "Alas doesn't run \(name); flows use \(commands.joined(separator: ", "))."
            )
        }
    }

    /// `"50%,80%"`.
    private static func parsePoint(_ text: String, line: Int) throws(DeviceFlowError) -> Selector {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap { part in part.hasSuffix("%") ? Double(part.dropLast()) : nil }
        guard parts.count == 2, values.count == 2, values.allSatisfy({ (0...100).contains($0) }) else {
            throw DeviceFlowError(line: line, message: "point must look like \"50%,80%\", not \(text).")
        }
        return .point(x: values[0] / 100, y: values[1] / 100)
    }

    private static func keyValue(_ line: String, line number: Int) throws(DeviceFlowError) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else {
            throw DeviceFlowError(line: number, message: "Expected \"key: value\".")
        }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        return (key, try value(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces), line: number))
    }

    /// `text` split at each `separator` outside double quotes.
    private static func splitOutsideQuotes(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
            } else if character == "\\", inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == separator, !inQuotes {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }

    /// A bare value, or one in double quotes with `\"`, `\\`, `\n`, `\r` and `\t` escapes.
    private static func value(_ text: String, line: Int) throws(DeviceFlowError) -> String {
        guard text.hasPrefix("\"") else { return text }
        var out = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                switch character {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return out
            } else {
                out.append(character)
            }
        }
        throw DeviceFlowError(line: line, message: "A quoted value isn't closed.")
    }

    /// Drops a `#` comment that starts a line or follows a space, outside quotes.
    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var escaped = false
        var previous: Character = " "
        for (offset, character) in line.enumerated() {
            if escaped {
                escaped = false
            } else if character == "\\", inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == "#", !inQuotes, previous == " " {
                return String(line.prefix(offset))
            }
            previous = character
        }
        return line
    }

    // MARK: Writing

    /// The flow as YAML this reader, and the Maestro CLI, read back.
    public var yaml: String {
        var out = ""
        if let appID { out += "appId: \(Self.quote(appID))\n" }
        out += "---\n"
        for step in steps { out += Self.line(step) + "\n" }
        return out
    }

    private static func line(_ step: Step) -> String {
        func selector(_ name: String, _ selector: Selector) -> String {
            switch selector {
            case .text(let text): "- \(name): \(quote(text))"
            case .id(let id): "- \(name):\n    id: \(quote(id))"
            case .point(let x, let y): "- \(name):\n    point: \"\(Int((x * 100).rounded()))%,\(Int((y * 100).rounded()))%\""
            }
        }
        return switch step {
        case .launchApp(nil): "- launchApp"
        case .launchApp(let id?): "- launchApp:\n    appId: \(quote(id))"
        case .tapOn(let target): selector("tapOn", target)
        case .inputText(let text): "- inputText: \(quote(text))"
        case .pressKey(let key): "- pressKey: \(key.rawValue)"
        case .scroll: "- scroll"
        case .swipe(let direction): "- swipe:\n    direction: \(direction.rawValue)"
        case .assertVisible(let target): selector("assertVisible", target)
        case .assertNotVisible(let target): selector("assertNotVisible", target)
        case .openLink(let url): "- openLink: \(quote(url))"
        case .waitForAnimationToEnd: "- waitForAnimationToEnd"
        }
    }

    /// In double quotes, with the escapes `value` reads, so a value never spans lines.
    private static func quote(_ text: String) -> String {
        var out = "\""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\r\n": out += "\\r\\n"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out + "\""
    }

    // MARK: Elements

    /// The element a selector names: an exact (case-insensitive) label on a
    /// control, then on any element, then a label that contains the text; or
    /// the id. Points name no element.
    public static func find(_ selector: Selector, in snapshot: DeviceSnapshot) -> DeviceElement? {
        switch selector {
        case .text(let text):
            let exact = snapshot.elements.filter { $0.label?.caseInsensitiveCompare(text) == .orderedSame }
            return exact.first(where: \.isControl) ?? exact.first
                ?? snapshot.elements.first { $0.label?.localizedCaseInsensitiveContains(text) == true }
        case .id(let id):
            return snapshot.elements.first { $0.id == id }
        case .point:
            return nil
        }
    }

    /// How a recording names a drag from `from` to `to` (0…1 of the upright
    /// screen): nil for one shorter than 5% of the screen, a tap; otherwise a
    /// swipe along its longer axis.
    public static func swipeDirection(from: DeviceScreenPoint, to: DeviceScreenPoint) -> Direction? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        guard (dx * dx + dy * dy).squareRoot() >= 0.05 else { return nil }
        return abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
    }

    /// How a recording names a wheel or trackpad scroll from its summed Mac
    /// deltas: the content moves the way the deltas point, as under a finger
    /// swiping that way. Nil for less than a point.
    public static func scrollDirection(dx: Double, dy: Double) -> Direction? {
        guard abs(dx) >= 1 || abs(dy) >= 1 else { return nil }
        return abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
    }

    /// The smallest element with a label or id under `point` (0…1 of the upright screen), for recording a tap.
    public static func element(at point: DeviceScreenPoint, in snapshot: DeviceSnapshot) -> DeviceElement? {
        let x = point.x * snapshot.screenWidth
        let y = point.y * snapshot.screenHeight
        return snapshot.elements
            .filter { ($0.label != nil || $0.id != nil) && $0.x <= x && x <= $0.x + $0.width && $0.y <= y && y <= $0.y + $0.height }
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    /// How a recording names what was tapped: its label, else its id, else the
    /// point in whole percents.
    public static func selector(for element: DeviceElement?, at point: DeviceScreenPoint) -> Selector {
        if let label = element?.label { return .text(label) }
        if let id = element?.id { return .id(id) }
        return .point(x: (point.x * 100).rounded() / 100, y: (point.y * 100).rounded() / 100)
    }
}
