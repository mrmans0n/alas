import AlasHighlight
import AlasRemoteKit
import SwiftUI
import UIKit

/// Every file of a review in one list: a pinned header per file, then its hunks and lines.
struct ReviewCollectionView: UIViewControllerRepresentable {
    let document: ReviewDocument
    let wraps: Bool
    /// The action bar's height: the list runs under it but its last line scrolls clear of it.
    let bottomInset: CGFloat

    func makeUIViewController(context: Context) -> ReviewCollectionController {
        ReviewCollectionController(document: document)
    }

    /// Reads the document's state, so SwiftUI calls this again whenever it changes.
    func updateUIViewController(_ controller: ReviewCollectionController, context: Context) {
        controller.apply(wraps: wraps)
        controller.setBottomInset(bottomInset)
    }
}

final class ReviewCollectionController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    private let document: ReviewDocument
    private var collectionView: UICollectionView!
    private var sidePan: UIPanGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private var press: UILongPressGestureRecognizer!
    private var dataSource: UICollectionViewDiffableDataSource<ReviewEntryID, ReviewRow>!
    private var wraps = true
    private var focused = false

    /// What each section was last drawn from; a change redraws its rows.
    private struct Drawn: Equatable {
        let content: ReviewEntryContent
        let folded: Bool
        let hasSpans: Bool
        let comments: [RemoteReviewComment]
        /// The comments', so a send redraws them.
        let sent: [RemoteReviewSent?]
        let threads: [RemoteProviderThread]
        let selection: ReviewSelection?
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

    /// The comments and threads drawn, by row id, and those whose lines left the diff.
    private var commentsByID: [String: RemoteReviewComment] = [:]
    private var threadsByID: [String: RemoteProviderThread] = [:]
    private var outdated: Set<String> = []
    /// Comments whose quoted code moved, by id: the lines it now sits on.
    private var moved: [String: RemoteReviewAnchor] = [:]
    /// A long press's finger, in the controller's view, and the edge auto-scroll it drives.
    private var pressPoint: CGPoint = .zero
    private var autoScroller: CADisplayLink?
    /// The file last jumped to. It stays the current one, and the jump is redone as rows reshape, until the
    /// user scrolls (a drag, the status bar, the selection's edge auto-scroll): whether its header reached the
    /// top is only known once rows below finish self-sizing, and a file the content ends too soon after never does.
    private var jumpedTo: ReviewEntryID?
    private lazy var pill = makePill()

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

        sidePan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        sidePan.delegate = self
        collectionView.addGestureRecognizer(sidePan)
        // Ours fails at once on vertical motion, so scrolling still starts straight away.
        collectionView.panGestureRecognizer.require(toFail: sidePan)
        // Both begin only on a line of a review that takes comments; the tap only on its numbers.
        tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        collectionView.addGestureRecognizer(tap)
        press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.3
        press.delegate = self
        collectionView.addGestureRecognizer(press)
        collectionView.addSubview(pill)

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
            cell.configure(header: hunk.header, menu: menu(id, index: h))
        }
        let line = UICollectionView.CellRegistration<LineCell, ReviewRow> { [weak self] cell, _, row in
            guard let self, case .line(let id, let h, let l) = row, let hunk = hunks(id)?[safe: h],
                  let diffLine = hunk.lines[safe: l], let metric = metrics[id] else { return }
            let entrySpans = entry(id).flatMap(document.spanKey).flatMap { self.document.spans[$0] } ?? []
            // The controller's traits: a style change reaches it before the collection view, and redraws from there.
            let tokens = traitCollection.userInterfaceStyle == .dark ? ThemeTokens.dark : ThemeTokens.light
            let selection = document.selection
            let selected = selection.map { $0.entry == id && $0.hunk == h && ($0.start ... $0.end).contains(l) } ?? false
            cell.configure(diffLine, spans: entrySpans[safe: metric.starts[h] + l] ?? [], digits: metric.digits,
                           wraps: wraps, offset: offsets[id] ?? 0, tokens: tokens, selected: selected)
            cell.accessibilityCustomActions = document.reviewSessionID == nil ? nil : lineActions(id, hunk: h, line: l)
        }
        let comment = UICollectionView.CellRegistration<ReviewCommentCell, ReviewRow> { [weak self] cell, _, row in
            guard let self, case .comment(_, let cid) = row else { return }
            if let thread = threadsByID[cid] { return configure(cell, thread: thread, outdated: outdated.contains(cid)) }
            guard let comment = commentsByID[cid] else { return }
            var badges: [String] = []
            if !comment.isOpen { badges.append(comment.state.capitalized) }
            if outdated.contains(cid) { badges.append("Outdated") }
            cell.configure(author: comment.author, location: Self.location(moved[cid] ?? comment.anchor), body: comment.body, badges: badges,
                           replies: comment.replies.map { .init(author: $0.author, body: $0.body) }, dimmed: !comment.isOpen,
                           sent: document.sent[cid])
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
            case .comment: collectionView.dequeueConfiguredReusableCell(using: comment, for: indexPath, item: row)
            case .placeholder, .note: collectionView.dequeueConfiguredReusableCell(using: note, for: indexPath, item: row)
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
                       onViewed: { [weak self] in self?.document.toggleViewed(id) },
                       onComment: document.reviewSessionID == nil ? nil : { [weak self] in self?.document.composing = .file(id) })
    }

    /// Built when it opens, so it reflects a git action still running.
    private func menu(_ id: ReviewEntryID, index: Int) -> UIMenu? {
        guard !document.hunkActions(id).isEmpty else { return nil }
        return UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            // The hunk as the menu showed it: a diff refreshed since then makes the host refuse, not act on another hunk.
            guard let self, let hunk = hunks(id)?[safe: index] else { return completion([]) }
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

    func setBottomInset(_ inset: CGFloat) {
        guard collectionView.contentInset.bottom != inset else { return }
        collectionView.contentInset.bottom = inset
        collectionView.verticalScrollIndicatorInsets.bottom = inset
    }

    func apply(wraps: Bool) {
        let entries = document.entries
        // Headers read the marks; reading them here asks SwiftUI to call again when they change.
        _ = document.marks
        // Comments only show where they can be written: the local-changes review.
        let byFile = document.reviewSessionID == nil ? [:] : Dictionary(grouping: document.comments, by: \.fileID)
        commentsByID = Dictionary(document.comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        moved = moved.filter { commentsByID[$0.key] != nil }
        // A pull request's threads by file; a conversation thread, on no file, stays in the Reviews list.
        let threadsByPath = Dictionary(grouping: document.threads.filter { $0.path != nil }, by: { $0.path ?? "" })
        threadsByID = Dictionary(document.threads.map { (Self.rowID($0), $0) }, uniquingKeysWith: { a, _ in a })
        let selection = document.selection
        let wrapsChanged = wraps != self.wraps
        self.wraps = wraps
        entryIndex = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var reshaped: [ReviewEntryID] = []
        // Drawn before: rows are positional, so rows a section keeps across a content, comment or
        // selection change still show the old state.
        var redrawn: [ReviewEntryID] = []
        for entry in entries {
            let id = entry.id
            let comments = byFile[RemoteReviewFileID(namespace: id.namespace, path: id.path)] ?? []
            let threads = threadsByPath[id.path] ?? []
            let state = Drawn(content: entry.content, folded: document.folded.contains(id),
                              hasSpans: document.spanKey(entry).map { document.spans[$0] != nil } ?? false,
                              comments: comments, sent: comments.map { document.sent[$0.id] }, threads: threads,
                              selection: selection?.entry == id ? selection : nil)
            guard drawn[id] != state else { continue }
            if drawn[id] != nil { redrawn.append(id) }
            if drawn[id]?.content != state.content {
                widest[id] = nil
                offsets[id] = nil
                metrics[id] = Self.measure(entry.content)
            }
            drawn[id] = state
            // Without hunks (a note in place of the diff) every comment is unplaced, so shown under the note.
            var hunks: [RemoteDiffHunk] = []
            if case .hunks(let found, _) = entry.content { hunks = found }
            // Threads first: under the same line, the provider's conversation reads before the drafts answering it.
            let placed = ReviewCommentPlacement.place(threads.map(Self.placeable) + comments.map(Self.placeable), in: hunks)
            for (thread, place) in zip(threads, placed) {
                let id = Self.rowID(thread)
                if thread.isOutdated || (place.row == nil && thread.anchor != nil) { outdated.insert(id) } else { outdated.remove(id) }
            }
            for (comment, place) in zip(comments, placed.dropFirst(threads.count)) {
                if place.row == nil, case .line = comment.anchor { outdated.insert(comment.id) } else { outdated.remove(comment.id) }
                if let lines = place.movedTo, case .line(let side, _, _, let quoted) = comment.anchor {
                    moved[comment.id] = .line(side: side, startLine: lines.lowerBound,
                                              endLine: lines.count > 1 ? lines.upperBound : nil, selectedText: quoted)
                } else {
                    moved[comment.id] = nil
                }
            }
            let rows = ReviewLayout.rows(for: entry, folded: state.folded, comments: placed)
            if rows != sectionRows[id] { reshaped.append(id) }
            sectionRows[id] = rows
        }
        let ids = entries.map(\.id)
        let idsChanged = ids != sectionIDs
        if idsChanged {
            sectionIDs = ids
            var snapshot = NSDiffableDataSourceSnapshot<ReviewEntryID, ReviewRow>()
            snapshot.appendSections(ids)
            for id in ids { snapshot.appendItems(sectionRows[id] ?? [], toSection: id) }
            dataSource.apply(snapshot, animatingDifferences: false)
        } else {
            for id in reshaped {
                var section = NSDiffableDataSourceSectionSnapshot<ReviewRow>()
                section.append(sectionRows[id] ?? [])
                dataSource.apply(section, to: id, animatingDifferences: false)
            }
        }
        // Wrapping changes every row's height: keep the row at the top where it is.
        let anchor = wrapsChanged ? topRow() : nil
        // After the shape is applied, so every row reconfigured is in the snapshot.
        let stale = wrapsChanged ? ids : redrawn
        if !stale.isEmpty {
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(stale.flatMap { sectionRows[$0] ?? [] })
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        if let anchor {
            settle { self.dataSource.indexPath(for: anchor).flatMap(self.rowTop) }
            reportCurrent()
        } else if let pending = jumpedTo, idsChanged || !reshaped.isEmpty {
            // Rows landing above or below it move it, or make the room it lacked (the focused file, opened
            // over placeholders).
            scroll(to: pending)
        }
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            if let view = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath)
                as? FileHeaderView { configure(view, section: indexPath.section) }
        }
        placePill()
    }

    private static func placeable(_ comment: RemoteReviewComment) -> ReviewPlaceable {
        guard case .line(let side, let start, let end, let quoted) = comment.anchor else {
            return ReviewPlaceable(id: comment.id, side: nil, line: nil, endLine: nil)
        }
        return ReviewPlaceable(id: comment.id, side: side, line: start, endLine: end, selectedText: quoted)
    }

    private static func rowID(_ thread: RemoteProviderThread) -> String { "thread:" + thread.id }

    /// An outdated thread goes to the top of its file: the provider no longer places it on these lines.
    private static func placeable(_ thread: RemoteProviderThread) -> ReviewPlaceable {
        guard !thread.isOutdated, case .line(let side, let start, let end, _)? = thread.anchor else {
            return ReviewPlaceable(id: rowID(thread), side: nil, line: nil, endLine: nil)
        }
        return ReviewPlaceable(id: rowID(thread), side: side, line: start, endLine: end)
    }

    private func configure(_ cell: ReviewCommentCell, thread: RemoteProviderThread, outdated: Bool) {
        let location = thread.anchor.map(Self.location) ?? "File"
        var badges: [String] = []
        if outdated { badges.append("Outdated") }
        if thread.isResolved { badges.append("Resolved") }
        let first = thread.comments.first
        cell.configure(author: first?.author ?? "Unknown", location: location, body: first?.body ?? "", badges: badges,
                       replies: thread.comments.dropFirst().map { .init(author: $0.author ?? "Unknown", body: $0.body) },
                       dimmed: thread.isResolved || outdated)
    }

    private static func location(_ anchor: RemoteReviewAnchor) -> String {
        switch anchor {
        case .file: return "File"
        case .image: return "Image"
        case .line(let side, let start, let end, _):
            let range = end.flatMap { $0 != start ? "L\(start)\u{2013}\($0)" : nil } ?? "L\(start)"
            return range + (side == "old" ? " (old)" : "")
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

    /// Puts the entry's header at the top of the list, or where the content ends first, as far as it goes;
    /// either way the entry becomes the current one.
    private func scroll(to id: ReviewEntryID) {
        guard let section = sectionIDs.firstIndex(of: id) else { return }
        jumpedTo = id
        settle {
            if self.collectionView.numberOfItems(inSection: section) > 0 { return self.rowTop(IndexPath(item: 0, section: section)) }
            return self.collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))?.frame.minY
        }
        reportCurrent()
    }

    /// Where the list's top edge goes for the row to sit right under its pinned header.
    private func rowTop(_ indexPath: IndexPath) -> CGFloat? {
        guard let row = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
        // A pinned header's frame is where it's pinned, but its height holds.
        let header = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: indexPath.section))
        return row.frame.minY - (header?.frame.height ?? 0)
    }

    /// Scrolls until `target`, a content y read afresh each pass, is the list's top edge, or as near as the
    /// content allows.
    private func settle(at target: () -> CGFloat?) {
        // Until it holds: rows between here and there self-size on the way and move the target.
        for _ in 0 ..< 6 {
            collectionView.layoutIfNeeded()
            guard let y = target() else { break }
            let inset = collectionView.adjustedContentInset
            let top = -inset.top
            let bottom = max(top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
            let wanted = y - inset.top
            let offset = min(max(wanted, top), bottom)
            guard abs(collectionView.contentOffset.y - offset) >= 0.5 else { break }
            collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }
    }

    /// The row just under the pinned header at the list's top.
    private func topRow() -> ReviewRow? {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard let row = collectionView.layoutAttributesForItem(at: indexPath), let y = rowTop(indexPath) else { continue }
            if y + row.frame.height > top + 1 { return dataSource.itemIdentifier(for: indexPath) }
        }
        return nil
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        jumpedTo = nil
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        jumpedTo = nil
        return true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportCurrent()
        // Rows self-size as they scroll in, moving the selection's last line.
        placePill()
    }

    /// The entry whose header (or row) is at the top of the list.
    private func reportCurrent() {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(
            in: CGRect(x: 0, y: top, width: collectionView.bounds.width, height: 1)) ?? []
        let section = attributes.first { $0.representedElementCategory == .supplementaryView }?.indexPath.section
            ?? attributes.first?.indexPath.section
        let reported = jumpedTo.flatMap { sectionIDs.contains($0) ? $0 : nil } ?? section.flatMap { sectionIDs[safe: $0] }
        guard let id = reported, document.current != id else { return }
        // Not during a SwiftUI update, which a scroll from `apply` is part of.
        Task { self.document.current = id }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Not during a SwiftUI update, which `apply`'s layout pass is part of.
        if case .placeholder(let id)? = dataSource.itemIdentifier(for: indexPath) { Task { self.document.load(id) } }
    }

    // MARK: Scroll mode's sideways pan

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === tap || gesture === press {
            let point = gesture.location(in: collectionView)
            guard document.reviewSessionID != nil, let hit = line(at: point) else { return false }
            return gesture === press || hit.cell.isInGutter(hit.cell.convert(point, from: collectionView))
        }
        guard gesture === sidePan, let pan = gesture as? UIPanGestureRecognizer else { return true }
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

