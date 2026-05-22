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

    var tabId: TabID? { currentTabId }
    private var currentRoot: URL?
    private var currentRelativePath: String?
    private var currentLanguage: String?
    private var currentTheme: Theme?
    private var currentFontFamily: String?
    private var currentFontSize: CGFloat?
    private var lastAppliedReveal: (tabId: TabID, line: Int, character: Int)?
    private var currentExternalAbsolutePath: String?
    private var currentOriginatingWorktreeRoot: URL?
    private var currentOriginatingRelativePath: String?

    private var diagnosticsTask: Task<Void, Never>?
    private var diagnosticsSetupTask: Task<Void, Never>?
    let diagnosticsFeature = DiagnosticsFeature()
    /// Most recent diagnostics batch the LSP server has published, keyed by
    /// LSP URI. The server doesn't replay past batches to new subscribers,
    /// so when a tab is rebound we restore from this cache; otherwise the
    /// switched-to file would lose its squiggles until the server happens to
    /// publish again. Internal so tests can seed it.
    var lastDiagnosticsByURI: [String: [LSPDiagnostic]] = [:]
    let symbolsFeature = SymbolsFeature()
    private var pullDiagnosticsTask: Task<Void, Never>?
    private var hover: HoverFeature?
    private var definition: DefinitionFeature?
    private var hoverHighlight: HoverHighlightFeature?

    private var editObserverToken: EditorBuffer.EditObserverToken?
    private var didChangeTask: Task<Void, Never>?
    private var hasPendingDidChange = false
    private var pendingTextEdits: [EditorTextEdit] = []
    private let highlightSession = TreeSitterHighlighter.Session()

    static func resolveFont(family: String, size: CGFloat) -> NSFont {
        CenterTypography.resolveCodeFont(family: family, size: size)
    }

    init(appState: AppState) {
        self.appState = appState
    }

    func attach(textView: CodeTextView, buffer: EditorBuffer, layoutManager: NSLayoutManager, worktreeId: String, worktreeRoot: URL, tabId: TabID, revealLine: Int?, revealCharacter: Int?, theme: Theme, externalAbsolutePath: String? = nil, originatingRelativePath: String? = nil) {
        self.textView = textView
        self.layoutManager = layoutManager
        self.currentWorktreeId = worktreeId
        self.currentTabId = tabId
        self.currentTheme = theme
        self.currentExternalAbsolutePath = externalAbsolutePath
        if externalAbsolutePath != nil {
            currentOriginatingWorktreeRoot = worktreeRoot
            currentOriginatingRelativePath = originatingRelativePath
        } else {
            currentOriginatingWorktreeRoot = nil
            currentOriginatingRelativePath = nil
        }

        let family = appState.config.code.fontFamily
        let size = CGFloat(appState.config.code.fontSize)
        self.currentFontFamily = family
        self.currentFontSize = size
        textView.font = Self.resolveFont(family: family, size: size)
        let codeParagraphStyle = CenterTypography.paragraphStyle()
        textView.defaultParagraphStyle = codeParagraphStyle
        textView.typingAttributes[.paragraphStyle] = codeParagraphStyle
        textView.increaseFontSizeHandler = { [weak self] in self?.adjustFontSize(by: 1) }
        textView.decreaseFontSizeHandler = { [weak self] in self?.adjustFontSize(by: -1) }
        textView.resetFontSizeHandler = { [weak self] in self?.resetFontSize() }

        bindBuffer(buffer, theme: theme)

        if buffer.isExternal {
            textView.isEditable = false
        }

        hover = HoverFeature(
            textView: textView,
            getClient: { [weak self] in
                guard let self, let lang = self.currentLanguage else { return nil }
                if let abs = self.currentExternalAbsolutePath,
                   let originating = self.currentOriginatingWorktreeRoot {
                    let absURL = URL(fileURLWithPath: abs)
                    return self.appState.lsp.client(forFile: absURL, worktreeRoot: originating, language: lang)
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return self.appState.lsp.client(forFile: root.appendingPathComponent(rel), worktreeRoot: root, language: lang)
            },
            getURI: { [weak self] in
                guard let self else { return nil }
                if let abs = self.currentExternalAbsolutePath {
                    return URL(fileURLWithPath: abs).lspURI
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            },
            getTheme: { [weak self] in self?.currentTheme ?? (try? ThemeStore().current) ?? (try? Theme.loadBundled(id: "cool-slate")) ?? Theme(id: "fallback", name: "Fallback", tokens: [:]) },
            getMonoFontFamily: { [weak self] in self?.currentFontFamily ?? self?.appState.config.code.fontFamily ?? "SF Mono" },
            getMonoFontSize: { [weak self] in self?.currentFontSize.map(Int.init) ?? self?.appState.config.code.fontSize ?? 13 }
        )
        definition = DefinitionFeature(
            textView: textView,
            getClient: { [weak self] in
                guard let self, let lang = self.currentLanguage else { return nil }
                if let abs = self.currentExternalAbsolutePath,
                   let originating = self.currentOriginatingWorktreeRoot {
                    let absURL = URL(fileURLWithPath: abs)
                    return self.appState.lsp.client(forFile: absURL, worktreeRoot: originating, language: lang)
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return self.appState.lsp.client(forFile: root.appendingPathComponent(rel), worktreeRoot: root, language: lang)
            },
            getURI: { [weak self] in
                guard let self else { return nil }
                if let abs = self.currentExternalAbsolutePath {
                    return URL(fileURLWithPath: abs).lspURI
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            },
            openTarget: { [weak self] url, line, character in
                guard let self,
                      let wid = self.currentWorktreeId else { return }
                // For external buffers, the originating worktree root is the
                // anchor for in-worktree-vs-external classification, not the
                // sentinel that bindBuffer set on currentRoot.
                let anchor = self.currentOriginatingWorktreeRoot ?? self.currentRoot
                guard let root = anchor else { return }
                let abs = url.path
                let prefix = root.path + "/"
                if abs.hasPrefix(prefix) {
                    let rel = String(abs.dropFirst(prefix.count))
                    self.appState.tabs.openEditor(
                        worktreeId: wid,
                        relativePath: rel,
                        revealLine: line,
                        revealCharacter: character
                    )
                } else {
                    // Pass the current in-worktree file as the originating
                    // path so LSP traffic for the external file is routed to
                    // the correct holder in nested-package layouts.
                    // Also pass the worktree root and language so TabsManager
                    // can rebind the LSP holder even when the tab is inactive.
                    let originatingRel = self.currentExternalAbsolutePath == nil
                        ? self.currentRelativePath
                        : self.currentOriginatingRelativePath
                    let originatingRoot = self.currentOriginatingWorktreeRoot ?? self.currentRoot
                    let lang = self.currentLanguage
                    self.appState.tabs.openExternalEditor(
                        worktreeId: wid,
                        absoluteURL: url,
                        revealLine: line,
                        revealCharacter: character,
                        originatingRelativePath: originatingRel,
                        originatingWorktreeRoot: originatingRoot,
                        language: lang
                    )
                }
            }
        )
        hoverHighlight = HoverHighlightFeature(
            textView: textView,
            getClient: { [weak self] in
                guard let self, let lang = self.currentLanguage else { return nil }
                if let abs = self.currentExternalAbsolutePath,
                   let originating = self.currentOriginatingWorktreeRoot {
                    let absURL = URL(fileURLWithPath: abs)
                    return self.appState.lsp.client(forFile: absURL, worktreeRoot: originating, language: lang)
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return self.appState.lsp.client(forFile: root.appendingPathComponent(rel), worktreeRoot: root, language: lang)
            },
            getURI: { [weak self] in
                guard let self else { return nil }
                if let abs = self.currentExternalAbsolutePath {
                    return URL(fileURLWithPath: abs).lspURI
                }
                guard let root = self.currentRoot,
                      let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            }
        )

        // LSP open/close for external buffers is managed by TabsManager
        // (tied to the buffer's cached lifetime), not by the coordinator
        // (which is torn down on every tab switch by SwiftUI's dismantleNSView).
        // However, the initial open may have found no holder if the language
        // server hadn't started yet (e.g. persisted external tab restored
        // before any in-worktree file launches the server). Retry here so
        // that when the coordinator re-attaches after a server is up,
        // hover and ⌘-click start working without the user closing the tab.
        if externalAbsolutePath != nil {
            appState.tabs.ensureExternalLSPOpen(tabId: tabId)
        }

        applyRevealIfNeeded(tabId: tabId, line: revealLine, character: revealCharacter)

        NotificationCenter.default.post(
            name: .codeEditorDidAttach,
            object: self,
            userInfo: ["textView": textView, "tabId": tabId]
        )
    }

    func updateIfNeeded(worktreeId: String, worktreeRoot: URL, relativePath: String, tabId: TabID, revealLine: Int?, revealCharacter: Int?, theme: Theme, externalAbsolutePath: String? = nil, originatingRelativePath: String? = nil) {
        let nextLanguage: String?
        if let abs = externalAbsolutePath {
            nextLanguage = appState.lsp.language(forFileExtension: (abs as NSString).pathExtension)
        } else {
            nextLanguage = appState.lsp.language(forFileExtension: (relativePath as NSString).pathExtension)
        }

        let pathChanged: Bool
        if externalAbsolutePath != nil || currentExternalAbsolutePath != nil {
            // External-tab identity: only the (worktree, tabId, abs path) tuple matters.
            // Don't compare currentRoot/currentRelativePath against the in-worktree
            // worktreeRoot/relativePath — bindBuffer set them to sentinel values for
            // the external buffer, which will never equal the parameters here.
            // The || currentExternalAbsolutePath != nil clause catches the
            // in-worktree-to-external and external-to-in-worktree transitions.
            pathChanged = currentWorktreeId != worktreeId
                || currentTabId != tabId
                || currentExternalAbsolutePath != externalAbsolutePath
                || currentOriginatingRelativePath != originatingRelativePath
                || currentLanguage != nextLanguage
        } else {
            pathChanged = currentWorktreeId != worktreeId
                || currentTabId != tabId
                || currentRoot != worktreeRoot
                || currentRelativePath != relativePath
                || currentLanguage != nextLanguage
        }

        if pathChanged {
            hoverHighlight?.cancelAndClear()
            didChangeTask?.cancel()
            hasPendingDidChange = false
            pendingTextEdits.removeAll()
            let session = highlightSession
            Task { await session.reset() }

            currentWorktreeId = worktreeId
            currentTabId = tabId
            currentExternalAbsolutePath = externalAbsolutePath
            if externalAbsolutePath != nil {
                currentOriginatingWorktreeRoot = worktreeRoot
                currentOriginatingRelativePath = originatingRelativePath
            } else {
                currentOriginatingWorktreeRoot = nil
                currentOriginatingRelativePath = nil
            }

            // Fetch (and if needed, create) the buffer for the new tab and
            // re-bind the layout manager onto its storage. Without this swap
            // the text view keeps rendering the *previous* buffer's storage,
            // so every editor tab appears to show the file that was opened
            // first.
            let nextBuffer: EditorBuffer
            if let abs = externalAbsolutePath {
                let absURL = URL(fileURLWithPath: abs)
                let originatingFileURL: URL? = originatingRelativePath.flatMap {
                    worktreeRoot.appendingPathComponent($0)
                }
                let language = appState.lsp.language(
                    forFileExtension: (abs as NSString).pathExtension
                )
                nextBuffer = appState.tabs.externalBuffer(
                    worktreeId: worktreeId,
                    tabId: tabId,
                    absoluteURL: absURL,
                    worktreeRoot: worktreeRoot,
                    originatingFileURL: originatingFileURL,
                    language: language
                )
            } else {
                nextBuffer = appState.tabs.buffer(
                    worktreeId: worktreeId,
                    tabId: tabId,
                    worktreeRoot: worktreeRoot,
                    relativePath: relativePath
                )
            }
            bindBuffer(nextBuffer, theme: theme)

            if nextBuffer.isExternal {
                textView?.isEditable = false
            } else {
                textView?.isEditable = true
            }
            // Note: origin-change rebinding (close-old-holder / open-new-holder)
            // is now handled entirely by TabsManager.rebindExternalLSPHolder,
            // which runs at openExternalEditor() time regardless of tab activation.
            // The coordinator's externalBuffer() call above drives
            // ensureExternalLSPOpen for the common case where the tab is active
            // but the origin didn't change (normal tab switch).
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
        pullDiagnosticsTask?.cancel()
        pullDiagnosticsTask = nil
        let isRebind = self.buffer != nil
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
        applyIndentationMode()
        if let layoutManager {
            buffer.storage.addLayoutManager(layoutManager)
        }
        if isRebind {
            // Drop any state captured against the previous buffer before we
            // start the highlight: stale diagnostics would otherwise be
            // re-applied to the new storage by the async highlight task, and
            // stale undo records would let Undo/Redo mutate the wrong tab
            // because the NSUndoManager belongs to the (reused) NSTextView.
            diagnosticsFeature.reset()
            textView?.undoManager?.removeAllActions()
            textView?.setSelectedRange(NSRange(location: 0, length: 0))
        }
        applyBaseStyle(theme: theme)
        runHighlight(theme: theme)
        subscribeIfPossible(theme: theme)
        editObserverToken = buffer.onTextEdit { [weak self] edit in
            self?.scheduleEditPropagation(edit: edit)
        }
    }

    func detach() {
        // LSP open/close for external buffers is managed by TabsManager
        // (tied to the buffer's cached lifetime), not by the coordinator
        // (which is torn down on every tab switch by SwiftUI's dismantleNSView).
        // Do NOT call closeExternalDocument here.
        currentExternalAbsolutePath = nil
        currentOriginatingWorktreeRoot = nil
        currentOriginatingRelativePath = nil
        if let buffer, let token = editObserverToken {
            buffer.removeOnEdit(token)
        }
        editObserverToken = nil
        if hasPendingDidChange {
            notifyLSPDidChange(edits: pendingTextEdits)
            hasPendingDidChange = false
        }
        pendingTextEdits.removeAll()
        pullDiagnosticsTask?.cancel()
        pullDiagnosticsTask = nil
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
        hoverHighlight = nil
        textView?.hoverHandler = nil
        textView?.commandClickHandler = nil
        textView?.flagsChangedHandler = nil
        textView?.mouseExitedHandler = nil
        textView?.increaseFontSizeHandler = nil
        textView?.decreaseFontSizeHandler = nil
        textView?.resetFontSizeHandler = nil
        textView = nil
        buffer = nil
        // We deliberately do NOT close the LSP document or stop the file
        // watcher — the buffer owns those for as long as the tab is alive.

        NotificationCenter.default.post(
            name: .codeEditorDidDetach,
            object: self,
            userInfo: ["tabId": tabId as Any]
        )
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
        let theme = currentTheme
        Task {
            await appState.lsp.didChange(
                worktreeRoot: buffer.worktreeRoot,
                fileURL: url,
                languageId: language,
                text: text,
                edits: edits
            )
            if let theme,
               let client = appState.lsp.client(forFile: url, worktreeRoot: buffer.worktreeRoot, language: language),
               await client.supportsPullDiagnostics {
                await self.performPullDiagnostics(client: client, uri: url.lspURI, theme: theme)
            }
        }
    }

    // MARK: - Highlight + base styling

    private func applyIndentationMode() {
        if let language = currentLanguage, !language.isEmpty {
            textView?.indentationMode = .bracketAware
        } else {
            textView?.indentationMode = .plain
        }
    }

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
            .foregroundColor: editorTheme.defaultFG,
            .paragraphStyle: CenterTypography.paragraphStyle()
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
        // Restore from cache instead of clearing. The LSP server doesn't
        // replay past batches to new subscribers, so without this a tab
        // switch would lose its squiggles until the server happened to
        // republish (typically only after an edit/save). When there's no
        // cached batch this still acts as the clear it used to be.
        let bufferURI = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI
        let cached = lastDiagnosticsByURI[bufferURI] ?? []
        diagnosticsFeature.apply(cached, to: buffer.storage, theme: theme)
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
            await self.subscribeDiagnostics(for: client, theme: theme)
            await self.symbolsFeature.refresh(client: client, uri: url.lspURI)
            if await client.supportsPullDiagnostics {
                self.startPullDiagnosticsIfNeeded(for: client, uri: url.lspURI, theme: theme)
            }
        }
    }

    private func subscribeDiagnostics(for client: LSPClient?, theme: Theme) async {
        guard let client else { return }
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            for await batch in await client.subscribeDiagnostics() {
                await MainActor.run {
                    self?.processDiagnosticsBatch(batch, theme: theme)
                }
            }
        }
    }

    private func performPullDiagnostics(client: LSPClient, uri: String, theme: Theme) async {
        guard !Task.isCancelled else { return }
        do {
            if let diags = try await client.requestDiagnostics(uri: uri, previousResultId: nil) {
                let batch = LSPPublishDiagnosticsParams(uri: uri, diagnostics: diags)
                await MainActor.run {
                    self.processDiagnosticsBatch(batch, theme: theme)
                }
            }
        } catch {
            // Best-effort.
        }
    }

    private func startPullDiagnosticsIfNeeded(for client: LSPClient, uri: String, theme: Theme) {
        pullDiagnosticsTask?.cancel()
        pullDiagnosticsTask = Task { [weak self] in
            guard let self else { return }
            var first = true
            while !Task.isCancelled {
                if !first {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                }
                first = false
                await self.performPullDiagnostics(client: client, uri: uri, theme: theme)
            }
        }
    }

    /// Cache every batch we see (so a rebind back to a previously-open file
    /// can restore its squiggles), but only paint when the batch's URI
    /// matches the *currently bound* buffer's URI. Cancelling the old
    /// `diagnosticsTask` doesn't synchronously drain in-flight batches, so
    /// without this active-URI check a batch from the previous subscription
    /// could land on the new buffer's storage between cancellation and the
    /// new subscription starting.
    func processDiagnosticsBatch(_ batch: LSPPublishDiagnosticsParams, theme: Theme) {
        lastDiagnosticsByURI[batch.uri] = batch.diagnostics
        guard let buffer else { return }
        let activeURI = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI
        guard batch.uri == activeURI else { return }
        diagnosticsFeature.apply(batch.diagnostics, to: buffer.storage, theme: theme)
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
