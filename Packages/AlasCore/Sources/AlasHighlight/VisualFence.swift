import Foundation

/// A ```` ```visual ```` fence: HTML the transcript draws inline as an embedded
/// visual aid, the markdown counterpart of `visual_show`. Words after the tag
/// are the visual's title (```` ```visual Auth flow ````). Plain `html` and `svg`
/// fences stay code, because agents use them to show source they are editing.
///
/// A ```` ```chart ```` fence draws a chart natively: its body is `<alas-chart>`'s JSON data, and words
/// after the tag pick the type and set the other options (```` ```chart line unit=ms label="Build time" ````).
/// See `ChartSpec`.
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

    /// The HTML a closed ```` ```visual ```` fence draws, or nil for an empty body or any other fence.
    /// A chart fence draws natively instead; see `ChartSpec`.
    public static func html(language: String?, code: String) -> String? {
        guard firstWord(language) == tag, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return code
    }

    static let chartTypes: Set = ["bar", "hbar", "line"]

    static func firstWord(_ language: String?) -> String? {
        language?.split(whereSeparator: \.isWhitespace).first?.lowercased()
    }

    /// A bare chart type, and `key=value` or `key="quoted value"` pairs. Anything else is ignored.
    static func chartOptions(_ text: String) -> (type: String?, attributes: [String: String]) {
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
}
