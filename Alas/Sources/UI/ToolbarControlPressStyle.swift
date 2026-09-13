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
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ToolbarControlPressStyle {
    static var toolbarControl: ToolbarControlPressStyle { ToolbarControlPressStyle() }
}
