import AppKit
import SwiftUI

@MainActor
final class ACPDelayedHoverVisibility: ObservableObject {
    @Published private(set) var isVisible = false

    private let hideDelayNanoseconds: UInt64
    private var hideTask: Task<Void, Never>?

    init(hideDelayNanoseconds: UInt64 = 350_000_000) {
        self.hideDelayNanoseconds = hideDelayNanoseconds
    }

    deinit {
        hideTask?.cancel()
    }

    func enter() {
        hideTask?.cancel()
        hideTask = nil
        // `@Published` notifies on every assignment; re-rendering an already
        // visible overlay on each hover event is wasted work.
        if !isVisible { isVisible = true }
    }

    /// Detaching a retained row must clear hover without the pointer-exit delay.
    func reset() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
    }

    func leave() {
        hideTask?.cancel()
        let delay = hideDelayNanoseconds
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.isVisible = false
                self?.hideTask = nil
            }
        }
    }
}

extension View {
    /// `.onHover` for views inside transcript rows. SwiftUI's `.onHover` makes
    /// the row's hosting view observe its own position in the window, so every
    /// scroll tick re-laid out every mounted row. An AppKit tracking area
    /// follows the view without that observation.
    func acpTrackingHover(_ action: @escaping (Bool) -> Void) -> some View {
        background(ACPHoverTrackingView(onChange: action))
    }
}

private struct ACPHoverTrackingView: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var isInside = false

        /// Tracks the pointer only; clicks go to the content above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Added once: an `.inVisibleRect` area follows the view, and
        /// replacing it under the pointer fires a spurious exit/enter pair.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingAreas.isEmpty else { return }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { setInside(true) }
        override func mouseExited(with event: NSEvent) { setInside(false) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setInside(false) }
        }

        private func setInside(_ inside: Bool) {
            guard inside != isInside else { return }
            isInside = inside
            onChange?(inside)
        }
    }
}
