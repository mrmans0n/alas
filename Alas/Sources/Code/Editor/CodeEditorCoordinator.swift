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
    private var diagnosticsTask: Task<Void, Never>?
    private let diagnosticsFeature = DiagnosticsFeature()
    let symbolsFeature = SymbolsFeature()
    private var hover: HoverFeature?
    private var definition: DefinitionFeature?

    init(appState: AppState) {
        self.appState = appState
    }

    func attach(textView: CodeTextView, worktreeId: String, worktreeRoot: URL, relativePath: String, theme: Theme) {
        self.textView = textView
        self.currentWorktreeId = worktreeId
        load(worktreeRoot: worktreeRoot, relativePath: relativePath, theme: theme)
        hover = HoverFeature(
            textView: textView,
            getClient: { [weak self] in
                guard let self, let root = self.currentRoot, let lang = self.currentLanguage else { return nil }
                return self.appState.lsp.client(forWorktree: root, language: lang)
            },
            getURI: { [weak self] in
                guard let self, let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return "file://" + root.appendingPathComponent(rel).path
            }
        )
        definition = DefinitionFeature(
            textView: textView,
            getClient: { [weak self] in
                guard let self, let root = self.currentRoot, let lang = self.currentLanguage else { return nil }
                return self.appState.lsp.client(forWorktree: root, language: lang)
            },
            getURI: { [weak self] in
                guard let self, let root = self.currentRoot, let rel = self.currentRelativePath else { return nil }
                return "file://" + root.appendingPathComponent(rel).path
            },
            openTarget: { [weak self] url, line, character in
                guard let self, let root = self.currentRoot, let wid = self.currentWorktreeId else { return }
                // Compute path relative to the current worktree root. If the
                // target lives outside this worktree we still route to the
                // same TabsManager bucket — cross-worktree definitions are a
                // v1.5 concern.
                let abs = url.path
                let prefix = root.path + "/"
                let rel = abs.hasPrefix(prefix) ? String(abs.dropFirst(prefix.count)) : abs
                self.appState.tabs.openEditor(
                    worktreeId: wid,
                    relativePath: rel,
                    revealLine: line,
                    revealCharacter: character
                )
            }
        )
    }

    func updateIfNeeded(worktreeId: String, worktreeRoot: URL, relativePath: String, theme: Theme) {
        if currentRoot == worktreeRoot && currentRelativePath == relativePath && currentWorktreeId == worktreeId { return }
        Task { await closeCurrent() }
        currentWorktreeId = worktreeId
        load(worktreeRoot: worktreeRoot, relativePath: relativePath, theme: theme)
    }

    func detach() {
        Task { await closeCurrent() }
        diagnosticsTask?.cancel()
        hover = nil
        definition = nil
    }

    // MARK: - Load + highlight

    private func load(worktreeRoot: URL, relativePath: String, theme: Theme) {
        guard let textView else { return }
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
                for span in spans {
                    storage.addAttributes(editorTheme.attributes(for: span.capture), range: span.range)
                }
            }
        }

        // Stage 3 — async LSP setup.
        let registry = appState.lsp
        let language: String?
        switch ext.lowercased() {
        case "swift": language = "swift"
        default:      language = nil
        }
        currentLanguage = language
        guard let language else { return }

        Task {
            let client = await registry.openDocument(
                worktreeRoot: worktreeRoot,
                fileURL: url,
                languageId: language,
                text: text
            )
            await self.subscribeDiagnostics(for: client, uri: "file://" + url.path, theme: theme)
            await symbolsFeature.refresh(client: client, uri: "file://" + url.path)
        }
    }

    private func subscribeDiagnostics(for client: LSPClient?, uri: String, theme: Theme) async {
        guard let client else { return }
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            for await batch in await client.diagnosticsStream {
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

    private func closeCurrent() async {
        guard let root = currentRoot, let rel = currentRelativePath, let lang = currentLanguage else { return }
        let url = root.appendingPathComponent(rel)
        await appState.lsp.closeDocument(worktreeRoot: root, fileURL: url, languageId: lang)
        currentRoot = nil
        currentRelativePath = nil
        currentLanguage = nil
    }
}
