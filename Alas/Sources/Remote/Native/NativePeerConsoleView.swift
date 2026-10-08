import SwiftUI

/// A paired Mac's console. The host owns the terminal's rows and columns, so
/// the surface is sized to that grid and scrolls inside the pane instead of
/// asking the host to resize.
struct NativePeerConsoleView: View {
    let viewer: PeerConsoleViewer
    let peerName: String
    let onReconnect: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.color("line")).frame(height: 1)
            ZStack {
                if let surface = viewer.surface {
                    Group {
                        // Cell metrics exist once the surface is in a window,
                        // so it fills the pane until the grid can be sized.
                        if let extent = gridExtent {
                            ScrollView([.horizontal, .vertical]) {
                                GhosttyHost(surface: surface)
                                    .frame(width: extent.width, height: extent.height)
                            }
                        } else {
                            GhosttyHost(surface: surface)
                        }
                    }
                    .opacity(viewer.phase == .live ? 1 : 0.35)
                }
                status
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.color("bg-1"))
    }

    /// The host grid in points, plus one cell of slack for Ghostty's padding.
    private var gridExtent: CGSize? {
        guard let rows = viewer.rows, let columns = viewer.columns, let cell = viewer.cellSize else {
            return nil
        }
        return CGSize(width: CGFloat(columns + 1) * cell.width, height: CGFloat(rows + 1) * cell.height)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundColor(theme.color("fg-muted"))
            VStack(alignment: .leading, spacing: 1) {
                Text(viewer.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(controlLabel)
                .font(.system(size: 11))
                .foregroundColor(theme.color(viewer.isControlling ? "accent" : "fg-muted"))
            controlButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
    }

    private var subtitle: String {
        var parts = ["on \(peerName)"]
        if let rows = viewer.rows, let columns = viewer.columns {
            parts.append("\(columns)×\(rows), size set by the host")
        }
        return parts.joined(separator: " · ")
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
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                    .multilineTextAlignment(.center)
                Button("Reconnect", action: onReconnect)
            }
            .padding(16)
            .background(theme.color("bg-3"), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 360)
        }
    }
}
