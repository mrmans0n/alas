import AppKit
import SwiftUI

extension MarkdownCodeBlockStyle {
    /// The standard code box for editable surfaces. Colours mirror the
    /// transcript's rendered code block (`ACPMarkdownText.swift:574-576`) so an
    /// in-progress box matches the block it becomes once submitted.
    static func standard(
        theme: Theme,
        baseFont: NSFont,
        baseColor: NSColor,
        monoSize: CGFloat
    ) -> MarkdownCodeBlockStyle {
        MarkdownCodeBlockStyle(
            baseFont: baseFont,
            baseColor: baseColor,
            monoFont: .monospacedSystemFont(ofSize: monoSize, weight: .regular),
            bodyColor: baseColor,
            fenceColor: NSColor(theme.color("fg-dim")),
            backgroundColor: NSColor(theme.color("bg-0")).withAlphaComponent(0.6),
            borderColor: NSColor(theme.color("line"))
        )
    }
}
