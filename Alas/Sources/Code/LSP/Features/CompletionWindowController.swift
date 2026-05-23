import AppKit
import SwiftUI

@MainActor
final class CompletionWindowController {
    static let panelHidesOnDeactivate = true

    private final class CompletionPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let maxHeight: CGFloat = 260
    private let listWidth: CGFloat = 320
    private let screenPadding: CGFloat = 6
    private let caretGap: CGFloat = 4

    private var panel: CompletionPanel?
    private var hostingController: NSHostingController<CompletionPopup>?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(
        rows: [CompletionPopupRow],
        selection: Int,
        documentation: MarkdownRenderResult?,
        theme: Theme,
        anchor: NSRect,
        in textView: CodeTextView,
        onChoose: @escaping (Int) -> Void
    ) {
        let hasDocumentation = (documentation?.attributedString.length ?? 0) > 0
        let size = NSSize(width: hasDocumentation ? listWidth * 2 : listWidth, height: maxHeight)
        let root = CompletionPopup(rows: rows, selection: selection, documentation: documentation, theme: theme, onChoose: onChoose)
        let panel = ensurePanel(size: size)
        hostingController?.rootView = root
        panel.setFrame(frame(for: size, anchor: anchor, in: textView), display: true, animate: false)

        attach(panel, to: textView.window)
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

    private func ensurePanel(size: NSSize) -> CompletionPanel {
        if let panel {
            return panel
        }

        let hostingController = NSHostingController(
            rootView: CompletionPopup(
                rows: [],
                selection: 0,
                documentation: nil,
                theme: (try? Theme.loadBundled(id: "cool-slate")) ?? Theme(id: "fallback", name: "Fallback", tokens: [:]),
                onChoose: { _ in }
            )
        )
        let panel = CompletionPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .normal
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = Self.panelHidesOnDeactivate
        self.hostingController = hostingController
        self.panel = panel
        return panel
    }

    func attach(_ panel: NSWindow, to parentWindow: NSWindow?) {
        guard let parentWindow else { return }

        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.level = parentWindow.level
    }

    private func frame(for size: NSSize, anchor: NSRect, in textView: CodeTextView) -> NSRect {
        guard let window = textView.window else {
            return NSRect(origin: .zero, size: size)
        }

        let windowRect = textView.convert(anchor, to: nil)
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
