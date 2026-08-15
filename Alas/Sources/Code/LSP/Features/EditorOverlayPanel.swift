import AppKit

@MainActor
final class EditorOverlayPanel {
    static let hidesOnDeactivate = true

    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let screenPadding: CGFloat = 6
    private let caretGap: CGFloat = 4

    private var panel: OverlayPanel?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    /// The panel's frame in screen coordinates, or nil if not visible.
    /// Used by callers (e.g. HoverFeature) to perform their own
    /// hit-testing against the overlay independent of any tracking area.
    var screenFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    func show(
        contentViewController: NSViewController,
        size: NSSize,
        anchor: NSRect,
        in hostView: NSView
    ) {
        let panel = ensurePanel(size: size)
        panel.contentViewController = contentViewController
        panel.setFrame(frame(for: size, anchor: anchor, in: hostView), display: true, animate: false)
        attach(panel, to: hostView.window)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    func hide() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
        }
        panel?.orderOut(nil)
    }

    private func ensurePanel(size: NSSize) -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .normal
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = Self.hidesOnDeactivate
        // Required so NSEvent.addLocalMonitorForEvents(.mouseMoved) fires
        // for cursor motion over the panel. Without this AppKit suppresses
        // mouseMoved delivery to non-key panels and the hover-over-panel
        // detection breaks.
        panel.acceptsMouseMovedEvents = true
        self.panel = panel
        return panel
    }

    private func attach(_ panel: NSWindow, to parentWindow: NSWindow?) {
        guard let parentWindow else { return }
        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.level = parentWindow.level
    }

    func frame(for size: NSSize, anchor: NSRect, in hostView: NSView) -> NSRect {
        guard let window = hostView.window else {
            return NSRect(origin: .zero, size: size)
        }

        let windowRect = hostView.convert(anchor, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? screenRect
        let x = min(
            max(screenRect.minX, visibleFrame.minX + screenPadding),
            visibleFrame.maxX - size.width - screenPadding
        )
        let belowY = screenRect.minY - size.height - caretGap
        let aboveY = screenRect.maxY + caretGap
        let y: CGFloat
        if belowY >= visibleFrame.minY + screenPadding {
            y = belowY
        } else {
            y = min(aboveY, visibleFrame.maxY - size.height - screenPadding)
        }

        return NSRect(
            x: x,
            y: max(y, visibleFrame.minY + screenPadding),
            width: size.width,
            height: size.height
        )
    }
}

enum EditorOverlayPanelTesting {
    @MainActor
    static func frame(for panel: EditorOverlayPanel, size: NSSize, anchor: NSRect, in hostView: NSView) -> NSRect {
        panel.frame(for: size, anchor: anchor, in: hostView)
    }
}
