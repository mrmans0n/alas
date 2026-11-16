import AlasCore
import SwiftUI

/// A device's screen framed at its shape, turned for landscape, with a
/// gutter of hardware buttons on its right.
struct DeviceStageFrame<Screen: View, Gutter: View>: View {
    let shape: DeviceScreenShape?
    let landscape: Bool
    /// A drop the screen would take is over it: outline it.
    let dropTargeted: Bool
    @ViewBuilder let screen: () -> Screen
    @ViewBuilder let gutter: () -> Gutter
    @Environment(\.theme) private var theme

    private static var margin: CGFloat { 12 }
    private static var gutterWidth: CGFloat { 44 }
    private static var bezel: CGFloat { 4 }

    var body: some View {
        GeometryReader { geometry in
            let area = CGSize(
                width: max(0, geometry.size.width - Self.margin * 2 - Self.gutterWidth - Self.bezel * 2),
                height: max(0, geometry.size.height - Self.margin * 2 - Self.bezel * 2)
            )
            let size = Self.fit(shape, landscape: landscape, in: area)
            // The radius scales with the device's short side, which is its width in portrait.
            let radius = shape?.cornerRadius(forFittedWidth: landscape ? size.height : size.width) ?? 0
            HStack(spacing: 0) {
                screen()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(theme.color("accent"), lineWidth: 2)
                            .opacity(dropTargeted ? 1 : 0)
                    )
                    .padding(Self.bezel)
                    .background(
                        RoundedRectangle(cornerRadius: radius + Self.bezel, style: .continuous)
                            .fill(Color(white: 0.067))
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                gutter()
                    .frame(width: Self.gutterWidth)
            }
            .padding(Self.margin)
        }
    }

    /// The largest size of the screen's shape, turned for landscape, that
    /// fits `area`; all of it without a shape.
    static func fit(_ shape: DeviceScreenShape?, landscape: Bool, in area: CGSize) -> CGSize {
        guard let shape, shape.widthPoints > 0, shape.heightPoints > 0 else { return area }
        let (width, height) = landscape ? (shape.heightPoints, shape.widthPoints) : (shape.widthPoints, shape.heightPoints)
        let scale = min(area.width / width, area.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}

/// The capsule of hardware buttons beside a device's screen.
struct DeviceGutter<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(spacing: 2, content: content)
            .padding(scale.space[1])
            .background(theme.color("bg-2"), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            .frame(maxHeight: .infinity)
    }
}

struct DeviceGutterButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        ToolbarBtn(
            icon: icon, tooltip: help, metrics: ToolbarControlMetrics(width: 28, height: 28, cornerRadius: 14) // design-literal: pill-shaped hardware button, half its 28pt frame
        ) {
            action()
        }
    }
}

/// A capsule over the bottom of a device's screen: a notice, or an app being installed.
struct DeviceStagePill<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: 6, content: content)
            .font(scale.caption.font)
            .lineLimit(2)
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[1])
            .background(.ultraThinMaterial, in: Capsule())
            .background(theme.color("bg-2").opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
            .padding(.horizontal, scale.space[3])
    }
}

/// The app dropped on a device's screen, while it installs and launches, or why it couldn't.
struct DeviceAppInstallPill: View {
    let install: DevicePaneModel.AppInstall
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        DeviceStagePill {
            switch install {
            case .installing(let name):
                ProgressView().controlSize(.mini)
                Text("Installing \(name)…")
                    .foregroundStyle(theme.color("fg"))
            case .launching(let name):
                ProgressView().controlSize(.mini)
                Text("Launching \(name)…")
                    .foregroundStyle(theme.color("fg"))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.color("warn"))
                Text(message)
                    .foregroundStyle(theme.color("fg"))
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
            }
        }
    }
}

/// Who drives a device, over the top of its screen, with Take over or Hand back.
struct DeviceDriverPill: View {
    let driver: VMDriver
    /// The first session whose call waits for the user to hand back.
    let waiting: String?
    let agentName: (String) -> String
    /// Grows for a moment after a click an agent's driving blocked.
    let pulse: Bool
    let onTakeOver: () -> Void
    let onHandBack: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        // The one-line strip, or the same texts and button on two lines when the
        // screen is too narrow for it.
        ViewThatFits(in: .horizontal) {
            content(stacked: false)
            content(stacked: true)
        }
        .font(scale.caption.font)
        .background(.ultraThinMaterial, in: Capsule())
        .background(theme.color("bg-2").opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
        .scaleEffect(pulse ? 1.06 : 1)
        .animation(.easeOut(duration: 0.2), value: pulse)
    }

    @ViewBuilder
    private func content(stacked: Bool) -> some View {
        let status = HStack(spacing: 6) {
            switch driver {
            case .agent(let sessionID, _, _):
                Circle().fill(theme.color(DevicesSwitcher.colorToken(.busy))).frame(width: 6, height: 6)
                Text("\(agentName(sessionID)) is driving")
                    .foregroundStyle(theme.color("fg"))
                    .fixedSize()
            case .user, .idle:
                Text("You're driving")
                    .foregroundStyle(theme.color("fg"))
                    .fixedSize()
                if let waiting {
                    Text("· \(agentName(waiting)) is waiting")
                        .foregroundStyle(theme.color("fg-dim"))
                        .fixedSize()
                }
            }
        }
        let action = Group {
            switch driver {
            case .agent:
                Button("Take over", action: onTakeOver)
            case .user, .idle:
                Button("Hand back", action: onHandBack)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("accent"))
        .fixedSize()
        if stacked {
            VStack(alignment: .trailing, spacing: scale.space[1]) {
                status
                action
            }
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[1])
        } else {
            HStack(spacing: 6) {
                status
                action
            }
            .padding(.horizontal, scale.space[3])
            .frame(height: 24)
        }
    }
}
