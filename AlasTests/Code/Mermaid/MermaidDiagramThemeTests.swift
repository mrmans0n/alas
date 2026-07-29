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

    @Test("effective accent participates in the render key")
    func accentChangesKey() throws {
        var firstTheme = try Theme.loadBundled(id: "cool-slate")
        var secondTheme = firstTheme
        firstTheme.accentOverrideHex = "#112233"
        secondTheme.accentOverrideHex = "#445566"

        let firstKey = MermaidRenderKey(
            source: "graph TD; A-->B",
            theme: MermaidDiagramTheme(theme: firstTheme),
            scale: 2,
            profile: .full
        )
        let secondKey = MermaidRenderKey(
            source: firstKey.source,
            theme: MermaidDiagramTheme(theme: secondTheme),
            scale: firstKey.scale,
            profile: firstKey.profile
        )

        #expect(firstKey != secondKey)
    }
}
