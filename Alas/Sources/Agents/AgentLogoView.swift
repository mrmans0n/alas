import AppKit
import SwiftUI

enum AgentLogoPresentation: Equatable {
    case asset(name: String)
    case fallbackSymbol

    static func resolve(for agent: AgentDefinition) -> AgentLogoPresentation {
        guard let asset = agent.builtinLogoAssetName, NSImage(named: asset) != nil else {
            return .fallbackSymbol
        }
        return .asset(name: asset)
    }
}

/// Renders a built-in agent's vendor logo from `AgentLogos/agent-<id>` if
/// present; falls back to the sparkle glyph for custom agents (which have
/// no `builtinLogoAssetName`) or if the asset is missing.
struct AgentLogoView: View {
    let agent: AgentDefinition
    var size: CGFloat = 16
    @Environment(\.theme) private var theme

    @ViewBuilder
    var body: some View {
        switch AgentLogoPresentation.resolve(for: agent) {
        case .asset(let name):
            Image(name)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        case .fallbackSymbol:
            Icon(name: "sparkle", size: max(2, size - 2), color: theme.color("fg-muted"))
                .frame(width: size, height: size)
        }
    }
}

extension AgentLogoView {
    /// Returns an `NSImage` copy clamped to `size`.
    /// SwiftUI `Menu` / `Picker` (`.menu` style) renders items as `NSMenuItem`s
    /// and ignores SwiftUI frame sizing on custom icon views, drawing the
    /// backing `NSImage` at its native pixel size. Pass this clamped copy
    /// to `Image(nsImage:)` so the icon appears at the intended point size.
    static func menuImage(for agent: AgentDefinition, size: CGFloat = 16) -> NSImage {
        if let asset = agent.builtinLogoAssetName,
           let source = NSImage(named: asset) {
            let copy = source.copy() as? NSImage ?? source
            copy.size = NSSize(width: size, height: size)
            return copy
        }
        let fallback = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
            ?? NSImage()
        fallback.size = NSSize(width: size, height: size)
        return fallback
    }
}
