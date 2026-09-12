import AppKit
import Combine

@MainActor
final class CodeEditorScrollView: MinimapScrollView {
    private weak var observedStorage: NSTextStorage?
    private var observers: [AnyCancellable] = []
    private var pendingDrawing: DispatchWorkItem?
    private var minimapTheme: Theme?

    func configureMinimap(shown: Bool, theme: Theme) {
        let wasShown = showsMinimap
        showsMinimap = shown
        guard shown, let textView = documentView as? NSTextView else {
            stopObserving()
            minimap.update(drawing: MinimapDrawing())
            return
        }
        minimap.backgroundColor = NSColor(theme.color("bg-1"))
        minimap.indicatorColor = NSColor(theme.color("fg-muted"))
        if !minimap.preservesLineScale { minimap.preservesLineScale = true }
        minimap.onNavigate = { [weak self] value in
            guard let self, let documentView = self.documentView else { return }
            let maximum = max(0, documentView.frame.height - self.contentView.bounds.height)
            self.contentView.scroll(to: NSPoint(x: self.contentView.bounds.minX, y: CGFloat(value) * maximum))
            self.reflectScrolledClipView(self.contentView)
            self.updateMinimapViewport()
        }
        if observedStorage !== textView.textStorage || !wasShown {
            stopObserving()
            observedStorage = textView.textStorage
            let center = NotificationCenter.default
            if let storage = textView.textStorage {
                observers.append(center.publisher(for: NSTextStorage.didProcessEditingNotification, object: storage).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleDrawing() }
                })
            }
            contentView.postsBoundsChangedNotifications = true
            textView.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.boundsDidChangeNotification, contentView as NSView),
                                   (NSView.frameDidChangeNotification, textView as NSView)] {
                observers.append(center.publisher(for: name, object: object).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateMinimapViewport() }
                })
            }
            scheduleDrawing()
        }
        if minimapTheme != theme {
            minimapTheme = theme
            scheduleDrawing()
        }
        updateMinimapViewport()
    }

    private func scheduleDrawing() {
        guard showsMinimap, pendingDrawing == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDrawing = nil
            guard self.showsMinimap, let storage = self.observedStorage else { return }
            self.minimap.update(drawing: MinimapDrawing.editorText(storage))
            self.updateMinimapViewport()
        }
        pendingDrawing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func updateMinimapViewport() {
        guard showsMinimap, let documentView else { return }
        let height = max(1, documentView.frame.height)
        let viewport = contentView.bounds.height
        minimap.proportion = min(1, viewport / height)
        minimap.value = Double(max(0, contentView.bounds.minY) / max(1, height - viewport))
    }

    private func stopObserving() {
        pendingDrawing?.cancel()
        pendingDrawing = nil
        observers.removeAll()
        observedStorage = nil
    }

}
