import Foundation

/// Whether text set through Accessibility went in. Some apps (Chromium, Electron) report success
/// for an insert and change nothing, so the value is read back before the input counts as typed.
public enum ComputerUseTextCheck {
    public enum Verdict: Equatable, Sendable {
        /// The value changed: what went in may differ from the text (a field that formats it), but
        /// typing it again would put it in twice.
        case landed
        /// The value is as it was: nothing went in, so the text may be typed instead.
        case unchanged
        /// The value couldn't be read before or after.
        case unknown
    }

    /// An insert of `inserted` over `selection` (UTF-16 location and length, nil when unreadable).
    public static func insert(
        _ inserted: String, before: String?, selection: (location: Int, length: Int)?, after: String?
    ) -> Verdict {
        guard let before, let after else { return .unknown }
        if inserted.isEmpty || after != before { return .landed }
        // Text put over a selection of the very same text leaves the value as it was.
        if let selection, selectedText(before, selection) == inserted { return .landed }
        return .unchanged
    }

    /// A replace of the whole value with `text`.
    public static func replace(with text: String, before: String?, after: String?) -> Verdict {
        guard let after else { return .unknown }
        if after == text { return .landed }
        guard let before else { return .unknown }
        return after == before ? .unchanged : .landed
    }

    private static func selectedText(_ value: String, _ selection: (location: Int, length: Int)) -> String? {
        let utf16 = value.utf16
        guard selection.location >= 0, selection.length >= 0, selection.location + selection.length <= utf16.count,
              let start = utf16.index(utf16.startIndex, offsetBy: selection.location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: selection.length, limitedBy: utf16.endIndex)
        else { return nil }
        return String(utf16[start ..< end])
    }
}
