import AppKit
import SwiftUI

/// Maintains mounted diff-row hosts, recently released rows parked with
/// their content, and a small pool of blank hosts for reuse.
@MainActor
final class AppKitDiffRowHostingPool {
    var onRowIntrinsicSizeInvalidated: ((String) -> Void)?

    private static let maximumReusableHosts = 32
    /// Released rows kept with their content and measurement, so scrolling
    /// back over them re-attaches a host instead of rebuilding and measuring
    /// it. The default covers a few screens of hunks either side of the
    /// viewport.
    private let maximumParkedHosts: Int

    private struct Entry {
        let view: AppKitDiffRowHostingView
        var token: AppKitDiffRowEqualityToken
    }

    private var entries: [String: Entry] = [:]
    private var parked: [String: Entry] = [:]
    /// Parked row IDs, least recently released first.
    private var parkOrder: [String] = []
    private var reusableViews: [AppKitDiffRowHostingView] = []

    init(maximumParkedHosts: Int = 160) {
        self.maximumParkedHosts = maximumParkedHosts
    }

    var mountedIDs: Set<String> { Set(entries.keys) }
    var parkedIDs: Set<String> { Set(parked.keys) }

    func mountedView(id: String) -> AppKitDiffRowHostingView? {
        entries[id]?.view
    }

    func view(for spec: AppKitDiffRowSpec) -> (view: AppKitDiffRowHostingView, contentChanged: Bool) {
        if var entry = entries[spec.id] ?? unpark(id: spec.id) {
            if !entry.token.isEqual(to: spec.equalityToken) {
                entry.view.updateRootView(spec.build())
                entry.token = spec.equalityToken
                entries[spec.id] = entry
                return (entry.view, true)
            }
            entries[spec.id] = entry
            return (entry.view, false)
        }

        let view: AppKitDiffRowHostingView
        let parkIsFull = parked.count >= maximumParkedHosts
        if let reusedView = reusableViews.popLast() ?? (parkIsFull ? evictOldestParked() : nil) {
            view = reusedView
            view.updateRootView(spec.build())
        } else {
            view = AppKitDiffRowHostingView(rootView: spec.build())
            view.onIntrinsicSizeInvalidated = { [weak self] id in
                self?.onRowIntrinsicSizeInvalidated?(id)
            }
        }
        view.representedRowID = spec.id
        entries[spec.id] = Entry(view: view, token: spec.equalityToken)
        return (view, true)
    }

    func release(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.view.removeFromSuperview()
        parked[id] = entry
        parkOrder.append(id)
        while parked.count > maximumParkedHosts, let view = evictOldestParked() {
            recycle(view)
        }
    }

    func releaseAll(except keep: Set<String> = []) {
        for id in entries.keys where !keep.contains(id) {
            release(id: id)
        }
    }

    /// Drops parked rows that are no longer in the plan.
    func discardParked(notIn ids: Set<String>) {
        for id in parked.keys where !ids.contains(id) {
            if let view = parked.removeValue(forKey: id)?.view {
                recycle(view)
            }
        }
        parkOrder.removeAll { parked[$0] == nil }
    }

    private func unpark(id: String) -> Entry? {
        guard let entry = parked.removeValue(forKey: id) else { return nil }
        parkOrder.removeAll { $0 == id }
        return entry
    }

    private func evictOldestParked() -> AppKitDiffRowHostingView? {
        while !parkOrder.isEmpty {
            let id = parkOrder.removeFirst()
            if let entry = parked.removeValue(forKey: id) {
                entry.view.representedRowID = nil
                return entry.view
            }
        }
        return nil
    }

    private func recycle(_ view: AppKitDiffRowHostingView) {
        view.representedRowID = nil
        guard reusableViews.count < Self.maximumReusableHosts else { return }
        reusableViews.append(view)
    }
}
