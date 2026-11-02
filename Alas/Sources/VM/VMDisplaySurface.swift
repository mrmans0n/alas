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
struct VMDisplaySurface: NSViewRepresentable {
    let view: VZVirtualMachineView
    let virtualMachine: VZVirtualMachine?
    var allowsInput = true
    var onBlockedClick: () -> Void = {}

    func makeCoordinator() -> VMInputShield { VMInputShield() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(container, shield: context.coordinator, mayStealFromOtherContainer: true)
        // Keyboard input goes to the guest once the screen is shown.
        DispatchQueue.main.async { [weak container, weak shield = context.coordinator, view] in
            guard let container, let shield, shield.isHidden, view.superview === container,
                  container.window?.firstResponder !== view
            else { return }
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
            container.addSubview(view)
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
        shield.isHidden = allowsInput
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
