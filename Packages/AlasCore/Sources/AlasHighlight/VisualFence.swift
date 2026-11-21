import Foundation

/// A ```` ```visual ```` fence: HTML the transcript draws inline as an embedded
/// visual aid, the markdown counterpart of `visual_show`. Words after the tag
/// are the visual's title (```` ```visual Auth flow ````). Plain `html` and `svg`
/// fences stay code, because agents use them to show source they are editing.
///
/// A ```` ```chart ```` fence is shorthand for a visual holding one `<alas-chart>`: its body is the
/// chart's JSON data, and words after the tag pick the type and set the other attributes
/// (```` ```chart line unit=ms label="Build time" ````).
public enum VisualFence: Sendable {
    public static let tag = "visual"
    public static let chartTag = "chart"

    public static func isVisual(language: String?) -> Bool {
        guard let first = firstWord(language) else { return false }
        return first == tag || first == chartTag
    }

    /// The title after the tag, or nil when the fence has none. A chart's is its `label`, else "Chart".
    public static func title(language: String?) -> String? {
        guard let language, isVisual(language: language) else { return nil }
        let rest = language.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces)
        if firstWord(language) == chartTag { return chartOptions(rest).attributes["label"] ?? "Chart" }
        return rest.isEmpty ? nil : rest
    }

    /// The HTML a closed fence draws, or nil when it draws none: not a visual fence, an empty body,
    /// or a chart whose body is not a JSON object, which stays code so the data is still readable.
    public static func html(language: String?, code: String) -> String? {
        guard let language, isVisual(language: language),
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard firstWord(language) == chartTag else { return code }
        guard (try? JSONSerialization.jsonObject(with: Data(code.utf8))) is [String: Any] else { return nil }
        let options = chartOptions(language.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces))
        var attributes = [("type", options.type ?? "bar")]
        for key in ["unit", "height", "label"] {
            if let value = options.attributes[key] { attributes.append((key, value)) }
        }
        attributes.append(("data", code.trimmingCharacters(in: .whitespacesAndNewlines)))
        let rendered = attributes.map { "\($0.0)=\"\(escaped($0.1))\"" }.joined(separator: " ")
        return "<alas-chart \(rendered)></alas-chart>"
    }

    private static let chartTypes: Set = ["bar", "hbar", "line"]

    private static func firstWord(_ language: String?) -> String? {
        language?.split(whereSeparator: \.isWhitespace).first?.lowercased()
    }

    /// A bare chart type, and `key=value` or `key="quoted value"` pairs. Anything else is ignored.
    private static func chartOptions(_ text: String) -> (type: String?, attributes: [String: String]) {
        var type: String?
        var attributes: [String: String] = [:]
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0.isWhitespace }
            guard !rest.isEmpty else { break }
            let key = rest.prefix { !$0.isWhitespace && $0 != "=" }
            rest = rest.dropFirst(key.count)
            guard rest.first == "=" else {
                if chartTypes.contains(key.lowercased()) { type = key.lowercased() }
                continue
            }
            rest = rest.dropFirst()
            let value: Substring
            if rest.first == "\"" {
                rest = rest.dropFirst()
                value = rest.prefix { $0 != "\"" }
                rest = rest.dropFirst(value.count).dropFirst()
            } else {
                value = rest.prefix { !$0.isWhitespace }
                rest = rest.dropFirst(value.count)
            }
            attributes[key.lowercased()] = String(value)
        }
        return (type, attributes)
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
