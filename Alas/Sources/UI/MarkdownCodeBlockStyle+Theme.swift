import AppKit
import SwiftUI

extension MarkdownCodeBlockStyle {
    /// The standard code box for editable surfaces. Colours mirror the
    /// transcript's rendered code block (`ACPMarkdownText.swift:574-576`) so an
    /// in-progress box matches the block it becomes once submitted.
    /// `monoFontFamily` defaults to `""`, which preserves system monospace —
    /// the behaviour every call site got before this parameter existed.
    /// Pass a configured fixed-pitch family (e.g. the ACP chat font) to make
    /// the box track that font instead.
    static func standard(
        theme: Theme,
        baseFont: NSFont,
        baseColor: NSColor,
        monoSize: CGFloat,
        monoFontFamily: String = ""
    ) -> MarkdownCodeBlockStyle {
        MarkdownCodeBlockStyle(
            baseFont: baseFont,
            baseColor: baseColor,
            monoFont: CenterTypography.resolveCodeFont(family: monoFontFamily, size: monoSize),
            bodyColor: baseColor,
            fenceColor: NSColor(theme.color("fg-dim")),
            backgroundColor: NSColor(theme.color("bg-0")).withAlphaComponent(0.6),
            borderColor: NSColor(theme.color("line"))
        )
    }
}
