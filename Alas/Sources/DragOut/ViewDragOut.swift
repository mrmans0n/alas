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
    var beginTask: Task<Void, Never>?

    /// Called when the gesture ends without a drag ever lifting (a plain
    /// click, or a resolve that failed or lost the race with mouse-up).
    /// Once a drag actually lifts, `onEnded` never fires — AppKit has taken
    /// the mouse — so the success path resets state itself instead of
    /// relying on this.
    func reset() {
        resolveTask?.cancel()
        resolveTask = nil
        beginTask?.cancel()
        beginTask = nil
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
                    state.beginTask = Task { @MainActor in
                        guard let url = await resolveTask.value, !Task.isCancelled,
                              let event = NSApp.currentEvent,
                              event.type == .leftMouseDragged || event.type == .leftMouseDown,
                              let view = event.window?.contentView
                        else { return }        // no reset: onEnded will clean up
                        DragOutSession.shared.begin(url: url, event: event, in: view)
                        state.reset()          // only here — onEnded won't fire
                    }
                }
                .onEnded { _ in state.reset() }
        )
    }
}
