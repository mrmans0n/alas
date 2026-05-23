import AppKit
import Foundation

/// ⌘-hover affordance. While the user holds ⌘, mouse-move events trigger
/// debounced `textDocument/definition` queries; when LSP returns at least
/// one location, the symbol under the cursor is underlined and the cursor
/// is swapped to `.pointingHand`. Any of (⌘ released, mouse exits the
/// view, cursor moves to a no-result position, request fails) clears the
/// underline.
@MainActor
final class HoverHighlightFeature {
    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?

    private var commandHeld: Bool = false
    private(set) var lastUnderlinedRange: NSRange?
    private var inFlight: Task<Void, Never>?

    private let debounceNanos: UInt64 = 80_000_000 // 80 ms

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        // Chain all three handlers so coexisting features (HoverFeature's
        // ⌥-peek) keep receiving their events. Coordinator constructs
        // HoverFeature first, then this feature — without chaining we'd
        // silently replace the prior closures.
        let priorFlags = textView.flagsChangedHandler
        textView.flagsChangedHandler = { [weak self] event in
            priorFlags?(event)
            self?.onFlagsChanged(event)
        }
        let priorExit = textView.mouseExitedHandler
        textView.mouseExitedHandler = { [weak self] in
            priorExit?()
            guard let self else { return }
            self.cancelInFlight()
            self.clearUnderline()
        }
        let priorHover = textView.hoverHandler
        textView.hoverHandler = { [weak self] p in
            priorHover?(p)
            self?.onMove(at: p)
        }
    }

    private func onFlagsChanged(_ event: NSEvent) {
        let pressed = event.modifierFlags.contains(.command)
        if pressed && !commandHeld {
            simulateCommandPressed()
        } else if !pressed && commandHeld {
            simulateCommandReleased()
        }
    }

    // MARK: - Internal seams (also used by tests)

    func simulateCommandPressed() {
        commandHeld = true
    }

    func simulateCommandReleased() {
        commandHeld = false
        cancelInFlight()
        clearUnderline()
        restoreCursor()
    }

    func simulateMouseMoved(at point: NSPoint) {
        onMove(at: point)
    }

    /// Cancel any in-flight LSP request and remove the underline + cursor
    /// affordance. Does NOT change `commandHeld`, so a still-held ⌘ key
    /// will resume normal hover behavior on the next mouse move.
    func cancelAndClear() {
        cancelInFlight()
        clearUnderline()
    }

    private func onMove(at point: NSPoint) {
        guard commandHeld else { return }
        cancelInFlight()
        guard let textView else { return }
        guard let client = getClient(), let uri = getURI() else {
            clearUnderline()
            return
        }
        guard let position = textView.lspPosition(at: point) else {
            clearUnderline()
            return
        }
        inFlight = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 0)
            guard !Task.isCancelled, let self else { return }
            let locations: [LSPLocation] = (try? await client.definition(uri: uri, position: position)) ?? []
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                if locations.isEmpty {
                    self.clearUnderline()
                    return
                }
                self.applyUnderline(at: position)
            }
        }
    }

    private func applyUnderline(at position: LSPPosition) {
        guard let textView, let storage = textView.textStorage,
              let layoutManager = textView.layoutManager else { return }
        let nsString = storage.string as NSString
        // Compute UTF-16 offset for `position`.
        var offset = 0
        var line = 0
        while line < position.line {
            let r = nsString.range(of: "\n", options: [], range: NSRange(location: offset, length: nsString.length - offset))
            if r.location == NSNotFound { return }
            offset = r.location + 1
            line += 1
        }
        offset += position.character
        guard offset < nsString.length else { return }
        let wordRange = nsString.rangeOfWord(at: offset)
        clearUnderline()
        if wordRange.length == 0 { return }
        layoutManager.addTemporaryAttributes(
            [.underlineStyle: NSUnderlineStyle.single.rawValue],
            forCharacterRange: wordRange
        )
        lastUnderlinedRange = wordRange
        NSCursor.pointingHand.set()
    }

    private func clearUnderline() {
        defer { restoreCursor() }
        guard let textView, let layoutManager = textView.layoutManager,
              let range = lastUnderlinedRange else {
            lastUnderlinedRange = nil
            return
        }
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        lastUnderlinedRange = nil
    }

    private func restoreCursor() {
        NSCursor.iBeam.set()
    }

    private func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
    }
}
