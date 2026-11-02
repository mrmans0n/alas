import AppKit
import SwiftUI
import Virtualization

/// Hosts a VM tab's cached `VZVirtualMachineView` inside SwiftUI. The view is
/// never recreated while the tab is open: it moves between containers when
/// the tab is switched away and back, like `GhosttyHost` does for terminals,
/// so the live screen survives tab switches.
///
/// While `allowsInput` is false the screen is look-only: a shield above the
/// view swallows the mouse, the view gives up the keyboard, and a click calls
/// `onBlockedClick`.
///
/// `onUserInput` hears, at most once a second, that a key or mouse event reached the guest.
struct VMDisplaySurface: NSViewRepresentable {
    let view: VZVirtualMachineView
    let virtualMachine: VZVirtualMachine?
    var allowsInput = true
    var onBlockedClick: () -> Void = {}
    var onUserInput: (() -> Void)?

    func makeCoordinator() -> VMInputShield { VMInputShield() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(container, shield: context.coordinator, mayStealFromOtherContainer: true)
        // Keyboard input goes to the guest once the screen is shown.
        DispatchQueue.main.async { [weak container, weak shield = context.coordinator, view] in
            guard let container, let shield, view.superview === container,
                  container.window?.firstResponder !== view
            else { return }
            // Look-only: the guest gets the keyboard once input comes back.
            guard shield.isHidden else {
                shield.tookKeyboard = true
                return
            }
            container.window?.makeFirstResponder(view)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only makeNSView claims the view; a stale container getting a final
        // update before it is dismantled must not take it back.
        attach(nsView, shield: context.coordinator, mayStealFromOtherContainer: false)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: VMInputShield) {
        coordinator.stopWatchingInput()
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(_ container: NSView, shield: VMInputShield, mayStealFromOtherContainer: Bool) {
        for subview in container.subviews where subview !== view && subview !== shield {
            subview.removeFromSuperview()
        }
        if view.superview !== container {
            if view.superview != nil && !mayStealFromOtherContainer { return }
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            // Below a shield already in place, which must stay on top.
            container.addSubview(view, positioned: .below, relativeTo: shield.superview === container ? shield : nil)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        if view.virtualMachine !== virtualMachine {
            view.virtualMachine = virtualMachine
        }
        guard view.superview === container else { return }
        if shield.superview !== container {
            shield.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(shield, positioned: .above, relativeTo: view)
            NSLayoutConstraint.activate([
                shield.topAnchor.constraint(equalTo: container.topAnchor),
                shield.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                shield.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                shield.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        shield.onClick = onBlockedClick
        shield.watchInput(onUserInput)
        shield.isHidden = allowsInput
        // Tracking areas reach the view under the shield, so the guest pointer would follow a
        // hover; VZ may add them back on layout, so they go on every update.
        shield.screen = view
        if !allowsInput {
            shield.removeScreenTracking()
        } else if shield.trackingRemoved {
            view.updateTrackingAreas()
        }
        shield.trackingRemoved = !allowsInput
        guard let window = container.window else { return }
        if !allowsInput, window.firstResponder === view {
            window.makeFirstResponder(nil)
            shield.tookKeyboard = true
        } else if allowsInput, shield.tookKeyboard {
            shield.tookKeyboard = false
            // Back to the guest, unless something else took the keyboard meanwhile.
            if window.firstResponder === window { window.makeFirstResponder(view) }
        }
    }
}

/// A clear view over a look-only VM screen: it takes every click and scroll
/// so none reaches the guest, and never takes the keyboard.
final class VMInputShield: NSView {
    var onClick: () -> Void = {}
    /// The screen gave up the keyboard on going look-only, so it takes it back after.
    var tookKeyboard = false
    /// The screen's tracking areas were removed while look-only.
    var trackingRemoved = false
    /// The VM view under the shield.
    weak var screen: NSView?
    private var onUserInput: (() -> Void)?
    private var inputMonitor: Any?
    private var lastInputNote = Date.distantPast

    /// Watches this window's events for those that reach the guest, while `onUserInput` is set.
    func watchInput(_ onUserInput: (() -> Void)?) {
        self.onUserInput = onUserInput
        guard onUserInput != nil else { return stopWatchingInput() }
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel]
        ) { [weak self] event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated { self?.noteIfItReachesTheGuest(event) }
            return event
        }
    }

    func stopWatchingInput() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    private func noteIfItReachesTheGuest(_ event: NSEvent) {
        // Look-only: the shield swallows it.
        guard isHidden, let onUserInput, let screen, let window = screen.window, event.window === window else { return }
        let now = Date()
        guard now.timeIntervalSince(lastInputNote) >= 1 else { return }
        let reaches = if event.type == .keyDown {
            window.firstResponder === screen
        } else {
            screen.bounds.contains(screen.convert(event.locationInWindow, from: nil))
        }
        guard reaches else { return }
        lastInputNote = now
        onUserInput()
    }

    func removeScreenTracking() {
        guard let screen else { return }
        screen.trackingAreas.forEach(screen.removeTrackingArea)
    }

    // A resize lets VZ add its tracking areas back; the shield is laid out with it.
    override func layout() {
        super.layout()
        if !isHidden { removeScreenTracking() }
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDragged(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
}
