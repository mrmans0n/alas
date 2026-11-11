import SwiftUI

/// What a VM tab's status dot says.
enum VMStatusTone {
    case running, off, busy, attention

    var colorToken: String {
        switch self {
        case .running: "add"
        case .off: "fg-faint"
        case .busy: "accent"
        case .attention: "warn"
        }
    }
}

/// Toolbar control surface of the VM status bar: square, as tall as its compact buttons.
extension ToolbarControlMetrics {
    static let vmStatusBar = ToolbarControlMetrics(width: 24, height: 24, cornerRadius: 6) // design-literal: static toolbar metrics, no environment
}

/// The strip atop a VM tab: a status dot, the state, muted details, and the
/// tab's actions on the right.
struct VMStatusBar<Actions: View>: View {
    let tone: VMStatusTone
    let title: String
    let details: [String]
    private let actions: Actions

    init(
        tone: VMStatusTone, title: String, details: [String] = [],
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.tone = tone
        self.title = title
        self.details = details
        self.actions = actions()
    }
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: scale.space[2]) {
            HStack(spacing: scale.space[2]) {
                Circle()
                    .fill(theme.color(tone.colorToken))
                    .frame(width: 7, height: 7) // design-literal: status dot size
                Text(title)
                    .font(scale.emphasisFont)
                    .foregroundColor(theme.color("fg"))
            }
            .fixedSize()
            if !details.isEmpty {
                Text(details.map { "· \($0)" }.joined(separator: " "))
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: scale.space[2])
            actions
        }
        .padding(.leading, scale.space[3])
        .padding(.trailing, scale.space[2])
        .frame(height: 34) // design-literal: status bar height
        .background(theme.color("section-head-bg"))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
        }
    }
}

/// The centered card a VM tab shows when there is no VM screen to show: a
/// badge, a title, a short explanation, and its actions.
struct VMEmptyStateCard<Accessory: View, Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    /// Shows a spinner in the badge instead of the icon.
    let busy: Bool
    private let accessory: Accessory
    private let actions: Actions
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        busy: Bool = false,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.busy = busy
        self.accessory = accessory()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: scale.space[3]) {
            RoundedRectangle(cornerRadius: 12) // design-literal: badge tile radius
                .fill(theme.color("accent-soft"))
                .frame(width: 44, height: 44) // design-literal: badge tile size
                .overlay {
                    if busy {
                        Spinner(color: theme.color("accent")).frame(width: 20, height: 20) // design-literal: badge spinner size
                    } else {
                        Icon(name: icon, size: 20, color: theme.color("accent")) // design-literal: badge icon size
                    }
                }
            Text(title)
                .font(scale.titleFont)
                .foregroundColor(theme.color("fg"))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(scale.bodyFont)
                    .foregroundColor(theme.color("fg-muted"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3) // design-literal: description line spacing
                    .frame(maxWidth: 280) // design-literal: description measure
                    .fixedSize(horizontal: false, vertical: true)
            }
            accessory
            if Actions.self != EmptyView.self {
                HStack(spacing: scale.space[2]) { actions }
                    .padding(.top, scale.space[1])
            }
        }
        .padding(scale.space[5])
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A tinted note in a VM tab: a warning (setup or start failures) or
/// information (the manual setup steps).
struct VMCallout<Content: View, Actions: View>: View {
    enum Tone { case warning, info }

    let tone: Tone
    let title: String?
    let message: String?
    let onDismiss: (() -> Void)?
    private let content: Content
    private let actions: Actions
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    init(
        tone: Tone = .warning,
        title: String? = nil,
        message: String? = nil,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.onDismiss = onDismiss
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: scale.space[2]) {
            Icon(name: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill",
                 size: 12, color: tint) // design-literal: icon size
                .padding(.top, 1) // design-literal: optical icon alignment
            VStack(alignment: .leading, spacing: scale.space[1]) {
                if let title {
                    Text(title)
                        .font(scale.meta.font(weight: .semibold))
                        .foregroundColor(tone == .warning ? tint : theme.color("fg"))
                }
                if let message {
                    Text(message)
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-muted"))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
                if Actions.self != EmptyView.self {
                    HStack(spacing: scale.space[2]) { actions }
                        .padding(.top, scale.space[1])
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                ToolbarBtn(icon: "xmark", tooltip: "Dismiss", metrics: .vmStatusBar, action: onDismiss)
                    .padding(.top, -4) // design-literal: pull the dismiss button into the corner
                    .padding(.trailing, -4) // design-literal: pull the dismiss button into the corner
            }
        }
        .padding(.vertical, scale.space[2])
        .padding(.horizontal, scale.space[3])
        .background(RoundedRectangle(cornerRadius: scale.radius.medium).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(border, lineWidth: 0.5))
        .padding(scale.space[2])
    }

    private var tint: Color { theme.color(tone == .warning ? "warn" : "accent") }
    private var fill: Color { tone == .warning ? tint.opacity(0.12) : theme.color("accent-soft") }
    private var border: Color { tint.opacity(0.4) }
}

/// A numbered checklist for a `VMCallout`.
struct VMNumberedSteps: View {
    let steps: [String]
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: scale.space[2]) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundColor(theme.color("fg-dim"))
                    Text(step)
                        .foregroundColor(theme.color("fg-muted"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(scale.metaFont)
            }
        }
    }
}

