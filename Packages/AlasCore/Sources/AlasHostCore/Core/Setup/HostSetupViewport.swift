import Foundation

/// What of a setup screen fits the terminal: a long list scrolls and a wide
/// row is cut, so a small SSH window still shows the selection.
public enum HostSetupViewport {
    /// The rows of `count` that `height` lines show: all of them when they
    /// fit, otherwise a window centred on `selected` where the list allows.
    public static func visibleRows(count: Int, selected: Int, height: Int) -> Range<Int> {
        let height = max(height, 1)
        guard count > height else { return 0 ..< count }
        let start = min(max(selected - height / 2, 0), count - height)
        return start ..< start + height
    }

    /// `row` cut to `width` characters, ending in an ellipsis when cut.
    public static func fit(_ row: String, width: Int) -> String {
        guard row.count > width else { return row }
        return String(row.prefix(max(width - 1, 0))) + "…"
    }
}
