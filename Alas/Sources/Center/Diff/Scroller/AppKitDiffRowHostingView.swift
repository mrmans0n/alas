import AppKit
import SwiftUI

/// Width-aware SwiftUI host for a single diff row.
@MainActor
final class AppKitDiffRowHostingView: NSHostingView<AnyView> {
    var representedRowID: String?
    var onIntrinsicSizeInvalidated: ((String) -> Void)?

    private var baseRootView: AnyView
    private(set) var lastMeasuredWidth: CGFloat?
    private(set) var layoutPassCountForTests = 0
    private var hasLaidOutCurrentRootView = false
    private var suppressesNextStableLayout = false

    required init(rootView: AnyView) {
        baseRootView = rootView
        super.init(rootView: rootView)
        translatesAutoresizingMaskIntoConstraints = false
        sizingOptions = [.intrinsicContentSize]
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
        if let representedRowID {
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
        suppressesNextStableLayout = false
        hasLaidOutCurrentRootView = false
        rootView = AnyView(baseRootView.frame(width: width, alignment: .topLeading))
        lastMeasuredWidth = width
        return intrinsicContentSize.height
    }

    func suppressNextLayoutForStableScroll() {
        guard hasLaidOutCurrentRootView else { return }
        suppressesNextStableLayout = true
    }
}
