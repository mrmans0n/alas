import AppKit
import Foundation

/// Owns the lifecycle of a `CodeTextView` for a single file: reads the
/// source from disk, applies tree-sitter highlights, opens the document
/// with the workspace LSP, and routes diagnostics back as squiggle
/// attributes on the text storage.
///
/// Hover and Cmd-click are wired up by Tasks 13/16 — this task only
/// covers load + highlight + diagnostics.
@MainActor
final class CodeEditorCoordinator {
    let appState: AppState
    private weak var textView: CodeTextView?

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

    init(appState: AppState) {
        self.appState = appState
    }

    func attach(textView: CodeTextView, worktreeId: String, worktreeRoot: URL, relativePath: String, tabId: TabID, revealLine: Int?, revealCharacter: Int?, theme: Theme) {
        self.textView = textView
        self.currentWorktreeId = worktreeId
        self.currentTheme = theme
        load(worktreeRoot: worktreeRoot, relativePath: relativePath, theme: theme)
        applyRevealIfNeeded(tabId: tabId, line: revealLine, character: revealCharacter)
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
    }

    func updateIfNeeded(worktreeId: String, worktreeRoot: URL, relativePath: String, tabId: TabID, revealLine: Int?, revealCharacter: Int?, theme: Theme) {
        let fileChanged = !(currentRoot == worktreeRoot && currentRelativePath == relativePath && currentWorktreeId == worktreeId)
        if fileChanged {
            // Capture the previous document before `load` overwrites
            // `currentRoot`, `currentRelativePath`, and `currentLanguage` —
            // otherwise the fire-and-forget close races and ends up sending
            // `didClose` for the *new* file or shutting down its
            // freshly-spawned client.
            let previous = takeCurrentDocument()
            currentWorktreeId = worktreeId
            load(worktreeRoot: worktreeRoot, relativePath: relativePath, theme: theme)
            if let previous { Task { await self.close(document: previous) } }
        } else if currentTheme != theme {
            // Theme change without file change — SwiftUI's previous
            // per-line `Text` editor recomputed colors from the environment
            // every render, but the AppKit text view holds onto the old
            // background, foreground, syntax colors, and diagnostic colors
            // until something forces a repaint. Re-run highlight + base
            // styling so a live theme switch takes effect immediately.
            repaint(theme: theme)
        }
        currentTheme = theme
        applyRevealIfNeeded(tabId: tabId, line: revealLine, character: revealCharacter)
    }

    func detach() {
        let previous = takeCurrentDocument()
        if let previous { Task { await self.close(document: previous) } }
        diagnosticsTask?.cancel()
        hover = nil
        definition = nil
    }

    // MARK: - Load + highlight

    private func load(worktreeRoot: URL, relativePath: String, theme: Theme) {
        guard let textView else { return }
        // Cancel any in-flight diagnostics subscription from the previous
        // file before we (potentially) early-return for a non-LSP extension —
        // otherwise the old server can keep delivering diagnostics that get
        // applied as squiggles on the reused text view.
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        let url = worktreeRoot.appendingPathComponent(relativePath)
        let editorTheme = EditorTheme(theme: theme)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: editorTheme.defaultFG
        ]

