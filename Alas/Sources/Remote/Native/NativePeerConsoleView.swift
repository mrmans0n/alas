import SwiftUI

/// A paired Mac's console. The host owns the terminal's rows and columns, so
/// the surface is sized to that grid and scrolls inside the pane instead of
/// asking the host to resize, unless Fit shrinks the local font to fit.
struct NativePeerConsoleView: View {
    let viewer: PeerConsoleViewer
    /// The terminal font size from settings, which Fit scales down from.
    let baseFontSize: Float
    let onReconnect: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.color("line")).frame(height: 1)
            ZStack {
                if let surface = viewer.surface {
                    Group {
                        // Cell metrics exist once the surface is in a window,
                        // so it fills the pane until the grid can be sized.
                        if let extent = viewer.gridExtent {
                            ScrollView([.horizontal, .vertical]) {
                                GhosttyHost(surface: surface)
                                    .frame(width: extent.width, height: extent.height)
                                    .background(theme.color("bg-0"))
                            }
                        } else {
                            GhosttyHost(surface: surface)
                                .background(theme.color("bg-0"))
                        }
                    }
                    .opacity(viewer.phase == .live ? 1 : 0.35)
                }
                status
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewer.layout(pane: $0) }
            .onChange(of: baseFontSize, initial: true) { viewer.setBaseFontSize(baseFontSize) }
        }
        .background(theme.color("bg-1"))
    }

    /// Control of the host's terminal. Title and peer live in the tab strip.
    private var header: some View {
        HStack(spacing: 10) {
            if let rows = viewer.rows, let columns = viewer.columns {
                Text("\(columns)×\(rows), size set by the host")
                    .font(scale.captionFont)
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("Fit", isOn: Binding(get: { viewer.fitsToPane }, set: { viewer.setFitsToPane($0) }))
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Shrink the font so the host's terminal fits this pane")
            Text(controlLabel)
                .font(scale.metaFont)
                .foregroundColor(theme.color(viewer.isControlling ? "accent" : "fg-muted"))
            controlButton
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("bg-2"))
    }

    private var controlLabel: String {
        switch viewer.control.owner {
        case .you: "You have control"
        case .anotherPeer: "Another Mac has control"
        case .host: "View only"
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        if viewer.isControlling {
            Button("Release Control") { viewer.releaseControl() }
                .controlSize(.small)
        } else {
            Button("Take Control") { viewer.takeControl() }
                .controlSize(.small)
                .disabled(viewer.phase != .live || viewer.control.owner == .anotherPeer)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch viewer.phase {
        case .connecting:
            ProgressView("Connecting…")
                .controlSize(.small)
        case .live:
            EmptyView()
        case .ended(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg"))
                    .multilineTextAlignment(.center)
                Button("Reconnect", action: onReconnect)
            }
            .padding(scale.space[4])
            .background(theme.color("bg-3"), in: RoundedRectangle(cornerRadius: scale.radius.medium))
            .frame(maxWidth: 360)
        }
    }
}
