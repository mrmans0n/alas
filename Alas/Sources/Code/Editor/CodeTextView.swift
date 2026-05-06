import AppKit

/// Read-only `NSTextView` subclass that exposes mouse hover and Cmd-click
/// callbacks. The coordinator wires the callbacks; this class itself stays
/// dumb so it can be unit-tested in isolation if needed.
final class CodeTextView: NSTextView {
    var hoverHandler: ((NSPoint) -> Void)?
    var commandClickHandler: ((NSPoint) -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        self.isEditable = false
        self.isSelectable = true
        self.isRichText = false
        self.allowsUndo = false
        self.usesFindBar = true
        self.isAutomaticQuoteSubstitutionEnabled = false
        self.isAutomaticDashSubstitutionEnabled = false
        self.isAutomaticTextReplacementEnabled = false
        self.textContainerInset = NSSize(width: 12, height: 8)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        hoverHandler?(p)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            commandClickHandler?(p)
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }
}
