import AppKit
import Foundation
import SwiftUI

struct MermaidDiagramTheme: Hashable, Sendable {
    let background: String
    let foreground: String
    let line: String
    let accent: String
    let muted: String
    let surface: String
    let border: String

    @MainActor
    init(theme: Theme) {
        background = Self.hex(theme.color("bg-1"))
        foreground = Self.hex(theme.color("fg"))
        line = Self.hex(theme.color("line"))
        accent = Self.hex(theme.color("accent"))
        muted = Self.hex(theme.color("fg-muted"))
        surface = Self.hex(theme.color("bg-2"))
        border = Self.hex(theme.color("line"))
    }

    var signature: String {
        [background, foreground, line, accent, muted, surface, border]
            .joined(separator: "|")
    }

    @MainActor
    private static func hex(_ color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
