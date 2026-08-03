import AppKit
import SwiftUI

/// Owns the live `ACPTranscriptRowHostingView`s, keyed by row id. Views are
/// reused across layout passes; rootView is only replaced when the row's
/// equality token changes, mirroring the legacy `.equatable()` gating.
@MainActor
final class ACPTranscriptRowHostingPool {
    var onRowIntrinsicSizeInvalidated: ((String) -> Void)?

    private struct Entry {
        let view: ACPTranscriptRowHostingView
        var token: ACPRowEqualityToken
    }

    private var entries: [String: Entry] = [:]

    var mountedIds: Set<String> { Set(entries.keys) }

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
        let view = ACPTranscriptRowHostingView(rootView: spec.build())
        let id = spec.id
        view.onIntrinsicSizeInvalidated = { [weak self] in
            self?.onRowIntrinsicSizeInvalidated?(id)
        }
        entries[id] = Entry(view: view, token: spec.equalityToken)
        return (view, true)
    }

    func release(id: String) {
        entries.removeValue(forKey: id)?.view.removeFromSuperview()
    }

    func releaseAll(except keep: Set<String> = []) {
        for id in entries.keys where !keep.contains(id) {
            release(id: id)
        }
    }
}