// MARK: Selecting and commenting

extension ReviewCollectionController {
    fileprivate func line(at point: CGPoint) -> (id: ReviewEntryID, hunk: Int, line: Int, cell: LineCell)? {
        guard let indexPath = collectionView.indexPathForItem(at: point),
              case .line(let id, let h, let l)? = dataSource.itemIdentifier(for: indexPath),
              let cell = collectionView.cellForItem(at: indexPath) as? LineCell else { return nil }
        return (id, h, l, cell)
    }

    @objc fileprivate func tapped(_ gesture: UITapGestureRecognizer) {
        guard let hit = line(at: gesture.location(in: collectionView)) else { return }
        document.tapLine(hit.id, hunk: hit.hunk, line: hit.line)
    }

    /// Selects the pressed line, then extends to the line under the finger; scrolling and the
    /// sideways pan are off until the finger lifts, so the drag only selects.
    @objc fileprivate func pressed(_ gesture: UILongPressGestureRecognizer) {
        pressPoint = gesture.location(in: view)
        switch gesture.state {
        case .began:
            guard let hit = line(at: gesture.location(in: collectionView)) else { return }
            document.select(hit.id, hunk: hit.hunk, line: hit.line)
            UISelectionFeedbackGenerator().selectionChanged()
            collectionView.panGestureRecognizer.isEnabled = false
            sidePan.isEnabled = false
            let link = CADisplayLink(target: self, selector: #selector(autoScroll(_:)))
            link.add(to: .main, forMode: .common)
            autoScroller = link
        case .changed:
            extendToPress()
        default:
            autoScroller?.invalidate()
            autoScroller = nil
            collectionView.panGestureRecognizer.isEnabled = true
            sidePan.isEnabled = true
        }
    }

    private func extendToPress() {
        guard let hit = line(at: view.convert(pressPoint, to: collectionView)) else { return }
        document.extendSelection(hit.id, hunk: hit.hunk, line: hit.line)
    }

    /// Within 60 pt of the list's top or bottom edge, scrolls that way at up to 900 pt/s, faster the deeper the finger.
    @objc private func autoScroll(_ link: CADisplayLink) {
        let band: CGFloat = 60
        let inset = collectionView.adjustedContentInset
        let visible = collectionView.frame.inset(by: inset)
        let up = visible.minY + band - pressPoint.y
        let down = pressPoint.y - (visible.maxY - band)
        let depth = up > 0 ? -min(up, band) : down > 0 ? min(down, band) : 0
        guard depth != 0 else { return }
        let top = -inset.top
        let bottom = max(top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        let step = 900 * depth / band * CGFloat(link.targetTimestamp - link.timestamp)
        let y = min(max(collectionView.contentOffset.y + step, top), bottom)
        guard y != collectionView.contentOffset.y else { return }
        jumpedTo = nil
        collectionView.contentOffset.y = y
        extendToPress()
    }

    /// VoiceOver's way to select. Rows redraw when the selection changes, so each offers only what applies now.
    fileprivate func lineActions(_ id: ReviewEntryID, hunk: Int, line: Int) -> [UIAccessibilityCustomAction] {
        let selection = document.selection
        var actions = [
            UIAccessibilityCustomAction(name: "Select line") { [weak self] _ in
                self?.document.select(id, hunk: hunk, line: line)
                return true
            },
        ]
        if selection?.entry == id, selection?.hunk == hunk {
            actions.append(UIAccessibilityCustomAction(name: "Extend selection to here") { [weak self] _ in
                self?.document.extendSelection(id, hunk: hunk, line: line)
                return true
            })
        }
        if selection != nil {
            actions.append(UIAccessibilityCustomAction(name: "Comment on selection") { [weak self] _ in
                self?.document.composeSelection()
                return true
            })
        }
        return actions
    }

    fileprivate func makePill() -> UIView {
        var commentStyle = UIButton.Configuration.filled()
        commentStyle.title = "Comment"
        commentStyle.image = UIImage(systemName: "plus.bubble")
        commentStyle.imagePadding = 6
        commentStyle.cornerStyle = .capsule
        let comment = UIButton(configuration: commentStyle, primaryAction: UIAction { [weak self] _ in self?.document.composeSelection() })
        var clearStyle = UIButton.Configuration.gray()
        clearStyle.image = UIImage(systemName: "xmark")
        clearStyle.cornerStyle = .capsule
        let clear = UIButton(configuration: clearStyle, primaryAction: UIAction { [weak self] _ in self?.document.selection = nil })
        clear.accessibilityLabel = "Clear Selection"
        let pill = UIStackView(arrangedSubviews: [clear, comment])
        pill.spacing = 8
        pill.isHidden = true
        // Above the rows and the pinned file headers.
        pill.layer.zPosition = 1000
        return pill
    }

    /// Floats the pill by the selection, at the trailing edge (see `ReviewLayout.selectionPillY`); hidden while its
    /// last line isn't laid out.
    fileprivate func placePill() {
        guard let selection = document.selection,
              let indexPath = dataSource.indexPath(for: .line(entry: selection.entry, hunk: selection.hunk, line: selection.end)),
              let last = collectionView.layoutAttributesForItem(at: indexPath) else {
            pill.isHidden = true
            return
        }
        let size = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let first = dataSource.indexPath(for: .line(entry: selection.entry, hunk: selection.hunk, line: selection.start))
            .flatMap { collectionView.layoutAttributesForItem(at: $0) } ?? last
        // Under the file's pinned header.
        let header = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: indexPath.section))
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top + (header?.frame.height ?? 0)
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        let y = ReviewLayout.selectionPillY(selectionTop: first.frame.minY, selectionBottom: last.frame.maxY,
                                            pillHeight: size.height, visibleTop: visibleTop, visibleBottom: visibleBottom)
        pill.frame = CGRect(x: collectionView.bounds.width - collectionView.safeAreaInsets.right - size.width - 12,
                            y: y, width: size.width, height: size.height)
        pill.isHidden = false
    }

