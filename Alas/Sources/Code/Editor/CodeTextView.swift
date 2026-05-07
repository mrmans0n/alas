import AppKit

/// Editable `NSTextView` subclass. The coordinator wires hover and
/// Cmd-click callbacks; the storage is owned and managed by an
/// `EditorBuffer` outside this view. Editing is enabled but undo/redo,
/// dirty tracking, save, file-watch, and LSP `didChange` are all
/// orchestrated by the buffer + coordinator pair.
final class CodeTextView: NSTextView {
    var hoverHandler: ((NSPoint) -> Void)?
    var commandClickHandler: ((NSPoint) -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        self.isEditable = true
        self.isSelectable = true
        self.allowsUndo = true
        self.isRichText = false
        self.usesFindBar = true
        self.isAutomaticQuoteSubstitutionEnabled = false
        self.isAutomaticDashSubstitutionEnabled = false
        self.isAutomaticTextReplacementEnabled = false
        self.isAutomaticSpellingCorrectionEnabled = false
        self.isContinuousSpellCheckingEnabled = false
        self.isGrammarCheckingEnabled = false
        self.smartInsertDeleteEnabled = false
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
