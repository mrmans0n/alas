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
        attach(container, mayStealFromOtherContainer: true)
        return container
    }

    @MainActor
    func updateNSView(_ nsView: NSView, context: Context) {
        // updateNSView is a passenger: it may NOT steal the surface from another
        // container. During a structural transition (e.g. split→leaf collapse),
        // SwiftUI fires a final updateNSView on the about-to-dismantle GhosttyHost
        // before its dismantleNSView runs. The newly-made GhosttyHost has already
        // adopted the surface — re-parenting it back here would orphan the surface
        // during the imminent dismantle. Only makeNSView claims ownership.
        attach(nsView, mayStealFromOtherContainer: false)
    }

    @MainActor
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }

    @MainActor
    private func attach(_ container: NSView, mayStealFromOtherContainer: Bool) {
        for subview in container.subviews where subview !== session.surface {
            subview.removeFromSuperview()
        }

        if session.surface.superview !== container {
            if session.surface.superview != nil && !mayStealFromOtherContainer {
                // Another container owns the surface; we're a stale updateNSView.
                return
            }
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
        DispatchQueue.main.async { [weak container] in
            guard let container, container.window?.firstResponder !== session.surface else { return }
            container.window?.makeFirstResponder(session.surface)
        }
    }
}