        // Stage 1 — immediate. Read the file synchronously and paint plain
        // text so the user sees content right away. Tree-sitter parsing and
        // LSP startup follow asynchronously below.
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "(unable to read file)"
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttrs))

        currentRoot = worktreeRoot
        currentRelativePath = relativePath

        let ext = (relativePath as NSString).pathExtension

        // Stage 2 — async tree-sitter highlight. Parsing a non-trivial file
        // can take 10s of ms; doing it on the main actor freezes the
        // first paint. Run it on a detached priority-userInitiated task and
        // apply the spans back on the main actor. Bail if the user
        // navigated to a different file before the parse finished.
        let stableRoot = worktreeRoot
        let stableRel = relativePath
        Task.detached(priority: .userInitiated) { [weak self] in
            let spans = TreeSitterHighlighter.highlight(source: text, fileExtension: ext)
            await MainActor.run {
                guard let self = self,
                      let storage = self.textView?.textStorage,
                      self.currentRoot == stableRoot,
                      self.currentRelativePath == stableRel else { return }
                let kwColor = editorTheme.attributes(for: .keyword)[.foregroundColor] as? NSColor
                let fgColor = editorTheme.attributes(for: .plain)[.foregroundColor] as? NSColor
                let firstFew = spans.prefix(5).map { "\($0.capture)@\($0.range)" }.joined(separator: ", ")
                print("[highlight-debug] spans=\(spans.count), keyword=\(kwColor?.colorSpace.localizedName ?? "nil")/\(kwColor?.description ?? "nil"), plain=\(fgColor?.description ?? "nil"), first5=\(firstFew)")
                storage.beginEditing()
                for span in spans {
                    storage.addAttributes(editorTheme.attributes(for: span.capture), range: span.range)
                }
                storage.endEditing()
                if let firstSpan = spans.first(where: { $0.capture == .keyword }) {
                    let attrs = storage.attributes(at: firstSpan.range.location, effectiveRange: nil)
                    print("[highlight-debug] readback first keyword: fg=\((attrs[.foregroundColor] as? NSColor)?.description ?? "nil")")
                }
            }
        }

        // Stage 3 — async LSP setup. Resolve the language via the registry
        // so user-defined servers (Settings → Code) are honored alongside
        // the built-in Swift entry.
        let manager = appState.lsp
        let language = manager.language(forFileExtension: ext)
        currentLanguage = language
        guard let language else { return }

        // Snapshot the file we're loading so the async block can detect a
        // mid-flight file switch — the manager's `openDocument` awaits
        // `initialize()` which may take seconds; without this guard we'd
        // subscribe diagnostics and refresh symbols for the *previous* URI,
        // and `subscribeDiagnostics` would cancel the new file's
        // diagnostics task on its way through.
        Task { [stableRoot, stableRel] in
            let client = await manager.openDocument(
                worktreeRoot: worktreeRoot,
                fileURL: url,
                languageId: language,
                text: text
            )
            guard self.currentRoot == stableRoot, self.currentRelativePath == stableRel else { return }
            await self.subscribeDiagnostics(for: client, uri: url.lspURI, theme: theme)
            await symbolsFeature.refresh(client: client, uri: url.lspURI)
        }
    }

    private func subscribeDiagnostics(for client: LSPClient?, uri: String, theme: Theme) async {
        guard let client else { return }
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            for await batch in await client.subscribeDiagnostics() {
                if batch.uri != uri { continue }
                await MainActor.run {
                    self?.applyDiagnostics(batch.diagnostics, theme: theme)
                }
            }
        }
    }

    private func applyDiagnostics(_ diagnostics: [LSPDiagnostic], theme: Theme) {
        guard let storage = textView?.textStorage else { return }
        diagnosticsFeature.apply(diagnostics, to: storage, theme: theme)
    }

    /// Re-applies background, base text attributes, and tree-sitter
    /// highlights to the existing storage without re-reading the file or
    /// touching LSP state. Called when the theme changes mid-session.
    private func repaint(theme: Theme) {
        guard let textView, let storage = textView.textStorage,
              let root = currentRoot, let rel = currentRelativePath else { return }
        let editorTheme = EditorTheme(theme: theme)
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: editorTheme.defaultFG
        ]
        let text = storage.string
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttrs, range: fullRange)

        let ext = (rel as NSString).pathExtension
        let stableRoot = root
        let stableRel = rel
        Task.detached(priority: .userInitiated) { [weak self] in
            let spans = TreeSitterHighlighter.highlight(source: text, fileExtension: ext)
            await MainActor.run {
                guard let self = self,
                      let s = self.textView?.textStorage,
                      self.currentRoot == stableRoot,
                      self.currentRelativePath == stableRel else { return }
                s.beginEditing()
                for span in spans {
                    s.addAttributes(editorTheme.attributes(for: span.capture), range: span.range)
                }
                s.endEditing()
            }
        }
    }

    private struct OpenDocument {
        let root: URL
        let relativePath: String
        let language: String
    }

    /// Snapshots the currently-open document and clears the coordinator's
    /// `current*` fields so the caller can safely overwrite them with the
    /// next file's state. The returned snapshot is later passed to
    /// `close(document:)` which sends `didClose` against the captured URI.
    private func takeCurrentDocument() -> OpenDocument? {
        guard let root = currentRoot, let rel = currentRelativePath, let lang = currentLanguage else { return nil }
        currentRoot = nil
        currentRelativePath = nil
        currentLanguage = nil
        return OpenDocument(root: root, relativePath: rel, language: lang)
    }

    private func close(document: OpenDocument) async {
        let url = document.root.appendingPathComponent(document.relativePath)
        await appState.lsp.closeDocument(worktreeRoot: document.root, fileURL: url, languageId: document.language)
    }

    // MARK: - Reveal (go-to-definition scroll target)

    /// Scrolls the text view so the (line, character) target is visible and
    /// places the selection there. De-duplicates by `(tabId, line, character)`
    /// so SwiftUI re-renders that re-pass the same hints don't keep stealing
    /// the user's scroll position. After applying, asks the TabsManager to
    /// clear the hint so it isn't replayed on relaunch.
    private func applyRevealIfNeeded(tabId: TabID, line: Int?, character: Int?) {
        guard let line, let character else { return }
        if let last = lastAppliedReveal,
           last.tabId == tabId, last.line == line, last.character == character {
            return
        }
        guard let textView, let storage = textView.textStorage else { return }
        let nsString = storage.string as NSString
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
