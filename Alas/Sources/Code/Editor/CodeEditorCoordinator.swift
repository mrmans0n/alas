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
    private var currentFontFamily: String?
    private var currentFontSize: CGFloat?
    private var lastAppliedReveal: (tabId: TabID, line: Int, character: Int)?

    private var diagnosticsTask: Task<Void, Never>?
    private var diagnosticsSetupTask: Task<Void, Never>?
    private let diagnosticsFeature = DiagnosticsFeature()
    let symbolsFeature = SymbolsFeature()
    private var hover: HoverFeature?
    private var definition: DefinitionFeature?

    private var editObserverToken: EditorBuffer.EditObserverToken?
    private var didChangeTask: Task<Void, Never>?
    private var hasPendingDidChange = false
    private var pendingTextEdits: [EditorTextEdit] = []
    private let highlightSession = TreeSitterHighlighter.Session()

    static func resolveFont(family: String, size: CGFloat) -> NSFont {
        guard !family.isEmpty else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        // The picker stores family names (e.g. "JetBrains Mono"), but
        // NSFont(name:size:) requires the PostScript name of a specific
        // face ("JetBrainsMono-Regular"). Walk the family's members and
        // pick the face closest to regular weight (NSFontManager weight 5)
        // so multi-face families resolve to a real face instead of nil.
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        if !members.isEmpty {
            let sorted = members.sorted { lhs, rhs in
                let lw = (lhs.count > 2 ? lhs[2] as? Int : nil) ?? 5
                let rw = (rhs.count > 2 ? rhs[2] as? Int : nil) ?? 5
                return abs(lw - 5) < abs(rw - 5)
            }
            if let psName = sorted.first?.first as? String,
               let font = NSFont(name: psName, size: size) {
                return font
            }
        }
        // Last-resort fallbacks: try the user's string verbatim (covers the
        // case where they typed a PostScript name themselves), then a font
        // descriptor by family, then the system default.
        if let font = NSFont(name: family, size: size) { return font }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        if let font = NSFont(descriptor: descriptor, size: size) { return font }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    init(appState: AppState) {
        self.appState = appState
    }

    func attach(textView: CodeTextView, buffer: EditorBuffer, layoutManager: NSLayoutManager, worktreeId: String, tabId: TabID, revealLine: Int?, revealCharacter: Int?, theme: Theme) {
        self.textView = textView
        self.layoutManager = layoutManager
        self.currentWorktreeId = worktreeId
        self.currentTabId = tabId
        self.currentTheme = theme

        let family = appState.config.code.fontFamily
        let size = CGFloat(appState.config.code.fontSize)
        self.currentFontFamily = family
        self.currentFontSize = size
        textView.font = Self.resolveFont(family: family, size: size)
        textView.increaseFontSizeHandler = { [weak self] in self?.adjustFontSize(by: 1) }
        textView.decreaseFontSizeHandler = { [weak self] in self?.adjustFontSize(by: -1) }
        textView.resetFontSizeHandler = { [weak self] in self?.resetFontSize() }

        bindBuffer(buffer, theme: theme)

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
        let nextLanguage = appState.lsp.language(forFileExtension: (relativePath as NSString).pathExtension)
        let pathChanged = currentWorktreeId != worktreeId
            || currentTabId != tabId
            || currentRoot != worktreeRoot
            || currentRelativePath != relativePath
            || currentLanguage != nextLanguage

        if pathChanged {
            didChangeTask?.cancel()
            hasPendingDidChange = false
            pendingTextEdits.removeAll()
            let session = highlightSession
            Task { await session.reset() }
            currentWorktreeId = worktreeId
            currentTabId = tabId
            // Fetch (and if needed, create) the buffer for the new tab and
            // re-bind the layout manager onto its storage. Without this swap
            // the text view keeps rendering the *previous* buffer's storage,
            // so every editor tab appears to show the file that was opened
            // first.
            let nextBuffer = appState.tabs.buffer(
                worktreeId: worktreeId,
                tabId: tabId,
                worktreeRoot: worktreeRoot,
                relativePath: relativePath
            )
            bindBuffer(nextBuffer, theme: theme)
        }

        if currentTheme != theme {
            applyBaseStyle(theme: theme)
            runHighlight(theme: theme)
            currentTheme = theme
        }

        let family = appState.config.code.fontFamily
        let size = CGFloat(appState.config.code.fontSize)
        let fontChanged = currentFontFamily != family || currentFontSize != size
        if fontChanged {
            currentFontFamily = family
            currentFontSize = size
            if let textView {
                textView.font = Self.resolveFont(family: family, size: size)
            }
            applyBaseStyle(theme: theme)
            runHighlight(theme: theme)
        }

        applyRevealIfNeeded(tabId: tabId, line: revealLine, character: revealCharacter)
    }

    /// Wire the coordinator and the text view to `buffer`. If a previous
    /// buffer is already bound, its layout manager and edit observer are torn
    /// down first so the text view stops rendering the old storage.
    private func bindBuffer(_ buffer: EditorBuffer, theme: Theme) {
        if let previous = self.buffer {
            if let token = editObserverToken {
                previous.removeOnEdit(token)
            }
            editObserverToken = nil
            if let layoutManager {
                previous.storage.removeLayoutManager(layoutManager)
            }
        }
        self.buffer = buffer
        self.currentRoot = buffer.worktreeRoot
        self.currentRelativePath = buffer.relativePath
        let ext = (buffer.relativePath as NSString).pathExtension
        currentLanguage = appState.lsp.language(forFileExtension: ext)
        if let layoutManager {
            buffer.storage.addLayoutManager(layoutManager)
        }
        applyBaseStyle(theme: theme)
        runHighlight(theme: theme)
        subscribeIfPossible(theme: theme)
        editObserverToken = buffer.onTextEdit { [weak self] edit in
            self?.scheduleEditPropagation(edit: edit)
        }
    }

    func detach() {
        if let buffer, let token = editObserverToken {
            buffer.removeOnEdit(token)
        }
        editObserverToken = nil
        if hasPendingDidChange {
            notifyLSPDidChange(edits: pendingTextEdits)
            hasPendingDidChange = false
        }
        pendingTextEdits.removeAll()
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        diagnosticsSetupTask?.cancel()
        diagnosticsSetupTask = nil
        didChangeTask?.cancel()
        didChangeTask = nil
        if let buffer, let layoutManager {
            buffer.storage.removeLayoutManager(layoutManager)
        }
        layoutManager = nil
        hover = nil
        definition = nil
        textView?.increaseFontSizeHandler = nil
        textView?.decreaseFontSizeHandler = nil
        textView?.resetFontSizeHandler = nil
        textView = nil
        buffer = nil
        // We deliberately do NOT close the LSP document or stop the file
        // watcher — the buffer owns those for as long as the tab is alive.
    }

    // MARK: - Edit propagation (highlight + didChange debouncer)

    private func scheduleEditPropagation(edit: EditorTextEdit?) {
        didChangeTask?.cancel()
        hasPendingDidChange = true
        if let edit {
            pendingTextEdits.append(edit)
        } else {
            pendingTextEdits.removeAll()
        }
        didChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, let theme = self.currentTheme else { return }
            await MainActor.run {
                self.runHighlight(theme: theme)
                self.hasPendingDidChange = false
                let edits = self.pendingTextEdits
                self.pendingTextEdits.removeAll()
                self.notifyLSPDidChange(edits: edits)
            }
        }
    }

    private func notifyLSPDidChange(edits: [EditorTextEdit]? = nil) {
        guard let buffer, let language = currentLanguage else { return }
        let url = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath)
        let text = buffer.storage.string
        Task {
            await appState.lsp.didChange(
                worktreeRoot: buffer.worktreeRoot,
                fileURL: url,
                languageId: language,
                text: text,
                edits: edits
            )
        }
    }

    // MARK: - Highlight + base styling

    private func applyBaseStyle(theme: Theme) {
        guard let buffer, let textView else { return }
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        let editorTheme = EditorTheme(theme: theme)
        // Resolve the font from the coordinator's tracked family/size, not
        // from `textView.font`. The latter's getter reads `.font` from char 0
        // of the current storage — and immediately after binding a freshly
        // loaded buffer that attribute is unset, so it falls back to the
        // system default (a proportional font). Reading our own state keeps
        // the editor monospaced regardless of what the storage looks like.
        let family = currentFontFamily ?? appState.config.code.fontFamily
        let size = currentFontSize ?? CGFloat(appState.config.code.fontSize)
        let font = Self.resolveFont(family: family, size: size)
        textView.font = font
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
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
        let session = highlightSession
        let edits = pendingTextEdits
        Task(priority: .userInitiated) { [weak self] in
            let spans = await session.highlight(source: text, fileExtension: ext, edits: edits)
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

    // MARK: - Diagnostics subscription

    /// Waits for the buffer's LSP open to complete (via `clientWhenReady`),
    /// then subscribes to diagnostics. The buffer owns open/close; the
    /// coordinator only wires the diagnostic stream.
    private func subscribeIfPossible(theme: Theme) {
        guard let buffer else { return }
        diagnosticsSetupTask?.cancel()
        diagnosticsTask?.cancel()
        diagnosticsFeature.apply([], to: buffer.storage, theme: theme)
        guard let language = currentLanguage else { return }
        let url = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath)
        let root = buffer.worktreeRoot
        let relativePath = buffer.relativePath
        let manager = appState.lsp
        let stableTabId = currentTabId
        diagnosticsSetupTask = Task { [weak self] in
            let client = await manager.clientWhenReady(forFile: url, worktreeRoot: root, language: language)
            guard let self,
                  !Task.isCancelled,
                  self.currentTabId == stableTabId,
                  self.currentRoot == root,
                  self.currentRelativePath == relativePath,
                  self.currentLanguage == language,
                  let client else { return }
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

    // MARK: - Font size adjustments

    private func adjustFontSize(by delta: Int) {
        let current = appState.config.code.fontSize
        let next = max(8, min(64, current + delta))
        if next != current {
            appState.config.code.fontSize = next
            appState.saveConfig()
        }
    }

    private func resetFontSize() {
        let target = AppConfig.defaults.code.fontSize
        if appState.config.code.fontSize != target {
            appState.config.code.fontSize = target
            appState.saveConfig()
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
