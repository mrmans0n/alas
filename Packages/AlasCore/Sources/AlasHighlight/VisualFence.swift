/// A ```` ```visual ```` fence: HTML the transcript draws inline as an embedded
/// visual aid, the markdown counterpart of `visual_show`. Words after the tag
/// are the visual's title (```` ```visual Auth flow ````). Plain `html` and `svg`
/// fences stay code, because agents use them to show source they are editing.
public enum VisualFence: Sendable {
    public static let tag = "visual"

    public static func isVisual(language: String?) -> Bool {
        language?
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased() == tag
    }

    /// The title after the tag, or nil when the fence has none.
    public static func title(language: String?) -> String? {
        guard let language, isVisual(language: language) else { return nil }
        let rest = language.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}