    // MARK: Comment menu

    @objc func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, case .comment(_, let cid)? = dataSource.itemIdentifier(for: indexPaths[0]) else { return nil }
        if let thread = threadsByID[cid] {
            guard let menu = menu(for: thread) else { return nil }
            return UIContextMenuConfiguration(actionProvider: { _ in menu })
        }
        guard let comment = commentsByID[cid] else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.menu(for: comment) })
    }

    /// As the Reviews list's thread rows: reply, resolve or unresolve, as the provider lets the host's user.
    private func menu(for thread: RemoteProviderThread) -> UIMenu? {
        guard let pullRequest = document.pullRequest else { return nil }
        var items: [UIMenuElement] = []
        if pullRequest.canReply, thread.viewerCanReply {
            items.append(UIAction(title: "Reply…", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
                self?.document.composing = .reply(thread)
            })
        }
        if pullRequest.canResolve, thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve {
            items.append(UIAction(title: thread.isResolved ? "Unresolve…" : "Resolve…",
                                  image: UIImage(systemName: thread.isResolved ? "arrow.uturn.backward" : "checkmark")) { [weak self] _ in
                    self?.confirmResolve(thread, poster: pullRequest.poster)
                })
        }
        return items.isEmpty ? nil : UIMenu(children: items)
    }

    private func confirmResolve(_ thread: RemoteProviderThread, poster: String) {
        let resolved = thread.isResolved
        let alert = UIAlertController(title: resolved ? "Unresolve this thread?" : "Resolve this thread?",
                                      message: "It changes on the pull request, as \(poster).", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: resolved ? "Unresolve" : "Resolve", style: .default) { [weak self] _ in
            Task { [weak self] in
                guard let document = self?.document else { return }
                if let message = await document.changeThread(thread, resolved ? .unresolve : .resolve) { document.error = message }
            }
        })
        present(alert, animated: true)
    }

    /// As the Reviews list: edit, resolve and dismiss an open comment; delete any.
    private func menu(for comment: RemoteReviewComment) -> UIMenu {
        var items: [UIMenuElement] = []
        if comment.isOpen {
            items += [
                UIAction(title: "Edit…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.document.composing = .edit(comment) },
                UIAction(title: "Resolve", image: UIImage(systemName: "checkmark")) { [weak self] _ in
                    self?.change(.resolve(commentID: comment.id))
                },
                UIAction(title: "Dismiss", image: UIImage(systemName: "xmark")) { [weak self] _ in
                    self?.change(.dismiss(commentID: comment.id))
                },
            ]
        }
        items.append(UIAction(title: "Delete…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmDelete(comment)
        })
        return UIMenu(children: items)
    }

    private func change(_ mutation: RemoteReviewMutation) {
        Task {
            if let message = await document.change(mutation) { document.error = message }
        }
    }

    private func confirmDelete(_ comment: RemoteReviewComment) {
        let alert = UIAlertController(title: "Delete this comment?", message: "It's deleted on the Mac too.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.change(.delete(commentID: comment.id))
        })
        present(alert, animated: true)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
