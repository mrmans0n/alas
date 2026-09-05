import AppKit
import Foundation
import Markdown
import SwiftUI

struct DiffPaneLSPContext {
    let worktreeId: String
    let worktreeRoot: URL
    let relativePath: String
    let language: String
    let lsp: WorkspaceLSPManager
    let openTarget: @MainActor (URL, Int, Int) -> Void

    var fileURL: URL {
        worktreeRoot.appendingPathComponent(relativePath)
    }

    var uri: String {
        fileURL.lspURI
    }
}

enum DiffPaneLSPLineMap {
    struct Match: Equatable {
        let position: LSPPosition
        let sourceText: String
    }

    static func position(
        at characterIndex: Int,
        metadata: [DiffPaneTextDocumentBuilder.LineMetadata],
        allowedSide: DiffLineSide
    ) -> LSPPosition? {
        match(at: characterIndex, metadata: metadata, allowedSide: allowedSide)?.position
    }

    static func match(
        at characterIndex: Int,
        metadata: [DiffPaneTextDocumentBuilder.LineMetadata],
        allowedSide: DiffLineSide
    ) -> Match? {
        guard let line = metadata.first(where: { NSLocationInRange(characterIndex, $0.range) }) else {
            return nil
        }
        guard let source = line.sourceLine,
              allowedSide == .new,
              (source.anchor.side == .new || source.anchor.side == .paired),
              let newLine = source.anchor.newLine,
              newLine > 0
        else {
            return nil
        }

        let sourceRange = line.sourceRange ?? line.range
        guard NSLocationInRange(characterIndex, sourceRange) else {
            return nil
        }
        let character = characterIndex - sourceRange.location
        guard character >= 0, character < source.text.utf16.count else {
            return nil
        }
        return Match(
            position: LSPPosition(line: newLine - 1, character: character),
            sourceText: source.text
        )
    }
}

@MainActor
final class DiffPaneLSPDocumentRetain {
    typealias Open = (_ worktreeRoot: URL, _ fileURL: URL, _ language: String, _ text: String) async -> LSPClient?
    typealias Close = (_ worktreeRoot: URL, _ fileURL: URL, _ language: String) async -> Void

    let client: LSPClient?

    private let worktreeRoot: URL
    private let fileURL: URL
    private let language: String
    private let closeDocument: Close
    private var didClose = false

    private init(
        worktreeRoot: URL,
        fileURL: URL,
        language: String,
        close: @escaping Close,
        client: LSPClient?
    ) {
        self.worktreeRoot = worktreeRoot
        self.fileURL = fileURL
        self.language = language
        self.closeDocument = close
        self.client = client
    }

    static func open(
        worktreeRoot: URL,
        fileURL: URL,
        language: String,
        open: Open,
        close: @escaping Close
    ) async throws -> DiffPaneLSPDocumentRetain {
        let text = try await fileText(at: fileURL)
        let client = await open(worktreeRoot, fileURL, language, text)
        return DiffPaneLSPDocumentRetain(
            worktreeRoot: worktreeRoot,
            fileURL: fileURL,
            language: language,
            close: close,
            client: client
        )
    }

    func close() async {
        guard !didClose else { return }
        didClose = true
        await closeDocument(worktreeRoot, fileURL, language)
    }

    fileprivate static func fileText(at fileURL: URL) async throws -> String {
        if let host = RemoteHostRegistry.shared.host(forPath: fileURL.path) {
            guard case let .file(data, _) = try await RemoteFileAccess.read(host: host, path: fileURL.path),
                  let text = String(data: data, encoding: .utf8)
            else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return text
        }
        return try await Task.detached(priority: .userInitiated) {
            try String(contentsOf: fileURL, encoding: .utf8)
        }.value
    }

    deinit {
        guard !didClose else { return }
        let worktreeRoot = worktreeRoot
        let fileURL = fileURL
        let language = language
        let closeDocument = closeDocument
        Task { @MainActor in
            await closeDocument(worktreeRoot, fileURL, language)
        }
    }
}

@MainActor
final class DiffPaneLSPController {
    private struct ContextKey: Equatable {
        let worktreeRoot: URL
        let fileURL: URL
        let language: String
        let manager: ObjectIdentifier

        init(_ context: DiffPaneLSPContext) {
            self.worktreeRoot = context.worktreeRoot
            self.fileURL = context.fileURL
            self.language = context.language
            self.manager = ObjectIdentifier(context.lsp)
        }
    }

