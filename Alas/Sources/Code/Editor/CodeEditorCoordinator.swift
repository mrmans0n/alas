import AppKit
import Foundation
import Observation

/// Lifecycle adapter between a `CodeTextView` (per-mount, recreated by
/// SwiftUI) and an `EditorBuffer` (per-tab, owned by `TabsManager`). The
/// coordinator handles syntax highlighting, LSP `didChange` debouncing,
/// hover/definition feature wiring, theme repaints, and go-to-definition
/// reveal scrolling. Disk I/O, save, file-watch, and dirty tracking live
/// in `EditorBuffer`.
@MainActor
final class CodeEditorCoordinator {
    let appState: AppState
    var onTextViewAttached: ((CodeTextView, TabID) -> Void)?
    var onTextViewDetached: ((CodeTextView?, TabID?) -> Void)?
    var onInitialHighlightReady: ((TabID) -> Void)?

    private weak var textView: CodeTextView?
    private weak var buffer: EditorBuffer?
    private var layoutManager: NSLayoutManager?

    private var currentTabId: TabID?
    private var currentWorktreeId: String?

    var tabId: TabID? { currentTabId }
    var currentBufferReadOnly: Bool { buffer?.readOnly ?? true }
    private var currentRoot: URL?
    private var currentRelativePath: String?
    private var currentLanguage: String?
    private var currentTheme: Theme?
    private var currentFontFamily: String?
    private var currentFontSize: CGFloat?
    private var lastAppliedReveal: (tabId: TabID, line: Int, endLine: Int?, character: Int, revision: Int)?
    private var pendingReveal: (tabId: TabID, line: Int, endLine: Int?, character: Int, revision: Int)?
    private var revealHighlightTask: Task<Void, Never>?
    private var revealHighlightRange: NSRange?
    private var currentExternalAbsolutePath: String?
    private var currentExternalEditable: Bool = false
    private var currentOriginatingWorktreeRoot: URL?
    private var currentOriginatingRelativePath: String?
    private var lspBinding: EditorLSPBinding?
    private var editorCommandRouter: EditorCommandRouter?
    private var editorCommandStatusTask: Task<Void, Never>?
    private var renameFeature: RenameFeature?
    private var codeActionsFeature: CodeActionsFeature?
    private var semanticFeature: SemanticTokensFeature?
    private var semanticLayer: EditorSemanticLayer?
    private var semanticClient: LSPClient?
    private var semanticSubscription: Task<Void, Never>?
    private var semanticBindingID = UUID()
    private var semanticSupportsRange = false

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
    private var hoverObservers: [NSObjectProtocol] = []
    private var definition: DefinitionFeature?
    private var navigation: NavigationFeature?
    private var hoverHighlight: HoverHighlightFeature?
    private var completion: CompletionFeature?
    private var signatureHelp: SignatureHelpFeature?
    private var reportedInitialHighlightReady = false

    private var editObserverToken: EditorBuffer.EditObserverToken?
    private var didChangeTask: Task<Void, Never>?
    private var hasPendingDidChange = false
    private var pendingTextEdits: [EditorTextEdit] = []
    private let highlightSession = TreeSitterHighlighter.Session()

    private struct LSPDidChangePayload {
        let worktreeRoot: URL
        let relativePath: String
        let fileURL: URL
        let language: String
        let text: String
        let edits: [EditorTextEdit]?
        let theme: Theme?
    }

    static func resolveFont(family: String, size: CGFloat) -> NSFont {
        CenterTypography.resolveCodeFont(family: family, size: size)
    }

    init(appState: AppState) {
        self.appState = appState
    }

