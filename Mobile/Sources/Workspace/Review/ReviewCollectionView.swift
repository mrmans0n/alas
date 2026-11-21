import AlasHighlight
import AlasRemoteKit
import SwiftUI
import UIKit

/// Every file of a review in one list: a pinned header per file, then its hunks and lines.
struct ReviewCollectionView: UIViewControllerRepresentable {
    let document: ReviewDocument
    let wraps: Bool

    func makeUIViewController(context: Context) -> ReviewCollectionController {
        ReviewCollectionController(document: document)
    }

    /// Reads the document's state, so SwiftUI calls this again whenever it changes.
    func updateUIViewController(_ controller: ReviewCollectionController, context: Context) {
        controller.apply(wraps: wraps)
    }
}

final class ReviewCollectionController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    private let document: ReviewDocument
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ReviewEntryID, ReviewRow>!
    private var wraps = true
    private var focused = false

    /// What each section was last drawn from; a change redraws its rows.
    private struct Drawn: Equatable {
        let content: ReviewEntryContent
        let folded: Bool
        let hasSpans: Bool
    }
    private var drawn: [ReviewEntryID: Drawn] = [:]
    private var sectionRows: [ReviewEntryID: [ReviewRow]] = [:]
    private var sectionIDs: [ReviewEntryID] = []
    private var entryIndex: [ReviewEntryID: Int] = [:]
    /// Per entry: where each hunk's first line sits in its spans, and the gutter's digits.
    private var metrics: [ReviewEntryID: (starts: [Int], digits: Int)] = [:]

    /// Scroll mode's sideways offset per file, and each file's widest line.
    private var offsets: [ReviewEntryID: CGFloat] = [:]
    private var widest: [ReviewEntryID: CGFloat] = [:]
    private var panning: (id: ReviewEntryID, start: CGFloat, limit: CGFloat)?

    init(document: ReviewDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: Self.layout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        view.addSubview(collectionView)

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            guard let self else { return }
            Task {
                await self.document.refresh()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh

        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.delegate = self
        collectionView.addGestureRecognizer(pan)

        makeDataSource()
        document.scrollTo = { [weak self] in self?.scroll(to: $0) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.reconfigureAll() }
    }

    private static func layout() -> UICollectionViewCompositionalLayout {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.headerMode = .supplementary
        config.headerTopPadding = 0
        config.backgroundColor = .clear
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            for item in section.boundarySupplementaryItems { item.pinToVisibleBounds = true }
            return section
        }
    }

    private func makeDataSource() {
        let hunkHeader = UICollectionView.CellRegistration<HunkHeaderCell, ReviewRow> { [weak self] cell, _, row in
            guard let self, case .hunkHeader(let id, let h) = row, let hunk = hunks(id)?[safe: h] else { return }
            cell.configure(header: hunk.header, menu: menu(id, index: h, hunk))
        }
        let line = UICollectionView.CellRegistration<LineCell, ReviewRow> { [weak self] cell, _, row in
            guard let self, case .line(let id, let h, let l) = row, let hunk = hunks(id)?[safe: h],
                  let diffLine = hunk.lines[safe: l], let metric = metrics[id] else { return }
            let entrySpans = entry(id).flatMap(document.spanKey).flatMap { self.document.spans[$0] } ?? []
            let tokens = collectionView.traitCollection.userInterfaceStyle == .dark ? ThemeTokens.dark : ThemeTokens.light
            cell.configure(diffLine, spans: entrySpans[safe: metric.starts[h] + l] ?? [], digits: metric.digits,
                           wraps: wraps, offset: offsets[id] ?? 0, tokens: tokens)
        }
        let note = UICollectionView.CellRegistration<NoteCell, ReviewRow> { cell, _, row in
            switch row {
            case .note(_, let text): cell.configure(text)
            default: cell.configure("Loading…")
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            switch row {
            case .hunkHeader: collectionView.dequeueConfiguredReusableCell(using: hunkHeader, for: indexPath, item: row)
            case .line: collectionView.dequeueConfiguredReusableCell(using: line, for: indexPath, item: row)
            case .placeholder, .note, .comment: collectionView.dequeueConfiguredReusableCell(using: note, for: indexPath, item: row)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<FileHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            self?.configure(view, section: indexPath.section)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func entry(_ id: ReviewEntryID) -> ReviewEntry? {
        entryIndex[id].map { document.entries[$0] }
    }

    private func hunks(_ id: ReviewEntryID) -> [RemoteDiffHunk]? {
        guard case .hunks(let hunks, _)? = entry(id)?.content else { return nil }
        return hunks
    }

    private func configure(_ view: FileHeaderView, section: Int) {
        guard let entry = document.entries[safe: section] else { return }
        let id = entry.id
        view.configure(entry, folded: document.folded.contains(id), isViewed: document.isViewed(entry),
                       onFold: { [weak self] in self?.document.toggleFolded(id) },
                       onViewed: { [weak self] in self?.document.toggleViewed(id) })
    }

    /// Built when it opens, so it reflects a git action still running.
    private func menu(_ id: ReviewEntryID, index: Int, _ hunk: RemoteDiffHunk) -> UIMenu? {
        guard !document.hunkActions(id).isEmpty else { return nil }
        return UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let busy = document.gitBusy
            let items: [UIMenuElement] = document.hunkActions(id).map { action in
                let item: UIAction = switch action {
                case .stage: UIAction(title: "Stage Hunk", image: UIImage(systemName: "plus.circle")) { [weak self] _ in
                        self?.run(.stage, id, index, hunk)
                    }
                case .unstage: UIAction(title: "Unstage Hunk", image: UIImage(systemName: "minus.circle")) { [weak self] _ in
                        self?.run(.unstage, id, index, hunk)
                    }
                case .discard: UIAction(title: "Discard Hunk…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                        self?.confirmDiscard(id, index, hunk)
                    }
                }
                if busy { item.attributes.insert(.disabled) }
                return item
            }
            completion(items)
        }])
    }

    private func run(_ action: RemoteHunkAction, _ id: ReviewEntryID, _ index: Int, _ hunk: RemoteDiffHunk) {
        Task { await document.changeHunk(action, entry: id, index: index, hunk) }
    }

    private func confirmDiscard(_ id: ReviewEntryID, _ index: Int, _ hunk: RemoteDiffHunk) {
        let alert = UIAlertController(title: "Discard this hunk?", message: "Its changes are lost.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in self?.run(.discard, id, index, hunk) })
        present(alert, animated: true)
    }

    // MARK: Applying the document

    func apply(wraps: Bool) {
        let entries = document.entries
        // Headers read the marks; reading them here asks SwiftUI to call again when they change.
        _ = document.marks
        let wrapsChanged = wraps != self.wraps
        self.wraps = wraps
        entryIndex = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var restyled: [ReviewEntryID] = []
        var reshaped: [ReviewEntryID] = []
        for entry in entries {
            let id = entry.id
            let state = Drawn(content: entry.content, folded: document.folded.contains(id),
                              hasSpans: document.spanKey(entry).map { document.spans[$0] != nil } ?? false)
            guard drawn[id] != state else { continue }
            if drawn[id]?.content != state.content {
                widest[id] = nil
                metrics[id] = Self.measure(entry.content)
            }
            drawn[id] = state
            let rows = ReviewLayout.rows(for: entry, folded: state.folded)
            if rows == sectionRows[id] { restyled.append(id) } else { reshaped.append(id) }
            sectionRows[id] = rows
        }
        let ids = entries.map(\.id)
        let stale = wrapsChanged ? ids : restyled
        if ids != sectionIDs {
            sectionIDs = ids
            var snapshot = NSDiffableDataSourceSnapshot<ReviewEntryID, ReviewRow>()
            snapshot.appendSections(ids)
            for id in ids { snapshot.appendItems(sectionRows[id] ?? [], toSection: id) }
            snapshot.reconfigureItems(stale.flatMap { sectionRows[$0] ?? [] })
            dataSource.apply(snapshot, animatingDifferences: false)
        } else {
            for id in reshaped {
                var section = NSDiffableDataSourceSectionSnapshot<ReviewRow>()
                section.append(sectionRows[id] ?? [])
                dataSource.apply(section, to: id, animatingDifferences: false)
            }
            if !stale.isEmpty {
                var snapshot = dataSource.snapshot()
                snapshot.reconfigureItems(stale.flatMap { sectionRows[$0] ?? [] })
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            if let view = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath)
                as? FileHeaderView { configure(view, section: indexPath.section) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Once there are rows and room to show them.
        guard !focused, !sectionIDs.isEmpty, collectionView.bounds.height > 0 else { return }
        focused = true
        if let focus = document.focus { scroll(to: focus) }
    }

    private static func measure(_ content: ReviewEntryContent) -> (starts: [Int], digits: Int) {
        guard case .hunks(let hunks, _) = content else { return ([], 0) }
        let starts = hunks.reduce(into: [0]) { $0.append($0.last! + $1.lines.count) }
        let largest = hunks.flatMap(\.lines).map { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0
        return (starts, String(largest).count)
    }

    private func reconfigureAll() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: Scrolling

    /// Puts the entry's header at the top of the list.
    private func scroll(to id: ReviewEntryID) {
        guard let section = sectionIDs.firstIndex(of: id) else { return }
        // Twice: rows between here and there self-size on the way and move the target.
        for _ in 0 ..< 2 {
            collectionView.layoutIfNeeded()
            let header = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))
            let y: CGFloat
            if collectionView.numberOfItems(inSection: section) > 0,
               let first = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: section)) {
                // A pinned header's frame is where it's pinned; the first row sits right under where it belongs.
                y = first.frame.minY - (header?.frame.height ?? 0)
            } else if let header {
                y = header.frame.minY
            } else { return }
            let inset = collectionView.adjustedContentInset
            let top = -inset.top
            let bottom = max(top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
            collectionView.setContentOffset(CGPoint(x: 0, y: min(max(y - inset.top, top), bottom)), animated: false)
        }
        reportCurrent()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportCurrent()
    }

    /// The entry whose header (or row) is at the top of the list.
    private func reportCurrent() {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(
            in: CGRect(x: 0, y: top, width: collectionView.bounds.width, height: 1)) ?? []
        let section = attributes.first { $0.representedElementCategory == .supplementaryView }?.indexPath.section
            ?? attributes.first?.indexPath.section
        guard let section, let id = sectionIDs[safe: section], document.current != id else { return }
        // Not during a SwiftUI update, which a scroll from `apply` is part of.
        Task { self.document.current = id }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Not during a SwiftUI update, which `apply`'s layout pass is part of.
        if case .placeholder(let id)? = dataSource.itemIdentifier(for: indexPath) { Task { self.document.load(id) } }
    }

    // MARK: Scroll mode's sideways pan

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, pan.view == collectionView else { return true }
        let velocity = pan.velocity(in: collectionView)
        guard !wraps, abs(velocity.x) > abs(velocity.y),
              let indexPath = collectionView.indexPathForItem(at: pan.location(in: collectionView)),
              let id = sectionIDs[safe: indexPath.section],
              let codeWidth = visibleLineCells(in: indexPath.section).first?.codeClip.bounds.width else { return false }
        let limit = max(0, widestLine(id) - codeWidth)
        guard limit > 0 else { return false }
        panning = (id, offsets[id] ?? 0, limit)
        return true
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard let panning, let section = sectionIDs.firstIndex(of: panning.id) else { return }
        let offset = min(max(panning.start - gesture.translation(in: collectionView).x, 0), panning.limit)
        offsets[panning.id] = offset
        for cell in visibleLineCells(in: section) { cell.codeOffset = offset }
        if gesture.state == .ended || gesture.state == .cancelled { self.panning = nil }
    }

    private func visibleLineCells(in section: Int) -> [LineCell] {
        collectionView.indexPathsForVisibleItems.filter { $0.section == section }
            .compactMap { collectionView.cellForItem(at: $0) as? LineCell }
    }

    /// ponytail: measures the line with the most characters, which misjudges wide glyphs (CJK, emoji)
    /// and tabs; measure every line if that clips real code.
    private func widestLine(_ id: ReviewEntryID) -> CGFloat {
        if let known = widest[id] { return known }
        let longest = hunks(id)?.flatMap(\.lines).max { $0.text.utf16.count < $1.text.utf16.count }?.text ?? ""
        let width = ceil((longest as NSString).size(withAttributes: [.font: ReviewMetrics.codeFont]).width)
        widest[id] = width
        return width
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
