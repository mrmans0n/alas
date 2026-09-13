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

/// The shared toolbar-button surface: a fixed 26x22 hit area that fills with
/// `bg-3` once lit.
///
/// `ToolbarBtn` wraps its own icon in it, and the tab bar's menu-backed
/// controls borrow it directly — a `Menu` cannot take a `ButtonStyle`, so
/// wrapping the label is the only way for them to look like their `Button`
/// neighbours.
private struct ToolbarControlSurface: ViewModifier {
    let isLit: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
            .background(isLit ? theme.color("bg-3") : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

extension View {
    func toolbarControlSurface(isLit: Bool) -> some View {
        modifier(ToolbarControlSurface(isLit: isLit))
    }
}
