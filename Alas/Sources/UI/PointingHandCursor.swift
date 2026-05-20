import SwiftUI

struct PointingHandCursorModifier: ViewModifier {
    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    pushCursor()
                } else {
                    popCursor()
                }
            }
            .onDisappear {
                popCursor()
            }
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        NSCursor.pointingHand.push()
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}
