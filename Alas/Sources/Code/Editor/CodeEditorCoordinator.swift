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

    private var currentRoot: URL?
    private var currentRelativePath: String?
    private var currentLanguage: String?
    private var diagnosticsTask: Task<Void, Never>?
    private let diagnosticsFeature = DiagnosticsFeature()
    let symbolsFeature = SymbolsFeature()
    private var hover: HoverFeature?

    init(appState: AppState) {
        self.appState = appState
    }

    func attach(textView: CodeTextView, worktreeRoot: URL, relativePath: String, theme: Theme) {
        self.textView = textView
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
    }

    func updateIfNeeded(worktreeRoot: URL, relativePath: String, theme: Theme) {
        if currentRoot == worktreeRoot && currentRelativePath == relativePath { return }
        Task { await closeCurrent() }
        load(worktreeRoot: worktreeRoot, relativePath: relativePath, theme: theme)
    }

    func detach() {
        Task { await closeCurrent() }
        diagnosticsTask?.cancel()
        hover = nil
    }

    // MARK: - Load + highlight

    private func load(worktreeRoot: URL, relativePath: String, theme: Theme) {
        guard let textView else { return }
        let url = worktreeRoot.appendingPathComponent(relativePath)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "(unable to read file)"
        let editorTheme = EditorTheme(theme: theme)
        let attr = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: editorTheme.defaultFG
            ]
        )
        let ext = (relativePath as NSString).pathExtension
        for span in TreeSitterHighlighter.highlight(source: text, fileExtension: ext) {
            attr.addAttributes(editorTheme.attributes(for: span.capture), range: span.range)
        }
        textView.textStorage?.setAttributedString(attr)

        currentRoot = worktreeRoot
        currentRelativePath = relativePath

        // Spin up LSP for the file's language
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
