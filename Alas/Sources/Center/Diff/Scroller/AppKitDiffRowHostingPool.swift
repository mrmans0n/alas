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
        let view: any AppKitDiffRowView
        var token: AppKitDiffRowEqualityToken
    }

    private var entries: [String: Entry] = [:]
    private var parked: [String: Entry] = [:]
    /// Parked row IDs, least recently released first.
    private var parkOrder: [String] = []
    private var reusableViews: [AppKitDiffRowHostingView] = []
    private var reusableNativeViews: [any AppKitDiffRowView] = []

    init(maximumParkedHosts: Int = 160) {
        self.maximumParkedHosts = maximumParkedHosts
    }

    var mountedIDs: Set<String> { Set(entries.keys) }
    var parkedIDs: Set<String> { Set(parked.keys) }

    func mountedView(id: String) -> (any AppKitDiffRowView)? {
        entries[id]?.view
    }

    func mountedHostingView(id: String) -> AppKitDiffRowHostingView? {
        mountedView(id: id) as? AppKitDiffRowHostingView
    }

    func view(for spec: AppKitDiffRowSpec) -> (view: any AppKitDiffRowView, contentChanged: Bool) {
        if var entry = entries[spec.id] ?? unpark(id: spec.id) {
            if isNative(entry.view) == (spec.native != nil) {
                if !entry.token.isEqual(to: spec.equalityToken) {
                    apply(spec, to: entry.view)
                    entry.token = spec.equalityToken
                    entries[spec.id] = entry
                    return (entry.view, true)
                }
                entries[spec.id] = entry
                return (entry.view, false)
            }
            // The row switched between SwiftUI and native rendering.
            entries[spec.id] = nil
            recycle(entry.view)
        }

        let view: any AppKitDiffRowView
        var isFreshHost = false
        if let native = spec.native {
            view = reusableNativeViews.popLast() ?? native.make()
        } else if let reusedView = reusableViews.popLast() ?? (parked.count >= maximumParkedHosts ? evictOldestParkedHost() : nil) {
            view = reusedView
        } else {
            view = AppKitDiffRowHostingView(rootView: spec.build())
            isFreshHost = true
        }
        if view.onIntrinsicSizeInvalidated == nil {
            view.onIntrinsicSizeInvalidated = { [weak self] id in
                self?.onRowIntrinsicSizeInvalidated?(id)
            }
        }
        if !isFreshHost {
            apply(spec, to: view)
        }
        view.representedRowID = spec.id
        entries[spec.id] = Entry(view: view, token: spec.equalityToken)
        return (view, true)
    }

    private func isNative(_ view: any AppKitDiffRowView) -> Bool {
        !(view is AppKitDiffRowHostingView)
    }

    private func apply(_ spec: AppKitDiffRowSpec, to view: any AppKitDiffRowView) {
        if let native = spec.native {
            native.configure(view)
        } else if let host = view as? AppKitDiffRowHostingView {
            host.updateRootView(spec.build())
        }
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

    /// The oldest parked SwiftUI host, recycling native rows parked ahead of it.
    private func evictOldestParkedHost() -> AppKitDiffRowHostingView? {
        while let view = evictOldestParked() {
            if let host = view as? AppKitDiffRowHostingView { return host }
            recycle(view)
        }
        return nil
    }

    private func evictOldestParked() -> (any AppKitDiffRowView)? {
        while !parkOrder.isEmpty {
            let id = parkOrder.removeFirst()
            if let entry = parked.removeValue(forKey: id) {
                entry.view.representedRowID = nil
                return entry.view
            }
        }
        return nil
    }

    private func recycle(_ view: any AppKitDiffRowView) {
        view.removeFromSuperview()
        view.representedRowID = nil
        if let host = view as? AppKitDiffRowHostingView {
            guard reusableViews.count < Self.maximumReusableHosts else { return }
            reusableViews.append(host)
        } else {
            guard reusableNativeViews.count < Self.maximumReusableHosts else { return }
            reusableNativeViews.append(view)
        }
    }
}
