import SwiftUI
import AppKit

/// Hosts an existing AlasGhostty.SurfaceView (already attached to a TerminalSession)
/// inside SwiftUI. The surface is never recreated — we move it between containers
/// when the active tab changes. `isFocused` controls whether this host promotes
/// the surface to first responder on attach; with multiple panes per tab, only
/// the focused leaf should grab keyboard focus.
struct GhosttyHost: NSViewRepresentable {
    let session: TerminalSession
    var isFocused: Bool = true

    @MainActor
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(container)
        return container
    }

    @MainActor
    func updateNSView(_ nsView: NSView, context: Context) {
        attach(nsView)
    }

    @MainActor
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }

    @MainActor
    private func attach(_ container: NSView) {
        for subview in container.subviews where subview !== session.surface {
            subview.removeFromSuperview()
        }

        if session.surface.superview !== container {
            session.surface.removeFromSuperview()
            session.surface.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(session.surface)
            NSLayoutConstraint.activate([
                session.surface.topAnchor.constraint(equalTo: container.topAnchor),
                session.surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                session.surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                session.surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        guard isFocused else { return }
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(session.surface)
        }
    }
}