    func attach(textView: CodeTextView, buffer: EditorBuffer, layoutManager: NSLayoutManager, worktreeId: String, worktreeRoot: URL, tabId: TabID, revealLine: Int?, revealEndLine: Int? = nil, revealCharacter: Int?, revealRevision: Int? = nil, theme: Theme, externalAbsolutePath: String? = nil, originatingRelativePath: String? = nil, externalEditable: Bool = false) {
        self.textView = textView
        self.layoutManager = layoutManager
        self.currentWorktreeId = worktreeId
        self.currentTabId = tabId
        self.currentTheme = theme
        self.currentExternalAbsolutePath = externalAbsolutePath
        self.currentExternalEditable = externalEditable
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

        // Only external buffers gate editability on `readOnly` (they load
        // synchronously, so it's settled by bind time; editable run-script
        // buffers are writable, ⌘-click default ones are locked). Non-external
        // buffers stay editable regardless of `readOnly` — a remote in-worktree
        // buffer is transiently read-only while its async load runs, and
        // EditorBuffer.save()'s own `guard !readOnly` prevents a mid-load write.
        textView.isEditable = !buffer.isExternal || !buffer.readOnly

        hover = HoverFeature(
            textView: textView,
            getClient: { [weak self] in self?.currentLSPClient() },
            getURI: { [weak self] in
                guard let self else { return nil }
                if let abs = self.currentExternalAbsolutePath {
                    return URL(fileURLWithPath: abs).lspURI
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            },
            getTheme: { [weak self] in self?.currentTheme ?? (try? ThemeStore().current) ?? (try? Theme.loadBundled(id: "cool-slate")) ?? Theme(id: "fallback", name: "Fallback", tokens: [:]) },
            getMonoFontFamily: { [weak self] in self?.currentFontFamily ?? self?.appState.config.code.fontFamily ?? "JetBrainsMono Nerd Font" },
            getMonoFontSize: { [weak self] in self?.currentFontSize.map(Int.init) ?? self?.appState.config.code.fontSize ?? 13 },
            synchronizeRequest: { [weak self] range in await self?.synchronizeLSPRequest(range: range) },
            isContextCurrent: { [weak self] context in self?.isLSPRequestCurrent(context) ?? false }
        )
        installHoverObservers(textView: textView)
        definition = DefinitionFeature(
            textView: textView,
            getClient: { [weak self] in self?.currentLSPClient() },
            getURI: { [weak self] in
                guard let self else { return nil }
                if let abs = self.currentExternalAbsolutePath {
                    return URL(fileURLWithPath: abs).lspURI
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            },
            openTarget: { [weak self] url, line, character, sourcePosition in
                guard let self,
                      let source = self.navigationSource(at: sourcePosition),
                      let wid = self.currentWorktreeId else { return }
                let anchor = self.currentOriginatingWorktreeRoot ?? self.currentRoot
                guard let root = anchor else { return }
                let target = EditorNavigationTarget(
                    document: EditorDocumentID(
                        host: RemoteHostRegistry.shared.host(forPath: root.path),
                        worktreeID: wid,
                        uri: url.lspURI
                    ),
                    position: LSPPosition(line: line, character: character)
                )
                if self.appState.tabs.openNavigationTarget(
                    target,
                    worktreeRoot: root,
                    originatingRelativePath: self.currentExternalAbsolutePath == nil
                        ? self.currentRelativePath
                        : self.currentOriginatingRelativePath,
                    language: self.currentLanguage
                ) {
                    self.appState.tabs.navigationStore(forWorktreeId: wid).recordJump(from: source, to: target)
                } else {
                    self.appState.tabs.navigationStore(forWorktreeId: wid).recordActivationFailure(for: target)
                }
            },
            cancelPendingNavigation: { [weak self] in
                self?.navigation?.cancelPendingRequest()
            },
            synchronizeRequest: { [weak self] range in await self?.synchronizeLSPRequest(range: range) },
            isContextCurrent: { [weak self] context in self?.isLSPRequestCurrent(context) ?? false }
        )
        let initialNavigationStore = appState.tabs.navigationStore(forWorktreeId: worktreeId)
        navigation = NavigationFeature(
            store: { [weak self, initialNavigationStore] in
                guard let self else { return initialNavigationStore }
                return self.appState.tabs.navigationStore(forWorktreeId: self.currentWorktreeId ?? worktreeId)
            },
            synchronizeRequest: { [weak self] range in await self?.synchronizeLSPRequest(range: range) },
            isContextCurrent: { [weak self] context in self?.isLSPRequestCurrent(context) ?? false }
        )
        hoverHighlight = HoverHighlightFeature(
            textView: textView,
            getClient: { [weak self] in self?.currentLSPClient() },
            getURI: { [weak self] in
                guard let self else { return nil }
                if let abs = self.currentExternalAbsolutePath {
                    return URL(fileURLWithPath: abs).lspURI
                }
                guard let root = self.currentRoot,
                      let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            },
            synchronizeRequest: { [weak self] range in await self?.synchronizeLSPRequest(range: range) },
            isContextCurrent: { [weak self] context in self?.isLSPRequestCurrent(context) ?? false }
        )
        completion = CompletionFeature(
            textView: textView,
            getClient: { [weak self] in self?.currentLSPClient() },
            getURI: { [weak self] in
                guard let self else { return nil }
                if let abs = self.currentExternalAbsolutePath {
                    return URL(fileURLWithPath: abs).lspURI
                }
                guard let root = self.currentRoot,
                      let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            },
            isEnabled: { [weak self] in
                guard let self,
                      self.currentExternalAbsolutePath == nil,
                      self.currentLanguage != nil,
                      self.buffer?.isExternal != true,
                      self.buffer?.readOnly == false else {
                    return false
                }
                return true
            },
            getTheme: { [weak self] in self?.currentTheme ?? (try? ThemeStore().current) ?? (try? Theme.loadBundled(id: "cool-slate")) ?? Theme(id: "fallback", name: "Fallback", tokens: [:]) },
            getMonoFontFamily: { [weak self] in self?.currentFontFamily ?? self?.appState.config.code.fontFamily ?? "JetBrainsMono Nerd Font" },
            getMonoFontSize: { [weak self] in self?.currentFontSize.map(Int.init) ?? self?.appState.config.code.fontSize ?? 13 },
            prepareForCompletionRequest: { [weak self] in
                await self?.flushPendingLSPDidChangeForCompletion()
            },
            synchronizeRequest: { [weak self] range in await self?.synchronizeLSPRequest(range: range) },
            isContextCurrent: { [weak self] context in self?.isLSPRequestCurrent(context) ?? false },
            applyWorkspaceCompletion: { [weak self] plan, snapshot, context in
                await self?.applyWorkspaceCompletion(plan, snapshot: snapshot, context: context) ?? false
            }
        )
        signatureHelp = SignatureHelpFeature(
            textView: textView,
            getClient: { [weak self] in self?.currentLSPClient() },
            getURI: { [weak self] in
                guard let self else { return nil }
                if let abs = self.currentExternalAbsolutePath {
                    return URL(fileURLWithPath: abs).lspURI
                }
                guard let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return root.appendingPathComponent(rel).lspURI
            },
            isEnabled: { [weak self] in
                guard let self,
                      self.currentLanguage != nil,
                      self.buffer?.readOnly == false,
                      self.buffer?.isExternal != true else { return false }
                return true
            },
            prepareForSignatureHelpRequest: { [weak self] in
                await self?.flushPendingLSPDidChangeForSignatureHelp()
            },
            synchronizeRequest: { [weak self] range in await self?.synchronizeLSPRequest(range: range) },
            isContextCurrent: { [weak self] context in self?.isLSPRequestCurrent(context) ?? false }
        )
        installEditorCommands(on: textView)

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

        restoreViewStateIfNeeded(for: buffer, tabId: tabId, revealLine: revealLine, revealCharacter: revealCharacter)

        applyRevealIfNeeded(
            tabId: tabId,
            line: revealLine,
            endLine: revealEndLine,
            character: revealCharacter,
            revision: revealRevision
        )

        NotificationCenter.default.post(
            name: .codeEditorDidAttach,
            object: self,
            userInfo: ["textView": textView, "tabId": tabId]
        )
        onTextViewAttached?(textView, tabId)
    }

    func updateIfNeeded(worktreeId: String, worktreeRoot: URL, relativePath: String, tabId: TabID, revealLine: Int?, revealEndLine: Int? = nil, revealCharacter: Int?, revealRevision: Int? = nil, theme: Theme, externalAbsolutePath: String? = nil, originatingRelativePath: String? = nil, externalEditable: Bool = false) {
        // Re-query the registry every time so a registry change (e.g. a
        // server gets installed) still flips this comparison and triggers a
        // rebind. When the same tab is being re-evaluated and has an
        // override set, layer the override on top — otherwise the path
        // identity check would see `currentLanguage = override` vs.
        // `nextLanguage = inferred` permanently and rebind on every update,
        // churning undo/selection state.
        let inferred: String?
        if let abs = externalAbsolutePath {
            inferred = appState.lsp.language(forPath: abs)
        } else {
            inferred = appState.lsp.language(forPath: relativePath)
        }
        let nextLanguage: String?
        if let buf = self.buffer, currentWorktreeId == worktreeId, currentTabId == tabId {
            nextLanguage = buf.languageOverride ?? inferred
        } else {
            nextLanguage = inferred
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
                || currentExternalEditable != externalEditable
        } else {
            pathChanged = currentWorktreeId != worktreeId
                || currentTabId != tabId
                || currentRoot != worktreeRoot
                || currentRelativePath != relativePath
                || currentLanguage != nextLanguage
        }

        if pathChanged {
            saveViewState()
            clearRevealHighlight()
            hoverHighlight?.cancelAndClear()
            completion?.cancelAndDismiss()
            textView?.endSnippet()
            signatureHelp?.cancelAndDismiss()
            reportedInitialHighlightReady = false
            didChangeTask?.cancel()
            hasPendingDidChange = false
            pendingTextEdits.removeAll()
            let session = highlightSession
            Task { await session.reset() }

            currentWorktreeId = worktreeId
            currentTabId = tabId
            currentExternalAbsolutePath = externalAbsolutePath
            currentExternalEditable = externalEditable
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
                let language = appState.lsp.language(forPath: abs)
                nextBuffer = appState.tabs.externalBuffer(
                    worktreeId: worktreeId,
                    tabId: tabId,
                    absoluteURL: absURL,
                    worktreeRoot: worktreeRoot,
                    originatingFileURL: originatingFileURL,
                    language: language,
                    editable: externalEditable
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

            // Only external buffers gate editability on `readOnly` (settled by
            // bind time). Non-external buffers stay editable regardless — a
            // remote in-worktree buffer is transiently read-only while its async
            // load runs, and EditorBuffer.save()'s own `guard !readOnly`
            // prevents a mid-load write. Editable external (run-script) buffers
            // stay writable; ⌘-click default ones stay locked.
            textView?.isEditable = !nextBuffer.isExternal || !nextBuffer.readOnly
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

        if pathChanged, let buffer {
            restoreViewStateIfNeeded(
                for: buffer,
                tabId: tabId,
                revealLine: revealLine,
                revealCharacter: revealCharacter,
                deferred: false,
                resetScrollWhenMissing: true
            )
        }

        applyRevealIfNeeded(
            tabId: tabId,
            line: revealLine,
            endLine: revealEndLine,
            character: revealCharacter,
            revision: revealRevision
        )
    }

    /// Wire the coordinator and the text view to `buffer`. If a previous
    /// buffer is already bound, its layout manager and edit observer are torn
    /// down first so the text view stops rendering the old storage.
    private func observeEffectiveLanguage(_ buffer: EditorBuffer) {
        // One-shot `withObservationTracking` re-arms itself from `onChange`.
        // This observer only mirrors `buffer.effectiveLanguage` into
        // `currentLanguage` — LSP open/close lives in `EditorBuffer`.
        // Keeping `currentLanguage` accurate is critical because hover,
        // definition, completion, diagnostics, didChange, and indentation
        // all route through it.
        _ = withObservationTracking {
            _ = buffer.effectiveLanguage
        } onChange: { [weak self, weak buffer] in
            Task { @MainActor [weak self, weak buffer] in
                guard let self, let buffer, self.buffer === buffer else { return }
                self.currentLanguage = buffer.effectiveLanguage
                self.semanticFeature?.invalidate()
                self.updateSemanticClient()
                self.applyIndentationMode()
                self.observeEffectiveLanguage(buffer)
            }
        }
    }

    private func bindBuffer(_ buffer: EditorBuffer, theme: Theme) {
        stopSemanticTokens()
        textView?.displayAdapter?.composition.commit()
        textView?.bindUndo(to: nil)
        pullDiagnosticsTask?.cancel()
        pullDiagnosticsTask = nil
        let isRebind = self.buffer != nil
        if let previous = self.buffer {
            if let token = editObserverToken {
                previous.removeOnEdit(token)
            }
            editObserverToken = nil
            try? textView?.bindDisplay(to: nil)
        }
        self.buffer = buffer
        textView?.bindUndo(to: buffer)
        self.currentRoot = buffer.worktreeRoot
        self.currentRelativePath = buffer.relativePath
        if let worktreeID = currentWorktreeId, !buffer.isExternal {
            lspBinding = EditorLSPBinding(
                manager: appState.lsp,
                buffer: buffer,
                worktreeID: worktreeID,
                flushPendingChanges: { [weak self] in
                    await self?.flushPendingLSPDidChangeForCompletion()
                }
            )
        } else {
            lspBinding = nil
        }
        let ext = LanguageServerRegistry.extensionKey(forPath: buffer.relativePath)
        let freshlyInferred = appState.lsp.language(forFileExtension: ext)
        // Layer a pre-existing override on top of the freshly inferred
        // language. We don't read `buffer.effectiveLanguage` directly
        // because `buffer.language` is captured at buffer-init time and
        // can be stale after a registry change (e.g. a server gets
        // installed) — using the fresh registry lookup keeps that
        // transition working while still honoring override.
        currentLanguage = buffer.languageOverride ?? freshlyInferred
        observeEffectiveLanguage(buffer)
        applyIndentationMode()
        do { try textView?.bindDisplay(to: buffer) }
        catch {
            if let layoutManager { buffer.storage.addLayoutManager(layoutManager) }
        }
        if isRebind {
            // Drop any state captured against the previous buffer before we
            // start the highlight: stale diagnostics would otherwise be
            // re-applied to the new storage by the async highlight task.
            diagnosticsFeature.reset()
            textView?.setSelectedRange(NSRange(location: 0, length: 0))
        }
        applyBaseStyle(theme: theme)
        configureSemanticTokens(theme: theme)
        runHighlight(theme: theme)
        subscribeIfPossible(theme: theme)
        editObserverToken = buffer.onTextEdit { [weak self] edit in
            self?.scheduleEditPropagation(edit: edit)
        }
    }

    private func saveViewState() {
        guard let textView, let buffer, let currentTabId else { return }
        buffer.viewStates[currentTabId] = (
            textView.sourceSelectedRanges,
            textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        )
    }

    private func restoreViewStateIfNeeded(
        for buffer: EditorBuffer,
        tabId: TabID,
        revealLine: Int?,
        revealCharacter: Int?,
        deferred: Bool = true,
        resetScrollWhenMissing: Bool = false
    ) {
        guard revealLine == nil || revealCharacter == nil,
              let textView else { return }
        guard let viewState = buffer.viewStates[tabId] else {
            if resetScrollWhenMissing {
                scroll(textView, to: .zero)
            }
            return
        }
        if deferred {
            DispatchQueue.main.async { [weak self, weak textView, weak buffer] in
                self?.applyViewState(viewState, for: buffer, textView: textView, tabId: tabId)
            }
        } else {
            applyViewState(viewState, for: buffer, textView: textView, tabId: tabId)
        }
    }

    private func applyViewState(
        _ viewState: (selectedRanges: [NSValue], scrollOrigin: NSPoint),
        for buffer: EditorBuffer?,
        textView: CodeTextView?,
        tabId: TabID
    ) {
        guard let textView, let buffer,
              self.textView === textView,
              self.buffer === buffer,
              currentTabId == tabId else { return }
        let ranges = viewState.selectedRanges.map { value in
            let range = value.rangeValue
            let location = min(range.location, buffer.storage.length)
            let length = min(range.length, buffer.storage.length - location)
            return NSValue(range: NSRange(location: location, length: length))
        }
        textView.setSourceSelectedRanges(ranges)
        scroll(textView, to: viewState.scrollOrigin)
    }

    private func scroll(_ textView: CodeTextView, to origin: NSPoint) {
        guard let scrollView = textView.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func detach() {
        stopSemanticTokens()
        textView?.displayAdapter?.composition.commit()
        let detachedTextView = textView
        textView?.endSnippet()
        textView?.bindUndo(to: nil)
        saveViewState()
        // LSP open/close for external buffers is managed by TabsManager
        // (tied to the buffer's cached lifetime), not by the coordinator
        // (which is torn down on every tab switch by SwiftUI's dismantleNSView).
        // Do NOT call closeExternalDocument here.
        currentExternalAbsolutePath = nil
        currentExternalEditable = false
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
        try? textView?.bindDisplay(to: nil)
        if let layoutManager { layoutManager.textStorage?.removeLayoutManager(layoutManager) }
        layoutManager = nil
        clearHoverObservers()
        hover?.tearDown()
        hover = nil
        definition = nil
        hoverHighlight = nil
        completion?.cancelAndDismiss()
        completion = nil
        signatureHelp?.tearDown()
        signatureHelp = nil
        lspBinding = nil
        editorCommandStatusTask?.cancel()
        renameFeature?.cancel()
        renameFeature = nil
        codeActionsFeature?.cancel()
        codeActionsFeature = nil
        editorCommandStatusTask = nil
        if let editorCommandRouter {
            EditorCommandAvailability.shared.deactivate(editorCommandRouter)
        }
        editorCommandRouter = nil
        textView?.editorCommandRouter = nil
        textView?.hoverHandler = nil
        textView?.commandClickHandler = nil
        textView?.flagsChangedHandler = nil
        textView?.mouseExitedHandler = nil
        textView?.completionManualTriggerHandler = nil
        textView?.completionChangeHandler = nil
        textView?.completionSelectionChangeHandler = nil
        textView?.completionKeyHandler = nil
        textView?.signatureHelpManualTriggerHandler = nil
        textView?.signatureHelpChangeHandler = nil
        textView?.signatureHelpSelectionChangeHandler = nil
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
        onTextViewDetached?(detachedTextView, tabId)
    }

    // MARK: - Hover observers

    private func installHoverObservers(textView: CodeTextView) {
        clearHoverObservers()
        let nc = NotificationCenter.default

        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            let token = nc.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.hover?.notifyScrolled()
                self?.definition?.notifyScrolled()
                self?.signatureHelp?.notifyScrolled()
                Task { @MainActor [weak self] in self?.scheduleSemanticRefresh(visibleRangeChanged: true) }
            }
            hoverObservers.append(token)
        }

        let selectionToken = nc.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            guard self?.textView?.displayAdapter?.isRebuilding != true else { return }
            self?.hover?.notifyCaretChanged()
            self?.definition?.notifyCaretChanged()
            self?.signatureHelp?.notifyScrolled()
        }
        hoverObservers.append(selectionToken)

        // Subscribe with object: nil because attach(...) runs from
        // makeNSView before the text view is inserted into a window, so
        // textView.window is often nil here and never gets retried. The
        // handler filters to the text view's current window at fire time.
        let resizeToken = nc.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let window = note.object as? NSWindow,
                  window === self.textView?.window else { return }
            self.hover?.notifyWindowResized()
            self.definition?.notifyWindowResized()
            self.signatureHelp?.notifyWindowResized()
            Task { @MainActor [weak self] in self?.scheduleSemanticRefresh(visibleRangeChanged: true) }
        }
        hoverObservers.append(resizeToken)

        textView.escapeHandler = { [weak self] in
            if self?.signatureHelp?.handleEscape() == true { return true }
            return self?.hover?.handleEscape() ?? false
        }
    }

    private func clearHoverObservers() {
        let nc = NotificationCenter.default
        for token in hoverObservers {
            nc.removeObserver(token)
        }
        hoverObservers.removeAll()
        textView?.escapeHandler = nil
    }

    // MARK: - Editor commands

    private func applyWorkspaceCompletion(_ completion: CompletionEditPlan, snapshot: String, context: EditorRequestContext) async -> Bool {
        guard isLSPRequestCurrent(context), textView?.string == snapshot, let renameFeature else { return false }
        let coordinates = TextEditCoordinates.LineIndex(snapshot)
        var edits: [LSPTextEdit] = []
        for edit in completion.edits {
            guard let start = coordinates.lspPosition(utf16Offset: edit.range.location),
                  let end = coordinates.lspPosition(utf16Offset: NSMaxRange(edit.range)) else { return false }
            edits.append(LSPTextEdit(range: LSPRange(start: start, end: end), newText: edit.replacementText))
        }
        let generations = appState.tabs.workspaceEditGenerations(host: context.document.host, worktreeID: context.document.worktreeID)
        do {
            let plan = try await renameFeature.prepare(.init(changes: [context.document.uri: edits]), context: context, generations: generations)
            guard !Task.isCancelled, isLSPRequestCurrent(context), textView?.string == snapshot, !plan.requiresPreview else { return false }
            return await renameFeature.makePreviewModel(plan: plan, context: context).apply()
        } catch { return false }
    }

    private func installEditorCommands(on textView: CodeTextView) {
        renameFeature?.cancel()
        codeActionsFeature?.cancel()
        if let root = currentOriginatingWorktreeRoot ?? currentRoot {
            renameFeature = RenameFeature(textView: textView, tabs: appState.tabs, root: root,
                                          synchronize: { [weak self] range in await self?.synchronizeLSPRequest(range: range) },
                                          isCurrent: { [weak self] context in self?.isLSPRequestCurrent(context) == true })
            codeActionsFeature = CodeActionsFeature(textView: textView, tabs: appState.tabs, root: root,
                                                    synchronize: { [weak self] range in await self?.synchronizeLSPRequest(range: range) },
                                                    isCurrent: { [weak self] context in self?.isLSPRequestCurrent(context) == true },
                                                    diagnostics: { [weak self] in self?.diagnosticsFeature.current ?? [] })
        }
        let router = EditorCommandRouter()
        router.register(.definition) { [weak self, weak textView] range in
            self?.navigation?.cancelPendingRequest()
            textView?.triggerCommandClick(atUTF16Offset: range.location)
        }
        router.register(.typeDefinition) { [weak self] range in
            self?.navigation?.cancelPendingRequest()
            self?.definition?.goToTypeDefinition(range: range)
        }
        router.register(.implementation) { [weak self] range in
            self?.navigation?.cancelPendingRequest()
            self?.definition?.goToImplementation(range: range)
        }
        router.register(.references) { [weak self] range in
            self?.navigation?.perform(.references, range: range)
        }
        router.register(.back, isAvailable: { [weak self] in
            self?.currentNavigationStore?.canGoBack == true
        }) { [weak self] _ in
            self?.activateHistoryTarget(direction: .back)
        }
        router.register(.forward, isAvailable: { [weak self] in
            self?.currentNavigationStore?.canGoForward == true
        }) { [weak self] _ in
            self?.activateHistoryTarget(direction: .forward)
        }
        router.register(.nextProblem, isAvailable: { [weak self] in
            !(self?.diagnosticsFeature.current.isEmpty ?? true)
        }) { [weak self, weak textView] _ in
            self?.showProblem(from: textView?.selectedRange().location, backwards: false)
        }
        router.register(.previousProblem, isAvailable: { [weak self] in
            !(self?.diagnosticsFeature.current.isEmpty ?? true)
        }) { [weak self, weak textView] _ in
            self?.showProblem(from: textView?.selectedRange().location, backwards: true)
        }
        router.register(.hover) { [weak textView] range in
            textView?.triggerHover(atUTF16Offset: range.location)
        }
        let canEdit: () -> Bool = { [weak self] in
            guard let buffer = self?.buffer else { return false }
            return !buffer.readOnly && (!buffer.isExternal || buffer.externalEditable) && !buffer.undoManager.workspaceActionInFlight
        }
        router.register(.signatureHelp, isAvailable: canEdit) { [weak self] _ in
            self?.signatureHelp?.triggerManual()
        }
        router.register(.rename, isAvailable: canEdit) { [weak self] range in
            self?.renameFeature?.rename(range: range)
        }
        router.registerCodeActions(isAvailable: canEdit) { [weak self] range in
            self?.codeActionsFeature?.show(range: range)
        }
        router.register(.formatSelection, isAvailable: { [weak textView] in
            canEdit() && (textView?.selectedRange().length ?? 0) > 0
        }) { [weak self] range in
            guard range.length > 0 else { return }
            self?.renameFeature?.format(range: range, selectionOnly: true)
        }
        router.register(.formatDocument, isAvailable: canEdit) { [weak self] range in
            self?.renameFeature?.format(range: range, selectionOnly: false)
        }
        editorCommandRouter = router
        diagnosticsFeature.onChange = { [weak router] in
            router?.refreshAvailability()
        }
        currentNavigationStore?.setHistoryChangeHandler { [weak router] in
            router?.refreshAvailability()
        }
        textView.editorCommandRouter = router
        if textView.window?.firstResponder === textView {
            EditorCommandAvailability.shared.activate(router)
        }
        refreshEditorCommandCapabilities()
    }

    private func refreshEditorCommandCapabilities() {
        guard let router = editorCommandRouter else { return }
        guard let client = currentLSPClient() else {
            router.update(capabilities: .empty, isServerReady: false)
            return
        }
        Task { [weak self, weak router] in
            let capabilities = await client.capabilities
            let isReady = await client.isReady
            await MainActor.run {
                guard let self, let router, self.editorCommandRouter === router else { return }
                router.update(capabilities: capabilities, isServerReady: isReady)
            }
        }
    }

    private func trackEditorCommandAvailability(for client: LSPClient) {
        editorCommandStatusTask?.cancel()
        let router = editorCommandRouter
        editorCommandStatusTask = Task { [weak self, weak router] in
            while !Task.isCancelled {
                let capabilities = await client.capabilities
                let isReady = await client.isReady
                await MainActor.run {
                    guard let self, let router, self.editorCommandRouter === router else { return }
                    router.update(capabilities: capabilities, isServerReady: isReady)
                }
                guard isReady else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Edit propagation (highlight + didChange debouncer)

    private enum HistoryDirection {
        case back
        case forward
    }

    private var currentNavigationStore: EditorNavigationStore? {
        currentWorktreeId.map(appState.tabs.navigationStore(forWorktreeId:))
    }

    private func navigationSource(at position: LSPPosition) -> EditorNavigationTarget? {
        guard let worktreeID = currentWorktreeId,
              let root = currentOriginatingWorktreeRoot ?? currentRoot
        else { return nil }
        let uri: String
        if let absolutePath = currentExternalAbsolutePath {
            uri = URL(fileURLWithPath: absolutePath).lspURI
        } else {
            guard let relativePath = currentRelativePath else { return nil }
            uri = root.appendingPathComponent(relativePath).lspURI
        }
        return EditorNavigationTarget(
            document: EditorDocumentID(
                host: RemoteHostRegistry.shared.host(forPath: root.path),
                worktreeID: worktreeID,
                uri: uri
            ),
            position: position
        )
    }

    private func activateHistoryTarget(direction: HistoryDirection) {
        guard let worktreeID = currentWorktreeId,
              let root = currentOriginatingWorktreeRoot ?? currentRoot
        else { return }
        let store = appState.tabs.navigationStore(forWorktreeId: worktreeID)
        let target: EditorNavigationTarget?
        switch direction {
        case .back:
            target = store.goBack()
        case .forward:
            target = store.goForward()
        }
        guard let target else { return }
        if appState.tabs.openNavigationTarget(
            target,
            worktreeRoot: root,
            originatingRelativePath: currentExternalAbsolutePath == nil
                ? currentRelativePath
                : currentOriginatingRelativePath,
            language: currentLanguage
        ) {
            store.confirmHistoryActivation()
        } else {
            store.recordActivationFailure(for: target)
            textView?.showCommandStatus("Could not open navigation target")
        }
    }

    private func showProblem(from caretOffset: Int?, backwards: Bool) {
        guard let textView,
              let caretOffset,
              let position = TextEditCoordinates.lspPosition(utf16Offset: caretOffset, in: textView.string),
              let range = diagnosticsFeature.nextRange(after: position, backwards: backwards),
              let diagnostic = diagnosticsFeature.diagnostics(at: range.start).first(where: { $0.range == range }),
              let displayRange = DiagnosticsFeature.nsRange(for: range, in: textView.string)
        else {
            textView?.showCommandStatus("No visible problem at this location")
            return
        }

        textView.setSelectedRange(displayRange)
        scrollRangeToVisiblePreservingHorizontalOffset(displayRange, in: textView)
        hover?.showDiagnosticDetails(
            diagnostic,
            at: displayRange,
            openRelatedLocation: { [weak self] location in
                self?.openDiagnosticRelatedLocation(location, sourcePosition: diagnostic.range.start)
            },
            showQuickFixes: { [weak self] in
                self?.codeActionsFeature?.show(range: displayRange, diagnosticContext: [diagnostic])
            }
        )
    }

    private func openDiagnosticRelatedLocation(_ location: LSPLocation, sourcePosition: LSPPosition) {
        guard let worktreeID = currentWorktreeId,
              let root = currentOriginatingWorktreeRoot ?? currentRoot,
              let source = navigationSource(at: sourcePosition)
        else { return }
        let target = EditorNavigationTarget(
            document: EditorDocumentID(
                host: RemoteHostRegistry.shared.host(forPath: root.path),
                worktreeID: worktreeID,
                uri: location.uri
            ),
            position: location.range.start
        )
        if appState.tabs.openNavigationTarget(
            target,
            worktreeRoot: root,
            originatingRelativePath: currentExternalAbsolutePath == nil
                ? currentRelativePath
                : currentOriginatingRelativePath,
            language: currentLanguage
        ) {
            appState.tabs.navigationStore(forWorktreeId: worktreeID).recordJump(from: source, to: target)
        } else {
            appState.tabs.navigationStore(forWorktreeId: worktreeID).recordActivationFailure(for: target)
            textView?.showCommandStatus("Could not open related diagnostic location")
        }
    }

    private func currentLSPClient() -> LSPClient? {
        guard let language = currentLanguage else { return nil }
        if let binding = lspBinding {
            return binding.openedClient(language: language)
        }
        guard let absolutePath = currentExternalAbsolutePath,
              let originatingRoot = currentOriginatingWorktreeRoot else {
            return nil
        }
        return appState.lsp.openedClient(
            forFile: URL(fileURLWithPath: absolutePath),
            worktreeRoot: originatingRoot,
            language: language
        )
    }

    private func synchronizeLSPRequest(range: NSRange) async -> (LSPClient, EditorRequestContext)? {
        guard let binding = lspBinding, let language = currentLanguage else { return nil }
        return await binding.synchronizeRequest(range: range, language: language)
    }

    private func isLSPRequestCurrent(_ context: EditorRequestContext) -> Bool {
        lspBinding?.isCurrent(context) ?? false
    }

    private func scheduleEditPropagation(edit: EditorTextEdit?) {
        semanticFeature?.invalidate()
        if let worktreeID = currentWorktreeId {
            appState.tabs.navigationStore(forWorktreeId: worktreeID).markResultsStale()
        }
        didChangeTask?.cancel()
        hasPendingDidChange = true
        if let edit {
            pendingTextEdits.append(edit)
        } else {
            // Full reload (watcher-driven revert / discard-from-right-pane):
            // `loadFromDisk` replaced storage with a plain NSAttributedString,
            // wiping the font/color attributes. `runHighlight` only paints
            // syntax-colored spans, so without re-applying the base style the
            // text view falls back to the system proportional font for any
            // character outside a highlight capture.
            pendingTextEdits.removeAll()
            if let theme = currentTheme {
                applyBaseStyle(theme: theme)
            }
        }
        scheduleSemanticRefresh()
        didChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, let theme = self.currentTheme else { return }
            await MainActor.run {
                self.runHighlight(theme: theme)
                if let reveal = self.pendingReveal {
                    self.applyRevealIfNeeded(
                        tabId: reveal.tabId,
                        line: reveal.line,
                        endLine: reveal.endLine,
                        character: reveal.character,
                        revision: reveal.revision
                    )
                }
                self.hasPendingDidChange = false
                let edits = self.pendingTextEdits
                self.pendingTextEdits.removeAll()
                self.notifyLSPDidChange(edits: edits)
            }
        }
    }

    private func notifyLSPDidChange(edits: [EditorTextEdit]? = nil) {
        guard let payload = makeLSPDidChangePayload(edits: edits) else { return }
        Task { [weak self] in
            await self?.sendLSPDidChange(payload, awaitPullDiagnostics: true)
        }
    }

    private func flushPendingLSPDidChangeForCompletion() async {
        didChangeTask?.cancel()
        guard hasPendingDidChange else { return }

        hasPendingDidChange = false
        if let theme = currentTheme {
            runHighlight(theme: theme)
        }
        let edits = pendingTextEdits
        pendingTextEdits.removeAll()
        guard let payload = makeLSPDidChangePayload(edits: edits) else { return }
        await sendLSPDidChange(payload, awaitPullDiagnostics: false)
    }

    private func flushPendingLSPDidChangeForSignatureHelp() async {
        await flushPendingLSPDidChangeForCompletion()
    }

    private func makeLSPDidChangePayload(edits: [EditorTextEdit]? = nil) -> LSPDidChangePayload? {
        guard let buffer, let language = currentLanguage else { return nil }
        guard !buffer.isExternal || buffer.externalEditable else { return nil }
        let url = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath)
        return LSPDidChangePayload(
            worktreeRoot: buffer.worktreeRoot,
            relativePath: buffer.relativePath,
            fileURL: url,
            language: language,
            text: buffer.storage.string,
            edits: edits,
            theme: currentTheme
        )
    }

    private func sendLSPDidChange(_ payload: LSPDidChangePayload, awaitPullDiagnostics: Bool) async {
        await appState.lsp.didChange(
            worktreeRoot: payload.worktreeRoot,
            fileURL: payload.fileURL,
            languageId: payload.language,
            text: payload.text,
            edits: payload.edits
        )
        guard currentRoot == payload.worktreeRoot,
              currentRelativePath == payload.relativePath,
              currentLanguage == payload.language else { return }
        if let theme = payload.theme,
           let client = appState.lsp.client(forFile: payload.fileURL, worktreeRoot: payload.worktreeRoot, language: payload.language),
           await client.supportsPullDiagnostics {
            if awaitPullDiagnostics {
                await performPullDiagnostics(client: client, uri: payload.fileURL.lspURI, theme: theme)
            } else {
                Task { [weak self] in
                    await self?.performPullDiagnostics(client: client, uri: payload.fileURL.lspURI, theme: theme)
                }
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
        let ext = LanguageRegistry.highlighterExtension(forPath: buffer.relativePath)
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
            self.semanticLayer?.reapply(theme: editorTheme)
            if !cachedDiagnostics.isEmpty {
                self.diagnosticsFeature.apply(cachedDiagnostics, to: storage, theme: theme)
            }
            if b.initialLoadFinished, !self.reportedInitialHighlightReady, let tabId = stableTabId {
                self.reportedInitialHighlightReady = true
                self.onInitialHighlightReady?(tabId)
            }
        }
    }

    // MARK: - Semantic highlighting

    private func stopSemanticTokens() {
        semanticBindingID = UUID()
        semanticFeature?.stop()
        semanticFeature = nil
        semanticLayer?.clear()
        semanticLayer = nil
        semanticSubscription?.cancel()
        semanticSubscription = nil
        semanticClient = nil
    }

    private func configureSemanticTokens(theme: Theme) {
        guard let layoutManager, lspBinding != nil else { return }
        semanticLayer = EditorSemanticLayer(layoutManager: layoutManager, theme: EditorTheme(theme: theme), isCurrent: { [weak self] context in
            guard let self, let buffer = self.buffer,
                  buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI == context.document.uri,
                  !self.hasPendingDidChange else { return false }
            return self.isLSPRequestCurrent(context)
        })
        semanticFeature = SemanticTokensFeature(request: { [weak self] range in
            await self?.requestSemanticTokens(range: range)
        }, apply: { [weak self] spans, context in
            self?.semanticLayer?.replace(spans, context: context)
        }, clear: { [weak self] in self?.semanticLayer?.clear() })
        observeSemanticServer(bindingID: semanticBindingID)
        updateSemanticClient()
    }

    private func observeSemanticServer(bindingID: UUID) {
        withObservationTracking {
            _ = appState.lsp.stateTick
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.semanticBindingID == bindingID else { return }
                self.updateSemanticClient()
                self.observeSemanticServer(bindingID: bindingID)
            }
        }
    }

    private func updateSemanticClient() {
        let next: LSPClient?
        if let buffer, appState.lsp.documentStatus(forFile: buffer.worktreeRoot.appendingPathComponent(buffer.relativePath),
                                                  worktreeRoot: buffer.worktreeRoot) == .ready {
            next = currentLSPClient()
        } else { next = nil }
        guard next !== semanticClient else { return }
        semanticFeature?.stop()
        semanticSubscription?.cancel()
        semanticClient = next
        guard let next else { return }
        let bindingID = semanticBindingID
        semanticSubscription = Task { [weak self] in
            let capabilities = await next.capabilities
            guard let self, !Task.isCancelled, self.semanticBindingID == bindingID, self.semanticClient === next,
                  let provider = capabilities.semanticTokens, provider.supportsRange || provider.supportsFull else { return }
            self.semanticSupportsRange = provider.supportsRange
            let refreshes = await next.subscribeSemanticRefreshes()
            guard !Task.isCancelled else { return }
            self.scheduleSemanticRefresh()
            for await _ in refreshes {
                guard !Task.isCancelled, self.semanticBindingID == bindingID, self.semanticClient === next else { return }
                self.scheduleSemanticRefresh()
            }
            guard !Task.isCancelled, self.semanticBindingID == bindingID, self.semanticClient === next else { return }
            self.semanticFeature?.stop()
        }
    }

    private func scheduleSemanticRefresh(visibleRangeChanged: Bool = false) {
        guard semanticClient != nil, let textView, let storage = buffer?.storage,
              !visibleRangeChanged || semanticSupportsRange else { return }
        let range: NSRange
        if let layout = textView.layoutManager, let container = textView.textContainer {
            let rect = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
            let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard characters.location <= storage.length, characters.length <= storage.length - characters.location else { return }
            range = (storage.string as NSString).lineRange(for: characters)
        } else {
            range = NSRange(location: 0, length: storage.length)
        }
        semanticFeature?.refresh(range: range, debounce: .milliseconds(semanticSupportsRange ? 60 : 250))
    }

    private func requestSemanticTokens(range: NSRange) async -> SemanticTokensFeature.Result? {
        guard let buffer else { return nil }
        let generation = buffer.editGeneration
        let bindingID = semanticBindingID
        guard let (client, context) = await synchronizeLSPRequest(range: range),
              self.buffer === buffer, buffer.editGeneration == generation, semanticBindingID == bindingID,
              let provider = await client.capabilities.semanticTokens else { return nil }
        let snapshot = buffer.storage.string
        do {
            let data = try await client.semanticTokens(uri: context.document.uri, range: provider.supportsRange ? context.range : nil)
            let allowedRange = provider.supportsRange ? range : nil
            let spans = try await Task.detached(priority: .utility) {
                try SemanticTokensFeature.decode(data, legend: provider.legend.tokenTypes, text: snapshot,
                                                 modifiers: provider.legend.tokenModifiers, allowedRange: allowedRange)
            }.value
            guard !Task.isCancelled, self.buffer === buffer, buffer.editGeneration == generation,
                  semanticBindingID == bindingID, isLSPRequestCurrent(context), semanticClient === client else { return nil }
            return .init(spans: spans, context: context)
        } catch { return nil }
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
            let capabilities = await client.capabilities
            let isReady = await client.isReady
            guard let router = self.editorCommandRouter else { return }
            router.update(capabilities: capabilities, isServerReady: isReady)
            self.trackEditorCommandAvailability(for: client)
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

    /// Scrolls the text view so the line target is visible and
    /// places the selection there. De-duplicates by tab, line range, character,
    /// and revision so SwiftUI re-renders that re-pass the same hints don't keep stealing
    /// the user's scroll position. After applying, asks the TabsManager to
    /// clear the hint so it isn't replayed on relaunch.
    private func applyRevealIfNeeded(
        tabId: TabID,
        line: Int?,
        endLine: Int?,
        character: Int?,
        revision: Int?
    ) {
        guard let line, let character else {
            pendingReveal = nil
            lastAppliedReveal = nil
            return
        }
        let revision = revision ?? 0
        if let last = lastAppliedReveal,
           last.tabId == tabId,
           last.line == line,
           last.endLine == endLine,
           last.character == character,
           last.revision == revision {
            return
        }
        pendingReveal = (
            tabId: tabId,
            line: line,
            endLine: endLine,
            character: character,
            revision: revision
        )
        guard let textView, let buffer else { return }
        guard buffer.initialLoadFinished else { return }
        let nsString = buffer.storage.string as NSString
        let charIndex = characterIndex(atLine: line, in: nsString) ?? nsString.length
        let target = min(charIndex + character, nsString.length)
        let range = NSRange(location: target, length: 0)
        textView.setSelectedRange(range)
        scrollRangeToVisiblePreservingHorizontalOffset(range, in: textView)
        let endTarget = endLine.map { characterIndex(atLine: $0, in: nsString) ?? nsString.length }
        highlightRevealLines(from: target, through: endTarget, in: nsString, textView: textView)
        pendingReveal = nil
        lastAppliedReveal = (
            tabId: tabId,
            line: line,
            endLine: endLine,
            character: character,
            revision: revision
        )
        if let wid = currentWorktreeId {
            appState.tabs.consumeReveal(worktreeId: wid, tabId: tabId)
        }
    }

    private func characterIndex(atLine line: Int, in nsString: NSString) -> Int? {
        var charIndex = 0
        var currentLine = 0
        while currentLine < line {
            let range = nsString.range(
                of: "\n",
                options: [],
                range: NSRange(location: charIndex, length: nsString.length - charIndex)
            )
            guard range.location != NSNotFound else { return nil }
            charIndex = range.location + 1
            currentLine += 1
        }
        return charIndex
    }

    private func scrollRangeToVisiblePreservingHorizontalOffset(_ range: NSRange, in textView: CodeTextView) {
        guard let scrollView = textView.enclosingScrollView else {
            textView.scrollRangeToVisible(range)
            return
        }

        let clipView = scrollView.contentView
        let originalX = clipView.bounds.origin.x
        textView.scrollRangeToVisible(range)

        guard clipView.bounds.origin.x != originalX else { return }
        clipView.scroll(to: NSPoint(x: originalX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func highlightRevealLines(
        from target: Int,
        through endTarget: Int?,
        in nsString: NSString,
        textView: CodeTextView
    ) {
        guard nsString.length > 0,
              let layoutManager = textView.layoutManager else { return }
        clearRevealHighlight()

        let clampedTarget = min(max(0, target), max(0, nsString.length - 1))
        let clampedEnd = min(max(clampedTarget, endTarget ?? clampedTarget), max(0, nsString.length - 1))
        let lineRange = nsString.lineRange(for: NSRange(
            location: clampedTarget,
            length: clampedEnd - clampedTarget + 1
        ))
        guard lineRange.location != NSNotFound, lineRange.length > 0 else { return }

        let color = NSColor.systemYellow.withAlphaComponent(0.9)
        layoutManager.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, forCharacterRange: lineRange)
        layoutManager.addTemporaryAttribute(.underlineColor, value: color, forCharacterRange: lineRange)
        revealHighlightRange = lineRange
        revealHighlightTask = Task { [weak self, weak textView] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let textView, self.textView === textView else { return }
                self.clearRevealHighlight()
            }
        }
    }

    private func clearRevealHighlight() {
        revealHighlightTask?.cancel()
        revealHighlightTask = nil
        guard let range = revealHighlightRange,
              let textView,
              let layoutManager = textView.layoutManager else {
            revealHighlightRange = nil
            return
        }
        let textLength = (textView.string as NSString).length
        if range.location < textLength {
            let clampedRange = NSRange(
                location: range.location,
                length: min(range.length, textLength - range.location)
            )
            if clampedRange.length > 0 {
                layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: clampedRange)
                layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: clampedRange)
            }
        }
        revealHighlightRange = nil
    }
}
