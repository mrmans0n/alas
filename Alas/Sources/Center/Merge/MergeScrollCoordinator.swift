import AppKit
import Foundation

/// Single source of truth for synchronized scrolling across the three
/// merge panes. Panes have different row counts (RESULT stacks both sides
/// of every conflict), so each pane keeps its own pixel offset and the
/// coordinator maps the row under the viewport's vertical center through
/// `MergeRegionVisualLayout.Layout.mapRow`. Corresponding hunks line up
/// in the middle of the screen, and scrolling stays continuous through
/// hunks of different heights.
@MainActor
final class MergeScrollCoordinator {
    typealias Source = MergeRegionVisualLayout.Pane

    /// All three panes use the same font and a fixed line height, so a
    /// single row height maps rows to pixels in every pane.
    var rowHeight: CGFloat = 16
    var contentTopInset: CGFloat = 6
    private(set) var viewportHeight: CGFloat = 0
    var layout: MergeRegionVisualLayout.Layout?

    private(set) var offsets: [Source: CGFloat] = [:]

    /// Scrolls a pane's clip view and returns the offset it settled at
    /// (AppKit clamps to the document bounds).
    typealias ScrollHandler = (CGFloat) -> CGFloat

    private var handlers: [Source: ScrollHandler] = [:]
    private var scrollObservers: [UUID: () -> Void] = [:]

    /// Panes currently being moved by a coordinator-driven sync. NSClipView
    /// posts boundsDidChange for programmatic scrolls too; those callbacks
    /// must not be treated as a fresh user scroll.
    private var syncingSources: Set<Source> = []

    func offset(for source: Source) -> CGFloat {
        offsets[source] ?? 0
    }

    func register(_ source: Source, handler: @escaping ScrollHandler) {
        handlers[source] = handler
    }

    /// Called by a pane's bounds observer. User scrolls broadcast to the
    /// other panes; echoes of a coordinator-driven sync only record the
    /// offset.
    func applyPaneY(_ y: CGFloat, source: Source) {
        let previous = offsets[source]
        offsets[source] = y
        guard !syncingSources.contains(source) else { return }
        guard previous.map({ abs($0 - y) > 0.25 }) ?? true else { return }
        broadcast(from: source)
    }

    /// Programmatic scroll (conflict navigation): moves `source` to `y`
    /// and brings the other panes along.
    func scroll(_ source: Source, toY y: CGFloat) {
        sync(max(0, y), to: source)
        broadcast(from: source)
    }

    /// Mapping anchors on the viewport center, so a height change moves the
    /// anchor: re-align the other panes on RESULT.
    func setViewportHeight(_ height: CGFloat) {
        guard abs(height - viewportHeight) > 0.25 else { return }
        viewportHeight = height
        broadcast(from: .result)
    }

    /// Pixel offset `target` needs so it shows the content that sits at
    /// the vertical center of `source` scrolled to `y`.
    func mappedOffset(_ y: CGFloat, from source: Source, to target: Source) -> CGFloat {
        guard let layout, rowHeight > 0 else { return y }
        let anchor = viewportHeight / 2
        let row = Double((y + anchor - contentTopInset) / rowHeight)
        let mapped = layout.mapRow(row, from: source, to: target)
        return max(0, CGFloat(mapped) * rowHeight + contentTopInset - anchor)
    }

    @discardableResult
    func addScrollObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        scrollObservers[id] = observer
        return id
    }

    func removeScrollObserver(_ id: UUID) {
        scrollObservers.removeValue(forKey: id)
    }

    private func broadcast(from source: Source) {
        let y = offset(for: source)
        for target in Source.allCases where target != source {
            sync(mappedOffset(y, from: source, to: target), to: target)
        }
        for observer in scrollObservers.values {
            observer()
        }
    }

    private func sync(_ y: CGFloat, to target: Source) {
        guard let handler = handlers[target] else {
            offsets[target] = y
            return
        }
        syncingSources.insert(target)
        defer { syncingSources.remove(target) }
        offsets[target] = handler(y)
    }
}

/// Shared scroll-sync wiring for a single merge pane's `NSScrollView`:
/// a bounds observer that reports user scrolling into
/// `MergeScrollCoordinator.applyPaneY`, and the handler that moves this
/// pane's clip view when another pane drives the scroll.
@MainActor
final class MergePaneScrollBridge {
    private var tokens: [any NSObjectProtocol] = []

    init(scroll: NSScrollView, source: MergeScrollCoordinator.Source, coordinator: MergeScrollCoordinator) {
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        tokens.append(NotificationCenter.default.addMainActorObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip
        ) { [weak clip] in
            guard let clip else { return }
            coordinator.applyPaneY(clip.bounds.origin.y, source: source)
        })
        tokens.append(NotificationCenter.default.addMainActorObserver(
            forName: NSView.frameDidChangeNotification,
            object: clip
        ) { [weak clip] in
            guard let clip else { return }
            coordinator.setViewportHeight(clip.bounds.height)
        })
        coordinator.setViewportHeight(clip.bounds.height)
        // Weak scroll: handlers live on `coordinator`, which outlives any
        // single pane instance.
        coordinator.register(source) { [weak scroll] y in
            guard let scroll else { return y }
            let clip = scroll.contentView
            let documentHeight = scroll.documentView?.frame.height ?? 0
            let maxY = max(0, documentHeight - clip.bounds.height)
            let clamped = min(max(0, y), maxY)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
            scroll.reflectScrolledClipView(clip)
            return clamped
        }
    }

    isolated deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
