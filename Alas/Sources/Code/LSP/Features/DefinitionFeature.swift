import AppKit
import SwiftUI
import Foundation

/// Cmd-click handler that resolves the symbol under the cursor via
/// `textDocument/definition` and forwards the result to `openTarget`.
/// 0 results → no-op; 1 result → open immediately; 2+ → present an
/// inline `DefinitionPicker` anchored at the click point.
@MainActor
final class DefinitionFeature {
    private enum RequestMethod {
        case definition
        case typeDefinition
        case implementation
    }
    typealias SynchronizeRequest = (_ range: NSRange) async -> (LSPClient, EditorRequestContext)?
    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?
    private let openTarget: (URL, Int, Int, LSPPosition) -> Void
    private let cancelPendingNavigation: () -> Void
    private let synchronizeRequest: SynchronizeRequest?
    private let isContextCurrent: (EditorRequestContext) -> Bool
    private var popover: NSPopover?
    private var requestID: UInt64 = 0
    private var inFlight: Task<Void, Never>?
    private let snippetCache = DefinitionSnippetCache()
    private var pickerSourcePosition: LSPPosition?

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?,
        openTarget: @escaping (URL, Int, Int, LSPPosition) -> Void,
        cancelPendingNavigation: @escaping () -> Void = {},
        synchronizeRequest: SynchronizeRequest? = nil,
        isContextCurrent: @escaping (EditorRequestContext) -> Bool = { _ in true }
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        self.openTarget = openTarget
        self.cancelPendingNavigation = cancelPendingNavigation
        self.synchronizeRequest = synchronizeRequest
        self.isContextCurrent = isContextCurrent
        textView.commandClickHandler = { [weak self] p in self?.onClick(at: p) }
    }

    func notifyScrolled() { dismiss() }
    func notifyCaretChanged() { dismiss() }
    func notifyWindowResized() { dismiss() }

    func notifyProjectionChanged() {
        guard let textView, let position = pickerSourcePosition, let rect = textView.firstRect(for: position) else { return }
        popover?.positioningRect = rect
    }

    func goToTypeDefinition(range: NSRange) {
        requestFromCommand(.typeDefinition, range: range)
    }

    func goToImplementation(range: NSRange) {
        requestFromCommand(.implementation, range: range)
    }

    private func dismiss() {
        requestID += 1
        inFlight?.cancel()
        inFlight = nil
        popover?.close()
    }

    private func onClick(at point: NSPoint) {
        cancelPendingNavigation()
        popover?.close()
        guard let textView, let uri = getURI(),
              let position = textView.lspPosition(at: point),
              let offset = textView.utf16Offset(at: point) else { return }
        request(.definition, uri: uri, position: position, offset: offset, anchorPoint: point)
    }

    private func requestFromCommand(_ method: RequestMethod, range: NSRange) {
        guard let textView,
              let uri = getURI(),
              let position = TextEditCoordinates.lspPosition(utf16Offset: range.location, in: textView.sourceString),
              let rect = textView.firstRect(for: position)
        else { return }
        request(
            method,
            uri: uri,
            position: position,
            offset: range.location,
            anchorPoint: NSPoint(x: rect.midX, y: rect.midY)
        )
    }

    private func request(
        _ method: RequestMethod,
        uri: String,
        position: LSPPosition,
        offset: Int,
        anchorPoint: NSPoint
    ) {
        let fallbackClient = getClient()
        let sourceSnapshot = textView?.sourceString
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
                switch method {
                case .definition:
                    locations = (try? await bound.0.definition(uri: bound.1.document.uri, position: bound.1.range.start)) ?? []
                case .typeDefinition:
                    locations = (try? await bound.0.typeDefinition(uri: bound.1.document.uri, position: bound.1.range.start)) ?? []
                case .implementation:
                    locations = (try? await bound.0.implementation(uri: bound.1.document.uri, position: bound.1.range.start)) ?? []
                }
            } else if let fallbackClient {
                switch method {
                case .definition:
                    locations = (try? await fallbackClient.definition(uri: uri, position: position)) ?? []
                case .typeDefinition:
                    locations = (try? await fallbackClient.typeDefinition(uri: uri, position: position)) ?? []
                case .implementation:
                    locations = (try? await fallbackClient.implementation(uri: uri, position: position)) ?? []
                }
            } else {
                locations = []
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.requestID == currentRequestID,
                      self.getURI() == uri,
                      context.map(self.isContextCurrent) ?? true,
                      self.textView?.sourceString == sourceSnapshot
                else { return }
                self.handle(
                    locations: locations,
                    anchorPoint: self.textView?.firstRect(for: position).map { NSPoint(x: $0.midX, y: $0.midY) } ?? anchorPoint,
                    sourcePosition: context?.range.start ?? position
                )
            }
        }
    }

    private func handle(
        locations: [LSPLocation],
        anchorPoint: NSPoint,
        sourcePosition: LSPPosition
    ) {
        switch locations.count {
        case 0: return
        case 1: openLocation(locations[0], sourcePosition: sourcePosition)
        default: presentPicker(locations: locations, anchor: anchorPoint, sourcePosition: sourcePosition)
        }
    }

    private func openLocation(_ target: LSPLocation, sourcePosition: LSPPosition) {
        let url = URL(string: target.uri)
            ?? URL(fileURLWithPath: target.uri.removingPercentEncoding ?? target.uri)
        openTarget(url, target.range.start.line, target.range.start.character, sourcePosition)
    }

    private func presentPicker(
        locations: [LSPLocation],
        anchor point: NSPoint,
        sourcePosition: LSPPosition
    ) {
        guard let textView else { return }
        let entries = locations.map { loc -> DefinitionPickerEntry in
            let url = URL(string: loc.uri)
                ?? URL(fileURLWithPath: loc.uri.removingPercentEncoding ?? loc.uri)
            let path = (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
            let display = "\(path):\(loc.range.start.line + 1)"
            // The picker is rendered synchronously. Remote snippets are
            // loaded by the persistent navigation surface instead of routing
            // an SSH path through local file APIs while opening this menu.
            let snippet = url.isRemoteAlasPath ? "" : snippetCache.line(at: url, line: loc.range.start.line)
            return DefinitionPickerEntry(displayPath: display, snippet: snippet)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: max(60, min(320, 24 + entries.count * 36)))
        let host = NSHostingController(
            rootView: DefinitionPicker(entries: entries) { [weak self, weak popover] choice in
                popover?.close()
                guard let self, let choice else { return }
                self.openLocation(locations[choice], sourcePosition: sourcePosition)
            }
        )
        popover.contentViewController = host
        let anchorRect = NSRect(origin: point, size: NSSize(width: 1, height: 1))
        pickerSourcePosition = sourcePosition
        popover.show(relativeTo: anchorRect, of: textView, preferredEdge: .maxY)
        self.popover = popover
    }
}
