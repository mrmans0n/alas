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
    static let vmStatusBar = ToolbarControlMetrics(width: 24, height: 24, cornerRadius: 6)
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

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.color(tone.colorToken))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg"))
            }
            .fixedSize()
            if !details.isEmpty {
                Text(details.map { "· \($0)" }.joined(separator: " "))
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 34)
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
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.color("accent-soft"))
                .frame(width: 44, height: 44)
                .overlay {
                    if busy {
                        Spinner(color: theme.color("accent")).frame(width: 20, height: 20)
                    } else {
                        Icon(name: icon, size: 20, color: theme.color("accent"))
                    }
                }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.color("fg"))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-muted"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }
            accessory
            if Actions.self != EmptyView.self {
                HStack(spacing: 8) { actions }
                    .padding(.top, 4)
            }
        }
        .padding(24)
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
        HStack(alignment: .top, spacing: 8) {
            Icon(name: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill",
                 size: 12, color: tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(tone == .warning ? tint : theme.color("fg"))
                }
                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(theme.color("fg-muted"))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
                if Actions.self != EmptyView.self {
                    HStack(spacing: 8) { actions }
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                ToolbarBtn(icon: "xmark", tooltip: "Dismiss", metrics: .vmStatusBar, action: onDismiss)
                    .padding(.top, -4)
                    .padding(.trailing, -4)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 0.5))
        .padding(8)
    }

    private var tint: Color { theme.color(tone == .warning ? "warn" : "accent") }
    private var fill: Color { tone == .warning ? tint.opacity(0.12) : theme.color("accent-soft") }
    private var border: Color { tint.opacity(0.4) }
}

/// A numbered checklist for a `VMCallout`.
struct VMNumberedSteps: View {
    let steps: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundColor(theme.color("fg-dim"))
                    Text(step)
                        .foregroundColor(theme.color("fg-muted"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
            }
        }
    }
}

/// The base image setup's steps, with the current one spinning, and a thin
/// bar for the whole setup.
struct VMSetupSteps: View {
    static let titles = [
        "Download macOS",
        "Install",
        "First start",
        "Create user & install helper",
        "Check permissions & seal",
    ]

    /// The step in progress, an index into `titles`.
    let current: Int
    /// How far the current step is, 0…1.
    let fraction: Double
    @Environment(\.theme) private var theme

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(Self.titles.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 8) {
                        marker(index)
                        Text(title)
                            .font(.system(size: 12, weight: index == current ? .medium : .regular))
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
            .frame(height: 3)
        }
        .frame(width: 260)
        .padding(.top, 4)
    }

    private var overall: Double {
        min(max((Double(current) + min(max(fraction, 0), 1)) / Double(Self.titles.count), 0), 1)
    }

    @ViewBuilder
    private func marker(_ index: Int) -> some View {
        if index < current {
            Circle().fill(theme.color("add"))
                .frame(width: 14, height: 14)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.color("bg-0"))
                }
        } else if index == current {
            Spinner(lineWidth: 1.5, color: theme.color("accent")).frame(width: 14, height: 14)
        } else {
            Circle().strokeBorder(theme.color("fg-faint"), lineWidth: 1)
                .frame(width: 14, height: 14)
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
