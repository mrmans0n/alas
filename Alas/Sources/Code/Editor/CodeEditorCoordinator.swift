import AppKit
import Foundation

/// Lifecycle adapter between a `CodeTextView` (per-mount, recreated by
/// SwiftUI) and an `EditorBuffer` (per-tab, owned by `TabsManager`). The
/// coordinator handles syntax highlighting, LSP `didChange` debouncing,
/// hover/definition feature wiring, theme repaints, and go-to-definition
/// reveal scrolling. Disk I/O, save, file-watch, and dirty tracking live
/// in `EditorBuffer`.
@MainActor
final class CodeEditorCoordinator {
    let appState: AppState
    private weak var textView: CodeTextView?
    private weak var buffer: EditorBuffer?
    private var layoutManager: NSLayoutManager?

    private var currentTabId: TabID?
    private var currentWorktreeId: String?
    private var currentRoot: URL?
    private var currentRelativePath: String?
    private var currentLanguage: String?
    private var currentTheme: Theme?
    private var lastAppliedReveal: (tabId: TabID, line: Int, character: Int)?

    private var diagnosticsTask: Task<Void, Never>?
    private let diagnosticsFeature = DiagnosticsFeature()
    let symbolsFeature = SymbolsFeature()
    private var hover: HoverFeature?
    private var definition: DefinitionFeature?

    private var editObserverToken: EditorBuffer.EditObserverToken?
    private var didChangeTask: Task<Void, Never>?
    private var hasPendingDidChange = false

    init(appState: AppState) {
        self.appState = appState
    }

    func attach(textView: CodeTextView, buffer: EditorBuffer, layoutManager: NSLayoutManager, worktreeId: String, tabId: TabID, revealLine: Int?, revealCharacter: Int?, theme: Theme) {
        self.textView = textView
        self.buffer = buffer
        self.layoutManager = layoutManager
        self.currentWorktreeId = worktreeId
        self.currentTabId = tabId
        self.currentRoot = buffer.worktreeRoot
        self.currentRelativePath = buffer.relativePath
        self.currentTheme = theme

        applyBaseStyle(theme: theme)
        let ext = (buffer.relativePath as NSString).pathExtension
        currentLanguage = appState.lsp.language(forFileExtension: ext)
        runHighlight(theme: theme)
        subscribeIfPossible(theme: theme)

        editObserverToken = buffer.onEdit { [weak self] in
            self?.scheduleEditPropagation()
        }

        hover = HoverFeature(
            textView: textView,
            getClient: { [weak self] in
                guard let self, let root = self.currentRoot, let rel = self.currentRelativePath, let lang = self.currentLanguage else { return nil }
                return self.appState.lsp.client(forFile: root.appendingPathComponent(rel), worktreeRoot: root, language: lang)
            },
            getURI: { [weak self] in
                guard let self, let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            }
        )
        definition = DefinitionFeature(
            textView: textView,
            getClient: { [weak self] in
                guard let self, let root = self.currentRoot, let rel = self.currentRelativePath, let lang = self.currentLanguage else { return nil }
                return self.appState.lsp.client(forFile: root.appendingPathComponent(rel), worktreeRoot: root, language: lang)
            },
            getURI: { [weak self] in
                guard let self, let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            },
            openTarget: { [weak self] url, line, character in
                guard let self, let root = self.currentRoot, let wid = self.currentWorktreeId else { return }
                // Targets outside the current worktree (SDK headers,
                // DerivedData, modulemap files) are dropped on the floor for
                // now — `appendingPathComponent` would treat the absolute
                // path as a sub-path of the worktree and the editor would
                // open a bogus `<worktree>/<abs>` location. v1.5 will route
                // these via absolute URLs so they can be opened in a new tab.
                let abs = url.path
                let prefix = root.path + "/"
                guard abs.hasPrefix(prefix) else { return }
                let rel = String(abs.dropFirst(prefix.count))
                self.appState.tabs.openEditor(
                    worktreeId: wid,
                    relativePath: rel,
                    revealLine: line,
                    revealCharacter: character
                )
            }
        )
        applyRevealIfNeeded(tabId: tabId, line: revealLine, character: revealCharacter)
    }

    func updateIfNeeded(worktreeId: String, worktreeRoot: URL, relativePath: String, tabId: TabID, revealLine: Int?, revealCharacter: Int?, theme: Theme) {
        // The view representable hands us the same parameters every render.
        // The only thing we react to here is theme change (re-paint) and
        // reveal hints (scroll).
        if currentTheme != theme {
            applyBaseStyle(theme: theme)
            runHighlight(theme: theme)
            currentTheme = theme
        }
        applyRevealIfNeeded(tabId: tabId, line: revealLine, character: revealCharacter)
    }

    func detach() {
        if let buffer, let token = editObserverToken {
            buffer.removeOnEdit(token)
        }
        editObserverToken = nil
        if hasPendingDidChange {
            notifyLSPDidChange()
            hasPendingDidChange = false
        }
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        didChangeTask?.cancel()
        didChangeTask = nil
        if let buffer, let layoutManager {
            buffer.storage.removeLayoutManager(layoutManager)
        }
        layoutManager = nil
        hover = nil
        definition = nil
        textView = nil
        buffer = nil
        // We deliberately do NOT close the LSP document or stop the file
        // watcher — the buffer owns those for as long as the tab is alive.
    }

