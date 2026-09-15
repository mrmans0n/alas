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
    private var pickerSourcePosition: LSPPosition?
    private var pickerContext: EditorRequestContext?
    private let snippetStore: () -> EditorNavigationStore?
    private var pickerSnippetSession: (store: EditorNavigationStore, id: UUID)?

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?,
        openTarget: @escaping (URL, Int, Int, LSPPosition) -> Void,
        cancelPendingNavigation: @escaping () -> Void = {},
        synchronizeRequest: SynchronizeRequest? = nil,
        isContextCurrent: @escaping (EditorRequestContext) -> Bool = { _ in true },
        snippetStore: @escaping () -> EditorNavigationStore? = { nil }
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        self.openTarget = openTarget
        self.cancelPendingNavigation = cancelPendingNavigation
        self.synchronizeRequest = synchronizeRequest
        self.isContextCurrent = isContextCurrent
        self.snippetStore = snippetStore
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
        endPickerSnippets()
        requestID += 1
        inFlight?.cancel()
        inFlight = nil
        popover?.close()
        pickerContext = nil
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
        endPickerSnippets()
        let fallbackClient = getClient()
        let sourceSnapshot = textView?.sourceString
        inFlight?.cancel()
        requestID += 1
        let currentRequestID = requestID
        showRequestStatus("Finding navigation targets…", loading: true, id: currentRequestID)
        inFlight = Task { [weak self] in
            guard let self else { return }
            let bound: (LSPClient, EditorRequestContext)?
            if let synchronizeRequest {
                bound = await synchronizeRequest(NSRange(location: offset, length: 0))
                guard bound != nil else {
                    if self.requestID == currentRequestID { self.showRequestStatus("Language server unavailable", id: currentRequestID) }
                    return
                }
            } else {
                bound = nil
            }
            let context = bound?.1
            guard let client = bound?.0 ?? fallbackClient else {
                if self.requestID == currentRequestID { self.showRequestStatus("Language server unavailable", id: currentRequestID) }
                return
            }
            do {
                let command: EditorCommandID
                switch method {
                case .definition: command = .definition
                case .typeDefinition: command = .typeDefinition
                case .implementation: command = .implementation
                }
                let capabilities = await client.capabilities
                guard self.requestID == currentRequestID, context.map(self.isContextCurrent) ?? true else { return }
                guard capabilities.supports(command) else {
                    self.showRequestStatus("This navigation command is not supported by the server", id: currentRequestID)
                    return
                }
                let locations: [LSPLocation]
                let requestURI = context?.document.uri ?? uri
                let requestPosition = context?.range.start ?? position
                switch method {
                case .definition:
                    locations = try await client.definition(uri: requestURI, position: requestPosition)
                case .typeDefinition:
                    locations = try await client.typeDefinition(uri: requestURI, position: requestPosition)
                case .implementation:
                    locations = try await client.implementation(uri: requestURI, position: requestPosition)
                }
                guard !Task.isCancelled,
                      self.requestID == currentRequestID,
                      self.getURI() == uri,
                      context.map(self.isContextCurrent) ?? true,
                      self.textView?.sourceString == sourceSnapshot
                else { return }
                self.pickerContext = context
                self.popover?.close()
                self.handle(
                    locations: locations,
                    anchorPoint: self.textView?.firstRect(for: position).map { NSPoint(x: $0.midX, y: $0.midY) } ?? anchorPoint,
                    sourcePosition: context?.range.start ?? position
                )
            } catch {
                guard !Task.isCancelled, self.requestID == currentRequestID, context.map(self.isContextCurrent) ?? true else { return }
                self.showRequestStatus(RenameFeature.message(for: error), id: currentRequestID)
            }
        }
    }

    private func showRequestStatus(_ message: String, loading: Bool = false, id: UInt64) {
        guard let textView, textView.window != nil, requestID == id else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(rootView: DefinitionRequestStatusView(message: message, loading: loading, cancel: { [weak self] in
            guard let self, self.requestID == id else { return }
            self.dismiss()
        }))
        self.popover = popover
        popover.show(relativeTo: textView.symbolAnchorRect(for: textView.sourceSelectedRange) ?? .zero, of: textView, preferredEdge: .maxY)
    }

    private func handle(
        locations: [LSPLocation],
        anchorPoint: NSPoint,
        sourcePosition: LSPPosition
    ) {
        switch locations.count {
        case 0: showRequestStatus("No navigation targets found", id: requestID)
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
        let store = snippetStore()
        let session = store?.beginSnippetSession()
        if let store, let session { pickerSnippetSession = (store, session) }
        let targets = pickerContext.map { context in
            locations.map { EditorNavigationTarget(document: .init(host: context.document.host, worktreeID: context.document.worktreeID, uri: $0.uri), position: $0.range.start) }
        } ?? []
        let entries = locations.map { loc -> DefinitionPickerEntry in
            let url = URL(string: loc.uri)
                ?? URL(fileURLWithPath: loc.uri.removingPercentEncoding ?? loc.uri)
            let path = (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
            let display = "\(path):\(loc.range.start.line + 1)"
            // The picker is rendered synchronously. Remote snippets are
            // loaded by the persistent navigation surface instead of routing
            // an SSH path through local file APIs while opening this menu.
            let snippet = store == nil ? "Snippet unavailable" : "Loading snippet…"
            return DefinitionPickerEntry(displayPath: display, snippet: snippet)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: max(60, min(320, 24 + entries.count * 36)))
        let host = NSHostingController(
            rootView: DefinitionPicker(entries: entries, snippetStore: store, snippetSessionID: session, targets: targets) { [weak self, weak popover, id = requestID] choice in
                popover?.close()
                guard let self, self.requestID == id else { return }
                self.endPickerSnippets()
                guard let choice, self.pickerContext.map(self.isContextCurrent) ?? true else { return }
                self.openLocation(locations[choice], sourcePosition: sourcePosition)
            }
        )
        popover.contentViewController = host
        let anchorRect = NSRect(origin: point, size: NSSize(width: 1, height: 1))
        pickerSourcePosition = sourcePosition
        popover.show(relativeTo: anchorRect, of: textView, preferredEdge: .maxY)
        self.popover = popover
    }

    private func endPickerSnippets() {
        if let session = pickerSnippetSession { session.store.endSnippetSession(session.id) }
        pickerSnippetSession = nil
    }
}

struct DefinitionRequestStatusView: View {
    let message: String
    let loading: Bool
    let cancel: () -> Void
    var body: some View {
        HStack {
            if loading { ProgressView().controlSize(.small) }
            Text(message)
            Button(loading ? "Cancel" : "Close", action: cancel).keyboardShortcut(.cancelAction)
        }.padding(10)
    }
}
