import AppKit
import Combine

@MainActor
final class CodeEditorScrollView: MinimapScrollView {
    private weak var observedStorage: NSTextStorage?
    private var observers: [AnyCancellable] = []
    private var pendingDrawing: DispatchWorkItem?
    private var minimapTheme: Theme?

    override var minimapBackgroundMaterial: NSVisualEffectView.Material? { .contentBackground }

    func configureMinimap(shown: Bool, theme: Theme) {
        let wasShown = showsMinimap
        showsMinimap = shown
        guard shown, let textView = documentView as? CodeTextView else {
            stopObserving()
            minimap.update(drawing: MinimapDrawing())
            return
        }
        minimap.backgroundColor = .clear
        minimap.indicatorColor = NSColor(theme.color("fg-muted"))
        if !minimap.preservesLineScale { minimap.preservesLineScale = true }
        minimap.onNavigate = { [weak self] value in
            guard let self, let view = self.documentView as? CodeTextView else { return }
            let maximumY = max(0, view.frame.height - self.contentView.bounds.height)
            let lastPosition = view.sourceLinePosition(atViewY: maximumY)
            let position = max(0, min(1, value)) * lastPosition
            let line = Int(position)
            let top = view.sourceLineY(line) ?? maximumY
            let bottom = view.sourceLineY(line + 1) ?? view.frame.height
            let y = min(maximumY, top + CGFloat(position - Double(line)) * (bottom - top))
            self.contentView.scroll(to: NSPoint(x: self.contentView.bounds.minX, y: y))
            self.reflectScrolledClipView(self.contentView)
            self.updateMinimapViewport()
        }
        let sourceStorage = textView.displayAdapter?.buffer.storage ?? textView.textStorage
        if observedStorage !== sourceStorage || !wasShown {
            stopObserving()
            observedStorage = sourceStorage
            let center = NotificationCenter.default
            if let storage = sourceStorage {
                observers.append(center.publisher(for: NSTextStorage.didProcessEditingNotification, object: storage).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleDrawing() }
                })
            }
            observers.append(center.publisher(for: .editorDisplayProjectionDidChange, object: textView).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMinimapViewport() }
            })
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
        guard showsMinimap, let view = documentView as? CodeTextView else { return }
        let first = view.sourceLinePosition(atViewY: contentView.bounds.minY)
        let last = view.sourceLinePosition(atViewY: contentView.bounds.maxY)
        let maximum = view.sourceLinePosition(atViewY: max(0, view.frame.height - contentView.bounds.height))
        minimap.proportion = min(1, CGFloat(last - first) / CGFloat(max(1, view.sourceLineStarts.count)))
        minimap.value = maximum > 0 ? min(1, max(0, first / maximum)) : 0
    }

    private func stopObserving() {
        pendingDrawing?.cancel()
        pendingDrawing = nil
        observers.removeAll()
        observedStorage = nil
    }
}
