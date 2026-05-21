import AppKit
import SwiftUI

/// Renders a built-in agent's vendor logo from `AgentLogos/agent-<id>` if
/// present; falls back to the sparkle glyph for custom agents (which have
/// no `builtinLogoAssetName`) or if the asset is missing.
struct AgentLogoView: View {
    let agent: AgentDefinition
    var size: CGFloat = 16
    @Environment(\.theme) private var theme

    @ViewBuilder
    var body: some View {
        if let asset = agent.builtinLogoAssetName, NSImage(named: asset) != nil {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Icon(name: "sparkle", size: max(2, size - 2), color: theme.color("fg-muted"))
                .frame(width: size, height: size)
        }
    }
}
