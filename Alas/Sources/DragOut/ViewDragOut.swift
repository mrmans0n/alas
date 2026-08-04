import AppKit
import SwiftUI

/// Distance thresholds separating a click from a drag.
enum DragOutActivation {
    /// Travel after which the payload starts resolving. Kept above zero so a
    /// plain click never spawns a `git show`.
    static let prefetchDistance: CGFloat = 2

    /// Travel after which the drag session begins.
    static let activationDistance: CGFloat = 6

    static func travel(_ translation: CGSize) -> CGFloat {
        (translation.width * translation.width + translation.height * translation.height)
            .squareRoot()
    }
}

extension View {
    /// Makes a row draggable out of Alas as a real file.
    ///
    /// The closure runs when the press starts travelling, and returning nil —
    /// or a payload that fails to resolve — simply means no drag lifts. Nothing
    /// is reported: an alert thrown mid-gesture is worse than the drag that
    /// quietly does not start.
    func dragOut(_ payload: @escaping () -> DragOutPayload?) -> some View {
        modifier(DragOutModifier(payload: payload))
    }
}

/// Per-row gesture state. A `@MainActor` reference type rather than `@State`
/// on the modifier, so the drag-start task captures only this — capturing the
/// modifier itself would drag in its non-Sendable payload closure, which
/// `SWIFT_STRICT_CONCURRENCY: complete` rejects.
@MainActor
private final class DragOutState: ObservableObject {
    var armed = false
    var began = false
    var resolveTask: Task<URL?, Never>?

    /// Called both when a drag begins — `onEnded` never fires once AppKit takes
    /// over the mouse — and when the gesture ends without one.
    func reset() {
        resolveTask = nil
        armed = false
        began = false
    }
}

private struct DragOutModifier: ViewModifier {
    let payload: () -> DragOutPayload?

    @StateObject private var state = DragOutState()

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let travel = DragOutActivation.travel(value.translation)
                    if !state.armed, travel >= DragOutActivation.prefetchDistance {
                        state.armed = true
                        if let payload = payload() {
                            state.resolveTask = Task { await payload.resolve() }
                        }
                    }
                    guard !state.began,
                          travel >= DragOutActivation.activationDistance,
                          let resolveTask = state.resolveTask
                    else { return }
                    state.began = true
                    let state = state
                    Task { @MainActor in
                        defer { state.reset() }
                        guard let url = await resolveTask.value,
                              let event = NSApp.currentEvent,
                              let view = event.window?.contentView
                        else { return }
                        DragOutSession.shared.begin(url: url, event: event, in: view)
                    }
                }
                .onEnded { _ in state.reset() }
        )
    }
}
