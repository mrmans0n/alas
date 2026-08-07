import AppKit
import SwiftUI

/// Maintains mounted diff-row hosts and a small detached reuse pool.
@MainActor
final class AppKitDiffRowHostingPool {
    var onRowIntrinsicSizeInvalidated: ((String) -> Void)?

    private static let maximumReusableHosts = 32

    private struct Entry {
        let view: AppKitDiffRowHostingView
        var token: AppKitDiffRowEqualityToken
    }

    private var entries: [String: Entry] = [:]
    private var reusableViews: [AppKitDiffRowHostingView] = []

    var mountedIDs: Set<String> { Set(entries.keys) }

    func mountedView(id: String) -> AppKitDiffRowHostingView? {
        entries[id]?.view
    }

    func view(for spec: AppKitDiffRowSpec) -> (view: AppKitDiffRowHostingView, contentChanged: Bool) {
        if var entry = entries[spec.id] {
            guard !entry.token.isEqual(to: spec.equalityToken) else {
                return (entry.view, false)
            }

            entry.view.updateRootView(spec.build())
            entry.token = spec.equalityToken
            entries[spec.id] = entry
            return (entry.view, true)
        }

        let view: AppKitDiffRowHostingView
        if let reusedView = reusableViews.popLast() {
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
        guard let view = entries.removeValue(forKey: id)?.view else { return }
        view.removeFromSuperview()
        view.representedRowID = nil
        guard reusableViews.count < Self.maximumReusableHosts else { return }
        reusableViews.append(view)
    }

    func releaseAll(except keep: Set<String> = []) {
        for id in entries.keys where !keep.contains(id) {
            release(id: id)
        }
    }
}
