import AppKit
import SwiftUI

/// Owns the live `ACPTranscriptRowHostingView`s, keyed by row id. Views are
/// reused across layout passes; rootView is only replaced when the row's
/// equality token changes, mirroring the legacy `.equatable()` gating. Released
/// views are parked in an LRU cache for reuse when rows return with unchanged content.
@MainActor
final class ACPTranscriptRowHostingPool {
    /// How many released rows keep their built hosting view, so scrolling back
    /// to them reattaches the view instead of rebuilding its SwiftUI graph.
    /// Zero disables parking entirely.
    static let parkedCapacity = 48

    var onRowIntrinsicSizeInvalidated: ((String) -> Void)?

    private struct Entry {
        let view: ACPTranscriptRowHostingView
        var token: ACPRowEqualityToken
    }

    private let parkedCapacity: Int
    private var entries: [String: Entry] = [:]
    /// Released rows, detached and silenced, most recently released last.
    private var parked: [String: Entry] = [:]
    private var parkedOrder: [String] = []

    init(parkedCapacity: Int = ACPTranscriptRowHostingPool.parkedCapacity) {
        self.parkedCapacity = max(0, parkedCapacity)
    }

    var mountedIds: Set<String> { Set(entries.keys) }

    /// The live hosting view for `id`, or nil when the row currently has
    /// none. Unlike `view(for:)` this never CREATES one, so callers can ask
    /// "is this row's content already measured at the current width?"
    /// without paying for a hosting view they may not need.
    func mountedView(id: String) -> ACPTranscriptRowHostingView? {
        entries[id]?.view
    }

    func view(for spec: ACPTranscriptRowSpec) -> (view: ACPTranscriptRowHostingView, contentChanged: Bool) {
        if var entry = entries[spec.id] {
            if entry.token.isEqual(to: spec.equalityToken) {
                return (entry.view, false)
            }
            entry.view.updateRootView(spec.build())
            entry.token = spec.equalityToken
            entries[spec.id] = entry
            return (entry.view, true)
        }
        if let parkedEntry = unpark(id: spec.id) {
            if parkedEntry.token.isEqual(to: spec.equalityToken) {
                attachCallback(to: parkedEntry.view, id: spec.id)
                parkedEntry.view.markNeedsRemeasure()
                entries[spec.id] = parkedEntry
                return (parkedEntry.view, true)
            }
            // Different content under the same id: drop the stale view.
        }
        let view = ACPTranscriptRowHostingView(rootView: spec.build())
        attachCallback(to: view, id: spec.id)
        entries[spec.id] = Entry(view: view, token: spec.equalityToken)
        return (view, true)
    }

    func release(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        // AppKit can retain the detached graph and invalidate it during teardown.
        // Retiring a row must end its ability to change transcript geometry.
        entry.view.onIntrinsicSizeInvalidated = nil
        entry.view.removeFromSuperview()
        park(entry, id: id)
    }

    func releaseAll(except keep: Set<String> = []) {
        for id in entries.keys where !keep.contains(id) {
            release(id: id)
        }
    }

    /// Drops every parked view, so the next mount of each row builds fresh.
    func purgeParked() {
        parked.removeAll()
        parkedOrder.removeAll()
    }

    /// Drops parked views whose rows are no longer in the transcript: they can
    /// never be revived, so keeping them alive is pure waste.
    func dropParked(notIn ids: Set<String>) {
        guard parked.keys.contains(where: { !ids.contains($0) }) else { return }
        parked = parked.filter { ids.contains($0.key) }
        parkedOrder.removeAll { !ids.contains($0) }
    }

    #if DEBUG
    var parkedIdsForTesting: Set<String> { Set(parked.keys) }
    #endif

    private func attachCallback(to view: ACPTranscriptRowHostingView, id: String) {
        view.onIntrinsicSizeInvalidated = { [weak self] in
            self?.onRowIntrinsicSizeInvalidated?(id)
        }
    }

    private func park(_ entry: Entry, id: String) {
        guard parkedCapacity > 0 else { return }
        parked[id] = entry
        parkedOrder.removeAll { $0 == id }
        parkedOrder.append(id)
        while parkedOrder.count > parkedCapacity {
            parked.removeValue(forKey: parkedOrder.removeFirst())
        }
    }

    private func unpark(id: String) -> Entry? {
        guard let entry = parked.removeValue(forKey: id) else { return nil }
        parkedOrder.removeAll { $0 == id }
        return entry
    }
}
