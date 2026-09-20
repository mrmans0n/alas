import SwiftUI

/// Click feedback for the app's toolbar controls.
///
/// Hover stays with each control — they disagree on the resting decoration
/// (neutral icon buttons in the sidebar, accent-tinted pills in the chat
/// toolbar) — but the press step is the same everywhere: the control dips
/// and dims while the mouse is down, so a click reads as landing even when
/// it opens a popover instead of changing the button's own appearance.
struct ToolbarControlPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    /// The body lives in a `View` rather than in `makeBody` because
    /// `@Environment` is only resolved for views.
    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.65 : 1)
                // Reduce Motion keeps the dim — it still reads as a press —
                // but drops the dip and the tween, so a routine click stops
                // moving. Every toolbar in the app runs through this style,
                // so the unconditional version animated a lot of clicks.
                .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.95)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08),
                           value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == ToolbarControlPressStyle {
    static var toolbarControl: ToolbarControlPressStyle { ToolbarControlPressStyle() }
}

/// Presentation state shared by menu-backed toolbar controls. Unlike buttons,
/// `Menu` does not expose `ButtonStyleConfiguration.isPressed` to its label.
enum ToolbarMenuControlPresentation {
    enum InteractionState: Equatable {
        case idle
        case hovering
        case pressed
    }

    static func interactionState(hovering: Bool, isPressed: Bool) -> InteractionState {
        if isPressed { return .pressed }
        return hovering ? .hovering : .idle
    }

    static func isLit(hovering: Bool, isPressed: Bool) -> Bool {
        interactionState(hovering: hovering, isPressed: isPressed) != .idle
    }
}

private struct ToolbarMenuControlPressFeedback: ViewModifier {
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isPressed ? 0.65 : 1)
            .scaleEffect(reduceMotion || !isPressed ? 1 : 0.95)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
    }
}

extension View {
    /// Matches `ToolbarControlPressStyle` for menu labels, whose press state is
    /// tracked by a simultaneous gesture so the menu still receives its click.
    func toolbarMenuControlPressFeedback(isPressed: Bool) -> some View {
        modifier(ToolbarMenuControlPressFeedback(isPressed: isPressed))
    }
}

/// Dimensions for a toolbar control's surface.
struct ToolbarControlMetrics: Equatable {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    /// The app-wide default: tab bar, right pane, ACP and dialog toolbars.
    static let standard = ToolbarControlMetrics(width: 26, height: 22, cornerRadius: 5)

    /// E1's sidebar header: square buttons, slightly rounder.
    static let sidebarHeader = ToolbarControlMetrics(width: 23, height: 23, cornerRadius: 6)
}

/// The shared toolbar-button surface: a fixed hit area that fills with `bg-3`
/// once lit.
///
/// `ToolbarBtn` wraps its own icon in it, and the tab bar's menu-backed
/// controls borrow it directly — a `Menu` cannot take a `ButtonStyle`, so
/// wrapping the label is the only way for them to look like their `Button`
/// neighbours.
private struct ToolbarControlSurface: ViewModifier {
    let isLit: Bool
    let metrics: ToolbarControlMetrics
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .frame(width: metrics.width, height: metrics.height)
            .contentShape(Rectangle())
            .background(isLit ? theme.color("bg-3") : .clear)
            .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
    }
}

extension View {
    func toolbarControlSurface(
        isLit: Bool,
        metrics: ToolbarControlMetrics = .standard
    ) -> some View {
        modifier(ToolbarControlSurface(isLit: isLit, metrics: metrics))
    }
}

/// A menu-backed toolbar control that behaves like its `Button` neighbours:
/// the same surface, the same hover fill, the same press dip.
///
/// The menu style is the whole point of this type. `.menuStyle(.borderlessButton)`
/// hands the label to an AppKit `SwiftUIPopupButton`, which keeps only the
/// glyph: the SwiftUI label never enters the view tree (it reports a zero
/// frame), the `toolbarControlSurface` fill is dropped, the control shrinks to
/// the glyph's intrinsic size, and the popup's tracking loop swallows
/// mouse-down. No amount of hover or press bookkeeping in the label can show
/// up on screen, because that label is never rendered or hit-tested.
///
/// `.menuStyle(.button)` keeps the label in SwiftUI, so `.onHover` fires and a
/// `ButtonStyle` receives `isPressed` — which is why the press step here is
/// `.toolbarControl`, the exact style the neighbouring `Button`s use, rather
/// than a hand-rolled gesture.
struct ToolbarMenuButton<Content: View>: View {
    private let iconName: String
    private let iconSize: CGFloat
    private let metrics: ToolbarControlMetrics
    private let restingColorToken: String
    private let help: String
    /// Kept as a closure: SwiftUI evaluates menu content when the menu opens,
    /// which is the rescan-on-open point for callers that build their items
    /// from disk.
    private let content: () -> Content

    @Environment(\.theme) private var theme
    @State private var hovering = false

    init(
        iconName: String,
        iconSize: CGFloat = 13,
        metrics: ToolbarControlMetrics = .standard,
        restingColorToken: String = "fg-faint",
        help: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.iconName = iconName
        self.iconSize = iconSize
        self.metrics = metrics
        self.restingColorToken = restingColorToken
        self.help = help
        self.content = content
    }

    var body: some View {
        Menu(content: content) {
            Icon(
                name: iconName,
                size: iconSize,
                color: theme.color(hovering ? "fg" : restingColorToken)
            )
            .toolbarControlSurface(isLit: hovering, metrics: metrics)
        }
        .menuStyle(.button)
        .buttonStyle(.toolbarControl)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
