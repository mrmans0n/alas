import AppKit
import Markdown
import SwiftUI

@MainActor
final class HoverFeature {
    typealias RequestHover = (_ uri: String, _ position: LSPPosition) async throws -> LSPHoverResult?

    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?
    private let getTheme: () -> Theme
    private let getMonoFontFamily: () -> String
    private let getMonoFontSize: () -> Int
    private let requestHover: RequestHover

    private let windowController = HoverWindowController()
    private var requestID: UInt64 = 0
    private var inFlight: Task<Void, Never>?
    private var dwellTimer: Task<Void, Never>?
    private var graceTimer: Task<Void, Never>?
    private var mouseMonitor: Any?

    private var optionHeld: Bool = false
    private var lastMousePoint: NSPoint?
    private var currentSymbolRange: NSRange?
    private var shownSymbolRange: NSRange?
    /// Last screen location we observed for the pointer. When the panel is
    /// shown we install an NSEvent monitor that updates this on every
    /// mouse-move; combined with the symbol's screen rect and the panel's
    /// screen frame, we decide whether to keep the popover or dismiss.
    private var lastScreenLocation: NSPoint?

    private static let dwellNanos: UInt64 = 750_000_000 // 750 ms
    /// Grace window for the pointer to bridge the gap between the symbol in
    /// the editor and the overlay panel (and vice versa) before we dismiss.
    private static let graceNanos: UInt64 = 500_000_000 // 500 ms

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?,
        getTheme: @escaping () -> Theme,
        getMonoFontFamily: @escaping () -> String,
        getMonoFontSize: @escaping () -> Int,
        requestHover: RequestHover? = nil
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        self.getTheme = getTheme
        self.getMonoFontFamily = getMonoFontFamily
        self.getMonoFontSize = getMonoFontSize
        self.requestHover = requestHover ?? { uri, position in
            guard let client = getClient() else { return nil }
            return try await client.hover(uri: uri, position: position)
        }