    private weak var textView: DiffPaneCodeTextView?
    private var context: DiffPaneLSPContext?
    private var allowedSide: DiffLineSide = .new
    private var hoverTask: Task<Void, Never>?
    private var definitionTask: Task<Void, Never>?
    private var documentRetain: DiffPaneLSPDocumentRetain?
    private let hoverWindowController = HoverWindowController()
    private var definitionPopover: NSPopover?
    private let snippetCache = DefinitionSnippetCache()
    private var hoverRequestID: UInt64 = 0
    private var definitionRequestID: UInt64 = 0
    private var hoverSymbolRange: NSRange?

    /// Dismisses any visible hover panel and definition popover. Called when
    /// the enclosing diff pane scrolls, because the symbol anchor the popovers
    /// were anchored to may have moved or left the visible area. Without this,
    /// a hover panel (which is a child window anchored to screen coordinates)
    /// can stay stuck on screen until the user scrolls back to the symbol.
    func notifyScrolled() {
        hideHover()
        cancelDefinitionRequests()
        definitionPopover?.close()
        definitionPopover = nil
    }

    init(textView: DiffPaneCodeTextView) {
        self.textView = textView
        textView.hoverHandler = { [weak self] point in
            self?.requestHover(at: point)
        }
        textView.commandClickHandler = { [weak self] point in
            self?.requestDefinition(at: point)
        }
        textView.flagsChangedHandler = { [weak self] _ in
            self?.hideHover()
        }
        textView.mouseExitedHandler = { [weak self] in
            self?.hideHover()
        }
    }

    func update(context: DiffPaneLSPContext?, allowedSide: DiffLineSide) {
        let oldKey = self.context.map(ContextKey.init)
        let newKey = context.map(ContextKey.init)
        self.context = context
        self.allowedSide = allowedSide

        if oldKey != newKey {
            cancelRequests()
            hideUI()
            closeRetain()
        }
        if context == nil {
            cancelRequests()
            hideUI()
            closeRetain()
        }
    }

    func tearDown() {
        cancelRequests()
        hideUI()
        closeRetain()
        context = nil
        if let textView {
            textView.hoverHandler = nil
            textView.commandClickHandler = nil
            textView.flagsChangedHandler = nil
            textView.mouseExitedHandler = nil
        }
    }

    func lspPosition(at point: NSPoint) -> LSPPosition? {
        guard let textView, let characterIndex = textView.characterIndex(at: point) else {
            return nil
        }
        return lspPosition(forCharacterIndex: characterIndex)
    }

    func lspPosition(forCharacterIndex characterIndex: Int) -> LSPPosition? {
        guard let textView else { return nil }
        return DiffPaneLSPLineMap.position(
            at: characterIndex,
            metadata: textView.lineMetadata,
            allowedSide: allowedSide
        )
    }

    func lspMatch(forCharacterIndex characterIndex: Int) -> DiffPaneLSPLineMap.Match? {
        guard let textView else { return nil }
        return DiffPaneLSPLineMap.match(
            at: characterIndex,
            metadata: textView.lineMetadata,
            allowedSide: allowedSide
        )
    }

