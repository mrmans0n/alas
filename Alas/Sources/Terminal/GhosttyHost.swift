import SwiftUI
import AppKit

/// Hosts an existing AlasGhostty.SurfaceView (already attached to a TerminalSession)
/// inside SwiftUI. The surface is never recreated — we move it between containers
/// when the active tab changes.
struct GhosttyHost: NSViewRepresentable {
    let session: TerminalSession

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
    private func attach(_ container: NSView) {
        // Detach surface from previous superview if any
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
        // Make the surface first responder when displayed
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(session.surface)
        }
    }
}
