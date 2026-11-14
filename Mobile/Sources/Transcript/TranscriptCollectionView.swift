import SwiftUI
import UIKit

/// A UICollectionView whose cells host SwiftUI rows. It follows the tail while the reader is at
/// the bottom, keeps the top visible row in place when older rows are prepended, and keeps a
/// tapped row in place when it expands or collapses.
struct TranscriptCollectionView: UIViewControllerRepresentable {
    let items: [TranscriptItem]
    @Binding var expanded: Set<String>
    let canLoadOlder: Bool
    let loadOlder: () -> Void
    var image: (String) -> UIImage? = { _ in nil }
    var onFirstLayout: () -> Void = {}

    init(items: [TranscriptItem], expanded: Binding<Set<String>>, canLoadOlder: Bool,
         loadOlder: @escaping () -> Void, image: @escaping (String) -> UIImage? = { _ in nil },
         onFirstLayout: @escaping () -> Void = {})
    {
        self.items = items
        _expanded = expanded
        self.canLoadOlder = canLoadOlder
        self.loadOlder = loadOlder
        self.image = image
        self.onFirstLayout = onFirstLayout
    }

    func makeUIViewController(context: Context) -> TranscriptCollectionController {
        TranscriptCollectionController(input: input)
    }

    func updateUIViewController(_ controller: TranscriptCollectionController, context: Context) {
        controller.input = input
        controller.sync()
    }

    private var input: TranscriptCollectionController.Input {
        .init(items: items, expanded: $expanded, canLoadOlder: canLoadOlder, loadOlder: loadOlder,
              image: image, onFirstLayout: onFirstLayout)
    }
}

final class TranscriptCollectionController: UIViewController, UICollectionViewDelegate {
    struct Input {
        var items: [TranscriptItem]
        var expanded: Binding<Set<String>>
        var canLoadOlder: Bool
        var loadOlder: () -> Void
        var image: (String) -> UIImage?
        var onFirstLayout: () -> Void
    }

    /// The latest values from SwiftUI; `sync()` brings the collection view in line with them.
    var input: Input
    private var collectionView: PinningCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var itemsByID: [String: TranscriptItem] = [:]
    private var ids: [String] = []
    private var shownExpanded: Set<String> = []
    private var pinned = false
    /// An apply lays out, which can scroll, which must not page in and apply again inside it.
    private var applying = false
    /// Changed only by the reader's own scrolling, never by content growth.
    private var followsTail = true
    /// A row held at a fixed distance from the top of the viewport until the reader scrolls.
    private var anchor: (id: String, screenY: CGFloat)?