    private func requestHover(at point: NSPoint) {
        guard let textView,
              let context,
              let characterIndex = textView.characterIndex(at: point),
              let match = lspMatch(forCharacterIndex: characterIndex),
              let symbolRange = textView.symbolRange(at: point)
        else {
            hideHover()
            return
        }
        let position = match.position

        hoverRequestID &+= 1
        let currentRequestID = hoverRequestID
        let contextKey = ContextKey(context)
        hoverSymbolRange = symbolRange
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.matchesCurrentSource(match, context: context) else {
                guard self.isCurrentHover(currentRequestID, contextKey: contextKey) else { return }
                self.hideHover()
                return
            }
            guard let client = await self.client(for: context, expectedKey: contextKey) else { return }
            let result: LSPHoverResult?
            do {
                result = try await client.hover(uri: context.uri, position: position)
            } catch {
                guard self.isCurrentHover(currentRequestID, contextKey: contextKey) else { return }
                self.hideHover()
                return
            }
            guard self.isCurrentHover(currentRequestID, contextKey: contextKey),
                  self.lspPosition(at: point) == position,
                  self.hoverSymbolRange == symbolRange
            else { return }
            self.showHover(result, symbolRange: symbolRange, fallbackPoint: point, context: context)
        }
    }

    private func requestDefinition(at point: NSPoint) {
        guard let textView,
              let context,
              let characterIndex = textView.characterIndex(at: point),
              let match = lspMatch(forCharacterIndex: characterIndex)
        else { return }
        let position = match.position

        definitionRequestID &+= 1
        let currentRequestID = definitionRequestID
        let contextKey = ContextKey(context)
        definitionPopover?.close()
        definitionTask?.cancel()
        definitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.matchesCurrentSource(match, context: context) else { return }
            guard let client = await self.client(for: context, expectedKey: contextKey) else { return }
            let locations = (try? await client.definition(uri: context.uri, position: position)) ?? []
            guard self.isCurrentDefinition(currentRequestID, contextKey: contextKey),
                  self.lspPosition(at: point) == position,
                  self.textView?.window != nil
            else { return }
            self.handleDefinition(locations: locations, anchorPoint: point, context: context)
        }
    }

    func matchesCurrentSourceForTesting(
        _ match: DiffPaneLSPLineMap.Match,
        context: DiffPaneLSPContext
    ) async -> Bool {
        await matchesCurrentSource(match, context: context)
    }

    var isHoverVisibleForTesting: Bool { hoverWindowController.isVisible }
    var isDefinitionPopoverShownForTesting: Bool { definitionPopover != nil }

    func showDefinitionPopoverForTesting(_ popover: NSPopover) {
        definitionPopover?.close()
        definitionPopover = popover
    }

    private func matchesCurrentSource(
        _ match: DiffPaneLSPLineMap.Match,
        context: DiffPaneLSPContext
    ) async -> Bool {
        let fileURL = context.fileURL
        let lineNumber = match.position.line
        let sourceText = match.sourceText
        let diskMatches: Bool
        do {
            let text = try await DiffPaneLSPDocumentRetain.fileText(at: fileURL)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lineNumber >= 0, lineNumber < lines.count else {
                return false
            }
            diskMatches = String(lines[lineNumber]) == sourceText
        } catch {
            diskMatches = false
        }
        guard diskMatches else { return false }
        if let lspMatches = context.lsp.openedDocumentLineMatches(
            forFile: fileURL,
            worktreeRoot: context.worktreeRoot,
            line: lineNumber,
            text: sourceText
        ) {
            return lspMatches
        }
        return true
    }

    private func client(for context: DiffPaneLSPContext, expectedKey: ContextKey) async -> LSPClient? {
        guard self.context.map(ContextKey.init) == expectedKey else { return nil }
        if let client = context.lsp.openedClient(
            forFile: context.fileURL,
            worktreeRoot: context.worktreeRoot,
            language: context.language
        ) {
            return client
        }
        if documentRetain == nil {
            do {
                let retain = try await DiffPaneLSPDocumentRetain.open(
                    worktreeRoot: context.worktreeRoot,
                    fileURL: context.fileURL,
                    language: context.language,
                    open: { worktreeRoot, fileURL, language, text in
                        await context.lsp.openTemporaryDocument(
                            worktreeRoot: worktreeRoot,
                            fileURL: fileURL,
                            languageId: language,
                            text: text
                        )
                    },
                    close: { worktreeRoot, fileURL, language in
                        await context.lsp.closeTemporaryDocument(
                            worktreeRoot: worktreeRoot,
                            fileURL: fileURL,
                            languageId: language
                        )
                    }
                )
                guard self.context.map(ContextKey.init) == expectedKey else {
                    await retain.close()
                    return nil
                }
                guard retain.client != nil else {
                    await retain.close()
                    return nil
                }
                documentRetain = retain
            } catch {
                return nil
            }
        }
        return documentRetain?.client ?? context.lsp.openedClient(
            forFile: context.fileURL,
            worktreeRoot: context.worktreeRoot,
            language: context.language
        )
    }

    private func showHover(
        _ result: LSPHoverResult?,
        symbolRange: NSRange,
        fallbackPoint: NSPoint,
        context: DiffPaneLSPContext
    ) {
        guard let textView,
              textView.window != nil,
              let body = nonEmptyBody(result),
              let theme = textView.theme
        else {
            hideHover()
            return
        }

        let renderResult = MarkdownRenderer().render(
            document: Document(parsing: body),
            theme: theme,
            monospacedFontFamily: textView.font?.familyName ?? "JetBrainsMono Nerd Font",
            monospacedFontSize: max(1, Int((textView.font?.pointSize ?? 13).rounded())),
            baseDirectory: context.fileURL.deletingLastPathComponent(),
            worktreeRoot: context.worktreeRoot,
            mermaidProfile: .compact
        )
        let size = HoverFeatureTesting.computePreferredSize(for: renderResult)
        let anchor = textView.symbolAnchorRect(for: symbolRange)
            ?? NSRect(origin: fallbackPoint, size: .zero)
        hoverWindowController.show(
            result: renderResult,
            size: size,
            theme: theme,
            anchor: anchor,
            in: textView,
            onWillPresentMermaidViewer: { [weak self] in
                self?.hideHover()
            }
        )
    }

    private func nonEmptyBody(_ result: LSPHoverResult?) -> String? {
        guard let result else { return nil }
        let body: String
        switch result.contents {
        case .markupContent(_, let value):
            body = value
        case .plain(let value):
            body = value
        }
        return body.isEmpty ? nil : body
    }

    private func handleDefinition(
        locations: [LSPLocation],
        anchorPoint: NSPoint,
        context: DiffPaneLSPContext
    ) {
        switch locations.count {
        case 0:
            return
        case 1:
            openLocation(locations[0], context: context)
        default:
            presentDefinitionPicker(locations: locations, anchor: anchorPoint, context: context)
        }
    }

    private func openLocation(_ target: LSPLocation, context: DiffPaneLSPContext) {
        let url = URL(string: target.uri)
            ?? URL(fileURLWithPath: target.uri.removingPercentEncoding ?? target.uri)
        context.openTarget(url, target.range.start.line, target.range.start.character)
    }

    private func presentDefinitionPicker(
        locations: [LSPLocation],
        anchor point: NSPoint,
        context: DiffPaneLSPContext
    ) {
        guard let textView, textView.window != nil else { return }
        let entries = locations.map { location -> DefinitionPickerEntry in
            let url = URL(string: location.uri)
                ?? URL(fileURLWithPath: location.uri.removingPercentEncoding ?? location.uri)
            let path = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            return DefinitionPickerEntry(
                displayPath: "\(path):\(location.range.start.line + 1)",
                snippet: snippetCache.line(at: url, line: location.range.start.line)
            )
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: max(60, min(320, 24 + entries.count * 36)))
        popover.contentViewController = NSHostingController(
            rootView: DefinitionPicker(entries: entries) { [weak self, weak popover] choice in
                popover?.close()
                guard let self, let choice else { return }
                self.openLocation(locations[choice], context: context)
            }
        )
        popover.show(
            relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)),
            of: textView,
            preferredEdge: .maxY
        )
        definitionPopover = popover
    }

    private func isCurrentHover(_ requestID: UInt64, contextKey: ContextKey) -> Bool {
        !Task.isCancelled && hoverRequestID == requestID && context.map(ContextKey.init) == contextKey
    }

    private func isCurrentDefinition(_ requestID: UInt64, contextKey: ContextKey) -> Bool {
        !Task.isCancelled && definitionRequestID == requestID && context.map(ContextKey.init) == contextKey
    }

    private func hideHover() {
        hoverRequestID &+= 1
        hoverTask?.cancel()
        hoverTask = nil
        hoverSymbolRange = nil
        hoverWindowController.hide()
    }

    private func hideUI() {
        hoverWindowController.hide()
        definitionPopover?.close()
        definitionPopover = nil
        hoverSymbolRange = nil
    }

    private func cancelRequests() {
        hoverRequestID &+= 1
        definitionRequestID &+= 1
        hoverTask?.cancel()
        definitionTask?.cancel()
        hoverTask = nil
        definitionTask = nil
    }

    private func cancelDefinitionRequests() {
        definitionRequestID &+= 1
        definitionTask?.cancel()
        definitionTask = nil
    }

    private func closeRetain() {
        guard let retain = documentRetain else { return }
        documentRetain = nil
        Task { @MainActor in
            await retain.close()
        }
    }

    deinit {
        hoverTask?.cancel()
        definitionTask?.cancel()
        let definitionPopover = definitionPopover
        let hoverWindowController = hoverWindowController
        let documentRetain = documentRetain
        Task { @MainActor in
            definitionPopover?.close()
            hoverWindowController.hide()
            await documentRetain?.close()
        }
    }
}