        let priorHover = textView.hoverHandler
        textView.hoverHandler = { [weak self] p in
            priorHover?(p)
            self?.onMouseMoved(at: p)
        }
        let priorFlags = textView.flagsChangedHandler
        textView.flagsChangedHandler = { [weak self] event in
            priorFlags?(event)
            self?.onFlagsChanged(event)
        }
        let priorExit = textView.mouseExitedHandler
        textView.mouseExitedHandler = { [weak self] in
            priorExit?()
            self?.onMouseExited()
        }
    }

    var isShowingPopover: Bool { windowController.isVisible }

    func tearDown() {
        dismiss()
    }

    // MARK: - Coordinator-facing notify entry points

    func notifyScrolled() { dismiss() }
    func notifyCaretChanged() { dismiss() }
    func notifyWindowResized() { dismiss() }

    /// Returns true if the popover was visible and consumed the Esc key.
    func handleEscape() -> Bool {
        guard isShowingPopover else { return false }
        dismiss()
        return true
    }

    // MARK: - Event entry points

    private func onMouseMoved(at point: NSPoint) {
        lastMousePoint = point
        let newRange = textView?.symbolRange(at: point)
        if newRange == currentSymbolRange { return }
        currentSymbolRange = newRange

        if let shownSymbolRange {
            if newRange == shownSymbolRange {
                // Back on the shown symbol — pre-empt any grace dismissal.
                cancelGrace()
                return
            }
            if let newRange {
                // Cursor moved to a DIFFERENT identifier while a popover is
                // up. Treat as intent to leave: dismiss the old immediately
                // and start a fresh dwell for the new symbol.
                cancelGrace()
                inFlight?.cancel()
                inFlight = nil
                dwellTimer?.cancel()
                dwellTimer = nil
                uninstallMouseMonitor()
                windowController.hide()
                self.shownSymbolRange = nil
                currentSymbolRange = newRange
                if optionHeld {
                    issueRequest(at: point)
                } else {
                    startDwellTimer(at: point)
                }
                return
            }
            // Cursor moved off the shown symbol into non-identifier
            // territory (still inside the editor). Could be in transit to
            // the panel — schedule a grace dismiss. The NSEvent monitor
            // will cancel it if the pointer enters the panel's screen
            // frame, and `onMouseMoved` will cancel it if the cursor
            // returns to the shown symbol.
            scheduleGraceDismiss()
            return
        }

        // No popover shown yet — standard dwell / immediate logic.
        inFlight?.cancel()
        inFlight = nil
        dwellTimer?.cancel()
        dwellTimer = nil
        guard newRange != nil else { return }
        if optionHeld {
            issueRequest(at: point)
        } else {
            startDwellTimer(at: point)
        }
    }

    private func onMouseExited() {
        // Mouse left the editor. Don't dismiss yet — the pointer may be on
        // its way to the overlay panel. The NSEvent monitor installed when
        // the popover is shown will decide based on screen-coord hit-testing.
        scheduleGraceDismiss()
    }

    private func onFlagsChanged(_ event: NSEvent) {
        let pressed = event.modifierFlags.contains(.option)
        if pressed && !optionHeld {
            optionHeld = true
            if let point = lastMousePoint, currentSymbolRange != nil {
                dwellTimer?.cancel()
                issueRequest(at: point)
            }
        } else if !pressed && optionHeld {
            optionHeld = false
            // Releasing ⌥ does NOT dismiss — dismissal is governed by the
            // symbol-tracking and forced-dismiss rules only.
        }
    }

    // MARK: - Test seams

    func simulateOptionPressed() {
        guard !optionHeld else { return }
        optionHeld = true
        if let point = lastMousePoint, currentSymbolRange != nil {
            dwellTimer?.cancel()
            issueRequest(at: point)
        }
    }

    func simulateOptionReleased() {
        guard optionHeld else { return }
        optionHeld = false
    }

    func simulateMouseMoved(at point: NSPoint) {
        onMouseMoved(at: point)
    }

    /// Test seam: simulates an NSEvent mouseMoved at a global screen point
    /// for the hit-test path used while the popover is shown.
    func simulatePointerScreenLocation(_ location: NSPoint) {
        lastScreenLocation = location
        evaluatePointerLocation(location)
    }

    // MARK: - Dwell timer

    private func startDwellTimer(at point: NSPoint) {
        dwellTimer?.cancel()
        let capturedRange = currentSymbolRange
        dwellTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.dwellNanos)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.currentSymbolRange != nil,
                      self.currentSymbolRange == capturedRange
                else { return }
                self.issueRequest(at: point)
            }
        }
    }

    private func dismiss() {
        dwellTimer?.cancel()
        dwellTimer = nil
        inFlight?.cancel()
        inFlight = nil
        cancelGrace()
        uninstallMouseMonitor()
        windowController.hide()
        shownSymbolRange = nil
        currentSymbolRange = nil
        lastScreenLocation = nil
    }

    private func scheduleGraceDismiss() {
        // Nothing to dismiss if we never showed anything.
        guard isShowingPopover || shownSymbolRange != nil else { return }
        graceTimer?.cancel()
        graceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.graceNanos)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Re-check the cursor location at fire time. If by now it's
                // over the symbol or the overlay panel, keep the popover up.
                if let location = self.lastScreenLocation, self.pointerIsInSafeArea(location) {
                    return
                }
                self.dismiss()
            }
        }
    }

    private func cancelGrace() {
        graceTimer?.cancel()
        graceTimer = nil
    }

    // MARK: - NSEvent monitor for pointer hit-testing while shown

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        // Seed the location so the first grace-timer fire has something to
        // hit-test even if the cursor is stationary.
        lastScreenLocation = NSEvent.mouseLocation
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            let location = NSEvent.mouseLocation
            self.lastScreenLocation = location
            self.evaluatePointerLocation(location)
            return event
        }
    }

    private func uninstallMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
    }

    /// Returns true if the global screen point lies inside the symbol's
    /// screen rect, the overlay panel's frame, or the corridor between
    /// them. The corridor makes the symbol→panel transit forgiving against
    /// slow movement and small lateral jitter; without it, anything off-
    /// axis during transit immediately schedules a grace dismiss.
    private func pointerIsInSafeArea(_ location: NSPoint) -> Bool {
        let panelFrame = windowController.screenFrame
        let symbolFrame = currentSymbolScreenRect()
        if let panelFrame, panelFrame.contains(location) { return true }
        if let symbolFrame, symbolFrame.contains(location) { return true }
        if let panelFrame, let symbolFrame,
           bridgeRect(symbolFrame: symbolFrame, panelFrame: panelFrame).contains(location) {
            return true
        }
        return false
    }

    /// Returns the rectangular corridor between the symbol and the panel,
    /// covering the gap that the cursor crosses during a normal mouse trip.
    /// Width is the union of the symbol and panel widths so off-axis drift
    /// stays inside; height is the vertical gap between them (zero if they
    /// overlap or touch).
    private func bridgeRect(symbolFrame: NSRect, panelFrame: NSRect) -> NSRect {
        let leftX = min(symbolFrame.minX, panelFrame.minX)
        let rightX = max(symbolFrame.maxX, panelFrame.maxX)
        let bottomY: CGFloat
        let topY: CGFloat
        if panelFrame.maxY <= symbolFrame.minY {
            // Panel sits below the symbol (default placement).
            bottomY = panelFrame.maxY
            topY = symbolFrame.minY
        } else if panelFrame.minY >= symbolFrame.maxY {
            // Panel was flipped above the symbol.
            bottomY = symbolFrame.maxY
            topY = panelFrame.minY
        } else {
            // Overlapping — no bridge strip.
            return .zero
        }
        return NSRect(
            x: leftX,
            y: bottomY,
            width: rightX - leftX,
            height: max(0, topY - bottomY)
        )
    }

    /// Translates the currently shown symbol's anchor rect into screen
    /// coordinates so we can do hit-testing against the global cursor.
    private func currentSymbolScreenRect() -> NSRect? {
        guard let textView,
              let window = textView.window,
              let symbolRange = shownSymbolRange ?? currentSymbolRange,
              let anchor = textView.symbolAnchorRect(for: symbolRange) else { return nil }
        let windowRect = textView.convert(anchor, to: nil)
        return window.convertToScreen(windowRect)
    }

    /// Called for every mouse-moved event while the popover is shown.
    /// Cancels any pending grace dismiss if the cursor is on the symbol or
    /// the overlay; schedules a grace dismiss if it's strayed off both.
    private func evaluatePointerLocation(_ location: NSPoint) {
        if pointerIsInSafeArea(location) {
            cancelGrace()
        } else if graceTimer == nil {
            scheduleGraceDismiss()
        }
    }

    // MARK: - Request dispatch

    private func issueRequest(at point: NSPoint) {
        guard let textView, let uri = getURI(),
              let symbolRange = currentSymbolRange,
              let position = textView.lspPosition(at: point) else {
            return
        }
        requestID &+= 1
        let currentRequestID = requestID
        inFlight?.cancel()
        let perform = requestHover
        inFlight = Task { [weak self] in
            let result: LSPHoverResult?
            do {
                result = try await perform(uri, position)
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.isCurrentRequest(currentRequestID, uri: uri, symbolRange: symbolRange)
                    else { return }
                    self.windowController.hide()
                    self.shownSymbolRange = nil
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
                      self.isCurrentRequest(currentRequestID, uri: uri, symbolRange: symbolRange)
                else { return }
                self.handleResult(result, symbolRange: symbolRange)
            }
        }
    }

    private func handleResult(_ result: LSPHoverResult?, symbolRange: NSRange) {
        guard let result, let body = nonEmptyBody(result) else {
            windowController.hide()
            shownSymbolRange = nil
            return
        }
        guard let textView else {
            windowController.hide()
            shownSymbolRange = nil
            return
        }
        let theme = getTheme()
        let family = getMonoFontFamily()
        let size = getMonoFontSize()
        let document = Document(parsing: body)
        let renderResult = MarkdownRenderer().render(
            document: document,
            theme: theme,
            monospacedFontFamily: family,
            monospacedFontSize: size,
            baseDirectory: URL(fileURLWithPath: "/"),
            mermaidProfile: .compact
        )
        let preferredSize = HoverFeatureTesting.computePreferredSize(for: renderResult)
        let anchor = textView.symbolAnchorRect(for: symbolRange)
            ?? CGRect(origin: lastMousePoint ?? .zero, size: .zero)
        windowController.show(
            result: renderResult,
            size: preferredSize,
            theme: theme,
            anchor: anchor,
            in: textView
        )
        shownSymbolRange = symbolRange
        installMouseMonitor()
    }

    private func nonEmptyBody(_ result: LSPHoverResult) -> String? {
        let body: String
        switch result.contents {
        case .markupContent(_, let value): body = value
        case .plain(let s):                body = s
        }
        return body.isEmpty ? nil : body
    }

    private func isCurrentRequest(_ currentRequestID: UInt64, uri: String, symbolRange: NSRange) -> Bool {
        guard !Task.isCancelled,
              requestID == currentRequestID,
              getURI() == uri,
              currentSymbolRange == symbolRange
        else { return false }
        return true
    }
}

