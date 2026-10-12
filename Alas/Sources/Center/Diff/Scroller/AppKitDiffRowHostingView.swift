import AppKit
import SwiftUI

/// Width-aware SwiftUI host for a single diff row.
@MainActor
final class AppKitDiffRowHostingView: NSHostingView<AnyView>, AppKitDiffRowView {
    var representedRowID: String?
    var onIntrinsicSizeInvalidated: ((String) -> Void)?

    private var baseRootView: AnyView
    private(set) var lastMeasuredWidth: CGFloat?
    private(set) var layoutPassCountForTests = 0
    private(set) var measureCountForTests = 0
    private var hasLaidOutCurrentRootView = false
    private var suppressesNextStableLayout = false
    private var isMeasuringOrAttaching = false

    required init(rootView: AnyView) {
        baseRootView = rootView
        super.init(rootView: rootView)
        translatesAutoresizingMaskIntoConstraints = false
        sizingOptions = [.intrinsicContentSize]
        // Rows sit inside a scroll view, never against a window edge. With
        // safe-area tracking on, every scroll tick re-derived each mounted
        // row's (always empty) insets.
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        if suppressesNextStableLayout {
            suppressesNextStableLayout = false
            return
        }
        layoutPassCountForTests += 1
        super.layout()
        hasLaidOutCurrentRootView = true
    }

    override func invalidateIntrinsicContentSize() {
        suppressesNextStableLayout = false
        hasLaidOutCurrentRootView = false
        super.invalidateIntrinsicContentSize()
        // Measuring re-roots the view and attaching it re-resolves its window
        // environment; both invalidate synchronously, and the height the
        // caller is about to read already accounts for them.
        if !isMeasuringOrAttaching, let representedRowID {
            onIntrinsicSizeInvalidated?(representedRowID)
        }
    }

    func updateRootView(_ newRootView: AnyView) {
        suppressesNextStableLayout = false
        hasLaidOutCurrentRootView = false
        baseRootView = newRootView
        if let lastMeasuredWidth {
            rootView = AnyView(newRootView.frame(width: lastMeasuredWidth, alignment: .topLeading))
        } else {
            rootView = newRootView
        }
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        measureCountForTests += 1
        suppressesNextStableLayout = false
        hasLaidOutCurrentRootView = false
        isMeasuringOrAttaching = true
        defer { isMeasuringOrAttaching = false }
        rootView = AnyView(baseRootView.frame(width: width, alignment: .topLeading))
        lastMeasuredWidth = width
        return intrinsicContentSize.height
    }

    /// Adds the row to `documentView` without reporting the intrinsic-size
    /// invalidation that joining a window triggers. A row with unchanged
    /// content and width keeps its measured height; anything else is
    /// measured by the caller right after.
    func attach(to documentView: NSView) {
        isMeasuringOrAttaching = true
        defer { isMeasuringOrAttaching = false }
        documentView.addSubview(self)
    }

    func suppressNextLayoutForStableScroll() {
        guard hasLaidOutCurrentRootView else { return }
        suppressesNextStableLayout = true
    }
}
