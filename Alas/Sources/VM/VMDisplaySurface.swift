import AppKit
import SwiftUI
import Virtualization

/// Hosts a VM tab's cached `VZVirtualMachineView` inside SwiftUI. The view is
/// never recreated while the tab is open: it moves between containers when
/// the tab is switched away and back, like `GhosttyHost` does for terminals,
/// so the live screen survives tab switches.
struct VMDisplaySurface: NSViewRepresentable {
    let view: VZVirtualMachineView
    let virtualMachine: VZVirtualMachine?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(container, mayStealFromOtherContainer: true)
        // Keyboard input goes to the guest once the screen is shown.
        DispatchQueue.main.async { [weak container, view] in
            guard let container, view.superview === container,
                  container.window?.firstResponder !== view
            else { return }
            container.window?.makeFirstResponder(view)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only makeNSView claims the view; a stale container getting a final
        // update before it is dismantled must not take it back.
        attach(nsView, mayStealFromOtherContainer: false)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(_ container: NSView, mayStealFromOtherContainer: Bool) {
        for subview in container.subviews where subview !== view {
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
    }
}
