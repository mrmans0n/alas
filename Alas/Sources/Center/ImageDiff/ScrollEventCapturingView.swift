import AppKit
import SwiftUI

/// Thin `NSViewRepresentable` whose underlying NSView intercepts
/// scroll-wheel events and forwards their deltas. SwiftUI on macOS does
/// not surface raw scroll-wheel events to gesture modifiers, so we drop
/// down to AppKit for this one piece.
struct ScrollEventCapturingView: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat, Bool) -> Void
    // (deltaX, deltaY, modifierFlagsContainsCommand)

    static func shouldCaptureScroll(
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        modifierFlags.contains(.command)
    }

    func makeNSView(context: Context) -> Backing {
        let v = Backing()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: Backing, context: Context) {
        nsView.onScroll = onScroll
    }

    final class Backing: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        private var eventMonitor: Any?
        override var acceptsFirstResponder: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            installEventMonitor()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            installEventMonitor()
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func scrollWheel(with event: NSEvent) {
            guard ScrollEventCapturingView.shouldCaptureScroll(
                modifierFlags: event.modifierFlags
            ) else {
                nextResponder?.scrollWheel(with: event)
                return
            }

            onScroll?(
                event.scrollingDeltaX,
                event.scrollingDeltaY,
                true
            )
        }

        private func installEventMonitor() {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.window === self.window,
                      bounds.contains(convert(event.locationInWindow, from: nil)),
                      ScrollEventCapturingView.shouldCaptureScroll(modifierFlags: event.modifierFlags)
                else { return event }
                onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, true)
                return nil
            }
        }
    }
}