enum HoverFeatureTesting {
    @MainActor
    static func makeHoverContainer(result: MarkdownRenderResult, theme: Theme) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        textView.textStorage?.setAttributedString(result.attributedString)
        scrollView.backgroundColor = NSColor(theme.color("bg-1"))
        return scrollView
    }

    static func computePreferredSize(for result: MarkdownRenderResult) -> NSSize {
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage(attributedString: result.attributedString)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.glyphRange(for: textContainer)

        var usedRect = layoutManager.usedRect(for: textContainer)
        usedRect.size.width += 16 + 20
        usedRect.size.height += 16 + 20

        let maxSize = NSSize(width: 520, height: 400)
        return NSSize(
            width: min(usedRect.size.width, maxSize.width),
            height: min(usedRect.size.height, maxSize.height)
        )
    }
}

extension CodeTextView {
    /// Resolves an `LSPPosition` (line, UTF-16 character) for a point in the
    /// view's coordinate space. Returns nil if outside the text area.
    func lspPosition(at point: NSPoint) -> LSPPosition? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let nsString = storage.string as NSString
        guard charIndex < nsString.length else { return nil }
        var line = 0
        var lineStart = 0
        var i = 0
        while i < charIndex {
            if nsString.character(at: i) == 10 {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        return LSPPosition(line: line, character: charIndex - lineStart)
    }

    /// Returns the rect (in view coords) of the character at `position`,
    /// or nil if the position is invalid.
    func firstRect(for position: LSPPosition) -> NSRect? {
        guard let storage = textStorage, let layoutManager else { return nil }
        let nsString = storage.string as NSString
        var charIndex = 0
        var line = 0
        while line < position.line {
            let r = nsString.range(of: "\n", options: [], range: NSRange(location: charIndex, length: nsString.length - charIndex))
            if r.location == NSNotFound { return nil }
            charIndex = r.location + 1
            line += 1
        }
        charIndex += position.character
        guard charIndex < nsString.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: charIndex)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer!)
        return rect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
    }
}
