import AppKit
import SwiftUI

/// Hover for every row of a scrolling sidebar list, from one tracking area.
///
/// A SwiftUI `.onHover` per row is what kept this list from 90fps. Whenever
/// content moves under a resting pointer SwiftUI re-runs its hover hit test,
/// and that walks every mounted row's responders on every scroll frame. With no hover responders in the rows the
/// same fling costs half the main-thread time and holds the display's full
/// rate. See `SidebarFrameRateBenchmark`.
///
/// Rows register their frames here instead, in the list's coordinate space, so
/// a pointer move costs one lookup and only re-renders the rows it entered or
/// left. Scrolling drops hover until the list comes to rest, as native lists do.
@MainActor
final class SidebarHoverTracker {
    nonisolated static let coordinateSpace = "sidebarHover"

    private struct Target {
        var frame: CGRect
        var perform: (Bool) -> Void
        var isHovered = false
    }

    private var targets: [UUID: Target] = [:]
    private var pointer: CGPoint?
    private var scrollOffset: CGFloat?
    private var isScrolling = false
    private var settle: Timer?
    /// Where the pointer is right now, for when a scroll comes to rest. Set by
    /// the tracking view.
    var currentPointer: () -> CGPoint? = { nil }
    /// False for a list that is not the one on screen, such as a Space page
    /// parked beside the sidebar, whose tracking area can overlap other panes.
    var isEnabled = true {
        didSet { if isEnabled != oldValue { reconcileAll() } }
    }
    private let settleDelay: TimeInterval

    init(settleDelay: TimeInterval = 0.12) {
        self.settleDelay = settleDelay
    }

    func update(_ id: UUID, frame: CGRect, perform: @escaping (Bool) -> Void) {
        var target = targets[id] ?? Target(frame: frame, perform: perform)
        target.frame = frame
        target.perform = perform
        targets[id] = target
        reconcile(id)
    }

    /// A row that left the list has no hover state left to clear.
    func remove(_ id: UUID) {
        targets[id] = nil
    }

    func pointerMoved(to point: CGPoint) {
        pointer = point
        guard !isScrolling else { return }
        reconcileAll()
    }

    func pointerExited() {
        pointer = nil
        reconcileAll()
    }

    /// Call with every scroll geometry update; only a moved offset counts.
    func scrolled(to offset: CGFloat) {
        defer { scrollOffset = offset }
        guard let scrollOffset, scrollOffset != offset else { return }
        if !isScrolling {
            isScrolling = true
            reconcileAll()
        }
        guard settleDelay > 0 else { return }
        // Reused rather than replaced: this runs on every scroll frame.
        if let settle {
            settle.fireDate = Date().addingTimeInterval(settleDelay)
        } else {
            let timer = Timer(timeInterval: settleDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollSettled() }
            }
            RunLoop.main.add(timer, forMode: .common)
            settle = timer
        }
    }

    func scrollSettled() {
        settle?.invalidate()
        settle = nil
        isScrolling = false
        pointer = currentPointer()
        reconcileAll()
    }

    private func reconcileAll() {
        for id in targets.keys { reconcile(id) }
    }

    private func reconcile(_ id: UUID) {
        guard var target = targets[id] else { return }
        let hovered = isEnabled && !isScrolling && pointer.map(target.frame.contains) == true
        guard hovered != target.isHovered else { return }
        target.isHovered = hovered
        targets[id] = target
        target.perform(hovered)
    }
}

extension EnvironmentValues {
    @Entry var sidebarHoverTracker: SidebarHoverTracker? = nil
}

extension View {
    /// Makes this view the list `tracker` serves: its rows' `.sidebarHover`
    /// report here, in this view's coordinates.
    func sidebarHoverTracking(_ tracker: SidebarHoverTracker) -> some View {
        environment(\.sidebarHoverTracker, tracker)
            .coordinateSpace(.named(SidebarHoverTracker.coordinateSpace))
            .background { SidebarHoverTrackingView(tracker: tracker) }
    }

    /// `.onHover` for a row of a list with a `SidebarHoverTracker`, and plain
    /// `.onHover` anywhere else.
    func sidebarHover(perform: @escaping (Bool) -> Void) -> some View {
        modifier(SidebarHoverModifier(perform: perform))
    }
}

private struct SidebarHoverModifier: ViewModifier {
    let perform: (Bool) -> Void
    @Environment(\.sidebarHoverTracker) private var tracker
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if let tracker {
            content
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(SidebarHoverTracker.coordinateSpace))
                } action: { frame in
                    tracker.update(id, frame: frame, perform: perform)
                }
                .onDisappear { tracker.remove(id) }
        } else {
            content.onHover(perform: perform)
        }
    }
}

/// The one tracking area, drawn behind the list's content.
private struct SidebarHoverTrackingView: NSViewRepresentable {
    let tracker: SidebarHoverTracker

    func makeNSView(context: Context) -> SidebarHoverTrackingBackingView {
        let view = SidebarHoverTrackingBackingView()
        view.tracker = tracker
        tracker.currentPointer = { [weak view] in view?.pointerInVisibleRect }
        return view
    }

    func updateNSView(_ nsView: SidebarHoverTrackingBackingView, context: Context) {}
}

final class SidebarHoverTrackingBackingView: NSView {
    weak var tracker: SidebarHoverTracker?

    /// Matches SwiftUI's top-left origin, so frames compare directly.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        tracker?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        tracker?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        tracker?.pointerExited()
    }

    var pointerInVisibleRect: CGPoint? {
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return visibleRect.contains(point) ? point : nil
    }
}