    init(input: Input) {
        self.input = input
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let layout = UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group))
        collectionView = PinningCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [unowned self] cell, _, id in
            guard let item = itemsByID[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                TranscriptRowView(item: item, isExpanded: shownExpanded.contains(id), image: input.image) { [unowned self] in
                    input.expanded.wrappedValue.formSymmetricDifference([id])
                    sync()
                }
            }
            .margins(.all, 0)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        collectionView.didLayout = { [unowned self] in holdPosition() }
        view = collectionView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !pinned, collectionView.bounds.height > 0, !ids.isEmpty else { return }
        pinned = true
        scrollToBottom()
        input.onFirstLayout()
    }

    /// Brings the collection view in line with `input`. Toggles call it directly so their offset
    /// compensation lands in the same layout pass as the change; the later SwiftUI update then
    /// finds nothing to do. Only items whose message changed are reconfigured.
    func sync() {
        let items = input.items
        let expanded = input.expanded.wrappedValue
        let newIDs = items.map(\.id)
        var reconfigure: [String] = []
        for item in items {
            guard let old = itemsByID[item.id] else {
                itemsByID[item.id] = item
                continue
            }
            if old.message != item.message {
                itemsByID[item.id] = item
                reconfigure.append(item.id)
            }
        }
        let toggled = expanded.symmetricDifference(shownExpanded)
        guard newIDs != ids || !reconfigure.isEmpty || !toggled.isEmpty else { return }

        let visible = Set(collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) })
        let anchorID: String? = if let tapped = toggled.first(where: visible.contains) {
            tapped
        } else if pinned, newIDs.first != ids.first {
            topVisibleID
        } else {
            nil
        }
        let prepended = anchorID.map { !toggled.contains($0) } ?? false
        if let anchorID, let y = minY(of: anchorID) {
            anchor = (anchorID, y - collectionView.contentOffset.y)
        }

        shownExpanded = expanded
        reconfigure += toggled.filter { itemsByID[$0] != nil }
        var snapshot = dataSource.snapshot()
        if newIDs != ids {
            snapshot = NSDiffableDataSourceSnapshot()
            snapshot.appendSections([0])
            snapshot.appendItems(newIDs)
            ids = newIDs
            // Rows a snapshot replaced must not keep their old items for a later reuse of the id.
            let live = Set(newIDs)
            itemsByID = itemsByID.filter { live.contains($0.key) }
        }
        snapshot.reconfigureItems(reconfigure)
        applying = true
        defer { applying = false }
        dataSource.apply(snapshot, animatingDifferences: false)
        if !toggled.isEmpty {
            // Only the toggled items: a full invalidation drops every measured height back to
            // the estimate and moves everything above the anchor.
            let context = UICollectionViewLayoutInvalidationContext()
            context.invalidateItems(at: toggled.compactMap { dataSource.indexPath(for: $0) })
            collectionView.collectionViewLayout.invalidateLayout(with: context)
        }
        guard pinned else { return }

        // A tap on a row is the reader taking over; the tail must not pull that row away.
        if !toggled.isEmpty, anchorID != nil { followsTail = false }
        // Lays out now, so a prepend is compensated in this same pass; `holdPosition` runs again
        // after any later pass in which hosted cells finish measuring.
        collectionView.layoutIfNeeded()
        // A prepend lands mid-scroll; holding it past this pass would fight the reader's finger.
        if prepended { anchor = nil }
    }

    /// Runs after every collection view layout pass, once cells have measured themselves.
    /// Hosted cells can resize a pass after the update that changed them, and the layout applies
    /// its own offset adjustments, so this restores the anchor's on-screen position (or the tail)
    /// from absolute values rather than adding deltas. Setting the offset lays out again with
    /// nothing left to correct, so it cannot loop.
    private func holdPosition() {
        guard pinned else { return }
        if let anchor, let y = minY(of: anchor.id) {
            let target = y - anchor.screenY
            if abs(collectionView.contentOffset.y - target) > 0.5 { collectionView.contentOffset.y = target }
        } else if followsTail, !collectionView.isTracking, !collectionView.isDecelerating, distanceFromBottom > 0.5 {
            collectionView.contentOffset.y += distanceFromBottom
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        anchor = nil
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        anchor = nil
        followsTail = false
        return true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard pinned, scrollView.isTracking || scrollView.isDecelerating else { return }
        followsTail = distanceFromBottom <= 8
        guard !applying, input.canLoadOlder,
              scrollView.contentOffset.y + scrollView.adjustedContentInset.top < 600 else { return }
        input.loadOlder()
    }

    private var distanceFromBottom: CGFloat {
        collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
            - collectionView.bounds.height - collectionView.contentOffset.y
    }

    private var topVisibleID: String? {
        collectionView.indexPathsForVisibleItems.min().flatMap { dataSource.itemIdentifier(for: $0) }
    }

    private func minY(of id: String) -> CGFloat? {
        dataSource.indexPath(for: id)
            .flatMap { collectionView.layoutAttributesForItem(at: $0)?.frame.minY }
    }

    /// Bounded: each pass measures the rows that scrolled in, which can grow the content again.
    private func scrollToBottom() {
        for _ in 0 ..< 8 {
            collectionView.layoutIfNeeded()
            let target = max(-collectionView.adjustedContentInset.top, collectionView.contentOffset.y + distanceFromBottom)
            if abs(collectionView.contentOffset.y - target) < 0.5 { return }
            collectionView.contentOffset.y = target
        }
    }
}

/// Reports each layout pass so the controller can pin to the tail after cells self-size.
final class PinningCollectionView: UICollectionView {
    var didLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }
}
