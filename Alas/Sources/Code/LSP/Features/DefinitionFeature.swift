import AppKit
import SwiftUI
import Foundation

/// Cmd-click handler that resolves the symbol under the cursor via
/// `textDocument/definition` and forwards the result to `openTarget`.
/// 0 results → no-op; 1 result → open immediately; 2+ → present an
/// inline `DefinitionPicker` anchored at the click point.
@MainActor
final class DefinitionFeature {
    typealias SynchronizeRequest = (_ range: NSRange) async -> (LSPClient, EditorRequestContext)?
    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?
    private let openTarget: (URL, Int, Int) -> Void
    private let synchronizeRequest: SynchronizeRequest?
    private let isContextCurrent: (EditorRequestContext) -> Bool
    private var popover: NSPopover?
    private var requestID: UInt64 = 0
    private var inFlight: Task<Void, Never>?
    private let snippetCache = DefinitionSnippetCache()

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?,
        openTarget: @escaping (URL, Int, Int) -> Void,
        synchronizeRequest: SynchronizeRequest? = nil,
        isContextCurrent: @escaping (EditorRequestContext) -> Bool = { _ in true }
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        self.openTarget = openTarget
        self.synchronizeRequest = synchronizeRequest
        self.isContextCurrent = isContextCurrent
        textView.commandClickHandler = { [weak self] p in self?.onClick(at: p) }
    }

    func notifyScrolled() { dismiss() }
    func notifyCaretChanged() { dismiss() }
    func notifyWindowResized() { dismiss() }

    private func dismiss() {
        requestID += 1
        inFlight?.cancel()
        inFlight = nil
        popover?.close()
    }

    private func onClick(at point: NSPoint) {
        popover?.close()
        guard let textView, let uri = getURI(),
              let position = textView.lspPosition(at: point),
              let offset = textView.utf16Offset(at: point) else { return }
        let fallbackClient = getClient()
        inFlight?.cancel()
        requestID += 1
        let currentRequestID = requestID
        inFlight = Task { [weak self] in
            guard let self else { return }
            let bound: (LSPClient, EditorRequestContext)?
            if let synchronizeRequest {
                bound = await synchronizeRequest(NSRange(location: offset, length: 0))
                guard bound != nil else { return }
            } else {
                bound = nil
            }
            let context = bound?.1
            let locations: [LSPLocation]
            if let bound {
                locations = (try? await bound.0.definition(uri: bound.1.document.uri, position: bound.1.range.start)) ?? []
            } else if let fallbackClient {
                locations = (try? await fallbackClient.definition(uri: uri, position: position)) ?? []
            } else {
                locations = []
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.requestID == currentRequestID,
                      self.getURI() == uri,
                      context.map(self.isContextCurrent) ?? true,
                      self.textView?.lspPosition(at: point) == position
                else { return }
                self.handle(locations: locations, anchorPoint: point)
            }
        }
    }

    private func handle(locations: [LSPLocation], anchorPoint: NSPoint) {
        switch locations.count {
        case 0: return
        case 1: openLocation(locations[0])
        default: presentPicker(locations: locations, anchor: anchorPoint)
        }
    }

    private func openLocation(_ target: LSPLocation) {
        let url = URL(string: target.uri)
            ?? URL(fileURLWithPath: target.uri.removingPercentEncoding ?? target.uri)
        openTarget(url, target.range.start.line, target.range.start.character)
    }

    private func presentPicker(locations: [LSPLocation], anchor point: NSPoint) {
        guard let textView else { return }
        let entries = locations.map { loc -> DefinitionPickerEntry in
            let url = URL(string: loc.uri)
                ?? URL(fileURLWithPath: loc.uri.removingPercentEncoding ?? loc.uri)
            let path = (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
            let display = "\(path):\(loc.range.start.line + 1)"
            let snippet = snippetCache.line(at: url, line: loc.range.start.line)
            return DefinitionPickerEntry(displayPath: display, snippet: snippet)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: max(60, min(320, 24 + entries.count * 36)))
        let host = NSHostingController(
            rootView: DefinitionPicker(entries: entries) { [weak self, weak popover] choice in
                popover?.close()
                guard let self, let choice else { return }
                self.openLocation(locations[choice])
            }
        )
        popover.contentViewController = host
        let anchorRect = NSRect(origin: point, size: NSSize(width: 1, height: 1))
        popover.show(relativeTo: anchorRect, of: textView, preferredEdge: .maxY)
        self.popover = popover
    }
}