    // MARK: - Edit propagation (highlight + didChange debouncer)

    private func scheduleEditPropagation() {
        didChangeTask?.cancel()
        hasPendingDidChange = true
        didChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, let theme = self.currentTheme else { return }
            await MainActor.run {
                self.runHighlight(theme: theme)
                self.hasPendingDidChange = false
                self.notifyLSPDidChange()
            }
        }
    }

    private func notifyLSPDidChange() {
        guard let buffer, let language = currentLanguage else { return }
        let url = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath)
        let text = buffer.storage.string
        Task {
            await appState.lsp.didChange(
                worktreeRoot: buffer.worktreeRoot,
                fileURL: url,
                languageId: language,
                text: text
            )
        }
    }

    // MARK: - Highlight + base styling

    private func applyBaseStyle(theme: Theme) {
        guard let buffer, let textView else { return }
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        let editorTheme = EditorTheme(theme: theme)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: editorTheme.defaultFG
        ]
        let storage = buffer.storage
        storage.beginEditing()
        storage.setAttributes(baseAttrs, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    private func runHighlight(theme: Theme) {
        guard let buffer else { return }
        let storage = buffer.storage
        let text = storage.string
        let textLength = storage.length
        let editGeneration = buffer.editGeneration
        let ext = (buffer.relativePath as NSString).pathExtension
        let editorTheme = EditorTheme(theme: theme)
        let stableTabId = currentTabId
        let cachedDiagnostics = diagnosticsFeature.current
        Task.detached(priority: .userInitiated) { [weak self] in
            let spans = TreeSitterHighlighter.highlight(source: text, fileExtension: ext)
            await MainActor.run {
                guard let self,
                      let b = self.buffer,
                      b.storage === storage,
                      self.currentTabId == stableTabId,
                      b.editGeneration == editGeneration,
                      storage.length == textLength else { return }
                storage.beginEditing()
                for span in spans {
                    guard NSMaxRange(span.range) <= storage.length else { continue }
                    storage.addAttributes(editorTheme.attributes(for: span.capture), range: span.range)
                }
                storage.endEditing()
                if !cachedDiagnostics.isEmpty {
                    self.diagnosticsFeature.apply(cachedDiagnostics, to: storage, theme: theme)
                }
            }
        }
    }

    // MARK: - Diagnostics subscription

    /// Waits for the buffer's LSP open to complete (via `clientWhenReady`),
    /// then subscribes to diagnostics. The buffer owns open/close; the
    /// coordinator only wires the diagnostic stream.
    private func subscribeIfPossible(theme: Theme) {
        guard let buffer, let language = currentLanguage else { return }
        let url = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath)
        let manager = appState.lsp
        diagnosticsTask?.cancel()
        diagnosticsFeature.reset()
        let stableTabId = currentTabId
        Task { [weak self] in
            let client = await manager.clientWhenReady(forFile: url, worktreeRoot: buffer.worktreeRoot, language: language)
            guard let self, self.currentTabId == stableTabId, let client else { return }
            await self.subscribeDiagnostics(for: client, uri: url.lspURI, theme: theme)
            await self.symbolsFeature.refresh(client: client, uri: url.lspURI)
        }
    }

    private func subscribeDiagnostics(for client: LSPClient?, uri: String, theme: Theme) async {
        guard let client else { return }
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            for await batch in await client.subscribeDiagnostics() {
                if batch.uri != uri { continue }
                await MainActor.run {
                    guard let self, let buffer = self.buffer else { return }
                    self.diagnosticsFeature.apply(batch.diagnostics, to: buffer.storage, theme: theme)
                }
            }
        }
    }

    // MARK: - Reveal (go-to-definition scroll target)

    /// Scrolls the text view so the (line, character) target is visible and
    /// places the selection there. De-duplicates by `(tabId, line, character)`
    /// so SwiftUI re-renders that re-pass the same hints don't keep stealing
    /// the user's scroll position. After applying, asks the TabsManager to
    /// clear the hint so it isn't replayed on relaunch.
    private func applyRevealIfNeeded(tabId: TabID, line: Int?, character: Int?) {
        guard let line, let character else {
            lastAppliedReveal = nil
            return
        }
        if let last = lastAppliedReveal,
           last.tabId == tabId, last.line == line, last.character == character {
            return
        }
        guard let textView, let buffer else { return }
        let nsString = buffer.storage.string as NSString
        // Walk to the requested line, then add the UTF-16 character offset.
        var charIndex = 0
        var currentLine = 0
        while currentLine < line {
            let r = nsString.range(of: "\n", options: [], range: NSRange(location: charIndex, length: nsString.length - charIndex))
            if r.location == NSNotFound { return }
            charIndex = r.location + 1
            currentLine += 1
        }
        let target = min(charIndex + character, nsString.length)
        let range = NSRange(location: target, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        lastAppliedReveal = (tabId: tabId, line: line, character: character)
        if let wid = currentWorktreeId {
            appState.tabs.consumeReveal(worktreeId: wid, tabId: tabId)
        }
    }
}