/// The base image setup's steps, with the current one spinning, and a thin
/// bar for the whole setup.
struct VMSetupSteps: View {
    static let macOSTitles = [
        "Download macOS",
        "Install",
        "First start",
        "Create user & install helper",
        "Check permissions & seal",
    ]

    static let linuxTitles = [
        "Download Ubuntu",
        "Convert",
        "First start",
        "Check helper & seal",
    ]

    var titles = Self.macOSTitles
    /// The step in progress, an index into `titles`.
    let current: Int
    /// How far the current step is, 0…1.
    let fraction: Double
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    /// Where the installer's `phase` is in `titles`; nil outside the setup.
    static func position(of phase: GoldenImageInstaller.Phase) -> (current: Int, fraction: Double)? {
        switch phase {
        case .downloading(let fraction): (0, fraction)
        case .installing(let fraction): (1, fraction)
        case .provisioning(.firstBoot): (2, 0)
        case .provisioning(.patching): (3, 0)
        case .provisioning(.finishing): (3, 0.5)
        case .provisioning(.verifying): (4, 0)
        case .provisioning(.shuttingDown): (4, 0.5)
        case .idle, .awaitingSetup, .sealed, .failed: nil
        }
    }

    /// Where the Linux installer's `phase` is in `linuxTitles`; nil outside the setup.
    static func position(of phase: LinuxGoldenInstaller.Phase) -> (current: Int, fraction: Double)? {
        switch phase {
        case .downloading(let fraction): (0, fraction)
        case .checking: (0, 1)
        case .converting(let fraction): (1, fraction)
        case .firstBoot: (2, 0)
        case .verifying: (3, 0)
        case .idle, .sealed, .failed: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            VStack(alignment: .leading, spacing: scale.space[2]) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: scale.space[2]) {
                        marker(index)
                        Text(title)
                            .font(scale.meta.font(weight: index == current ? .medium : .regular))
                            .foregroundColor(textColor(index))
                    }
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.color("bg-4"))
                    Capsule().fill(theme.color("accent"))
                        .frame(width: proxy.size.width * overall)
                }
            }
            .frame(height: 3) // design-literal: progress bar height
        }
        .frame(width: 260) // design-literal: steps column width
        .padding(.top, scale.space[1])
    }

    private var overall: Double {
        min(max((Double(current) + min(max(fraction, 0), 1)) / Double(titles.count), 0), 1)
    }

    @ViewBuilder
    private func marker(_ index: Int) -> some View {
        if index < current {
            Circle().fill(theme.color("add"))
                .frame(width: 14, height: 14) // design-literal: step marker size
                .overlay {
                    Image(systemName: "checkmark")
                        .font(scale.glyph.font(weight: .bold))
                        .foregroundColor(theme.color("bg-0"))
                }
        } else if index == current {
            Spinner(lineWidth: 1.5, color: theme.color("accent")).frame(width: 14, height: 14) // design-literal: step marker size
        } else {
            Circle().strokeBorder(theme.color("fg-faint"), lineWidth: 1)
                .frame(width: 14, height: 14) // design-literal: step marker size
        }
    }

    private func textColor(_ index: Int) -> Color {
        if index < current { return theme.color("fg-muted") }
        return theme.color(index == current ? "fg" : "fg-dim")
    }
}

extension View {
    /// Disables a VM tab control and dims it, which `AlasButton` does not do itself.
    func vmDisabled(_ disabled: Bool) -> some View {
        self.disabled(disabled).opacity(disabled ? 0.5 : 1)
    }
}
