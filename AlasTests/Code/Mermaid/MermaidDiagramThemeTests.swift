import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("Mermaid diagram theme")
struct MermaidDiagramThemeTests {
    @Test("theme palette is stable sRGB hex and includes accent")
    func stablePalette() throws {
        var theme = try Theme.loadBundled(id: "cool-slate")
        theme.accentOverrideHex = "#D3A25C"
        let palette = MermaidDiagramTheme(theme: theme)

        #expect(palette.background.hasPrefix("#"))
        #expect(palette.foreground.hasPrefix("#"))
        #expect(palette.accent == "#D3A25C")
        #expect(palette.signature.contains("#D3A25C"))
    }
}
