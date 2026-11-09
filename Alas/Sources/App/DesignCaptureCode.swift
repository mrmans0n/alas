#if DEBUG
import AppKit
import Markdown
import SwiftUI

/// Design-capture targets for the code editor: its find bar, LSP popups,
/// banners, Markdown preview and Mermaid viewer. Each one drives the real
/// view with scripted data on top of the file `scripts/design/capture.sh`
/// opened; no language server is started. Debug builds only.
@MainActor
enum DesignCaptureCode {
    static let targets: Set<String> = [
        "editor-find", "editor-lsp-status", "editor-completion", "editor-hover",
        "editor-definitions", "editor-code-actions", "editor-rename", "editor-edit-preview",
        "editor-banners", "editor-banners-blocked", "markdown", "mermaid-viewer",
    ]

    private static let hover = HoverWindowController()
    private static let completion = CompletionWindowController()
    private static let editPresentation = CodeActionEditPresentation()
    private static var popover: NSPopover?
    private static var galleryPanel: NSPanel?

    static func open(_ target: String, state: AppState) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty || state.selectedWorktreeId == nil {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            switch target {
            case "markdown":
                state.config.markdown.defaultViewMode = .preview
                openRelative("docs/architecture.md", state: state)
            case "mermaid-viewer": await showMermaidViewer(state: state)
            case "editor-banners": await showBanners(state: state, blocked: false)
            case "editor-banners-blocked": await showBanners(state: state, blocked: true)
            default: await showEditorOverlay(target, state: state)
            }
        }
    }

    // MARK: - Snapshots

    /// Writes every visible window other than the main one to `directory` as
    /// `<n>.png` and describes them in `windows.json`, with frames in screen
    /// points. screencapture grabs a child window's parent instead of the
    /// child, so popups, hover cards and sheets are drawn from inside the app.
    static func snapshotWindows(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let main = mainWindow() else { return }
        func rect(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
        var entries: [[String: Any]] = []
        let others = NSApp.windows.filter { $0 !== main && $0.isVisible && $0.frame.width >= 40 && $0.frame.height >= 24 }
            .sorted { ($0.level.rawValue, $0.windowNumber) < ($1.level.rawValue, $1.windowNumber) }
        for (index, window) in others.enumerated() {
            // The content view, not the frame around it: a popover's frame
            // view comes out with a garbled border when drawn off screen.
            guard let view = window.contentViewController?.view ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let name = "\(index + 1).png"
            try? png.write(to: dir.appendingPathComponent(name))
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            entries.append(["file": name, "frame": rect(frame), "sheet": window.isSheet])
        }
        let manifest: [String: Any] = ["main": rect(main.frame), "windows": entries]
        if let data = try? JSONSerialization.data(withJSONObject: manifest) {
            try? data.write(to: dir.appendingPathComponent("windows.json"), options: .atomic)
        }
    }

    // MARK: - Opening files

    private static func openRelative(_ path: String, state: AppState) {
        guard let id = state.selectedWorktreeId else { return }
        state.openFile(relativePath: path, worktreeId: id)
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0.parent == nil && $0.contentView != nil && $0.frame.width > 600 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func codeTextView() -> CodeTextView? {
        guard let root = mainWindow()?.contentView else { return nil }
        func search(_ view: NSView) -> CodeTextView? {
            if let found = view as? CodeTextView { return found }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return search(root)
    }

    private static func waitForEditor() async -> CodeTextView? {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let view = codeTextView(), view.window != nil, view.string.contains("subtotal") { return view }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private static func range(of word: String, in view: NSTextView, occurrence: Int = 0) -> NSRange {
        let text = view.string as NSString
        var found = NSRange(location: 0, length: 0)
        var searchRange = NSRange(location: 0, length: text.length)
        for _ in 0...occurrence {
            found = text.range(of: word, options: [], range: searchRange)
            guard found.location != NSNotFound else { return found }
            searchRange = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        return found
    }

    // MARK: - Overlays on the opened editor

    private static func showEditorOverlay(_ target: String, state: AppState) async {
        guard let textView = await waitForEditor() else { return }
        let theme = state.themeStore.current
        var word = range(of: "tax(on", in: textView)
        word.length = 3
        let anchor = textView.symbolAnchorRect(for: word) ?? .zero
        switch target {
        case "editor-find":
            textView.setSelectedRange(range(of: "Decimal", in: textView))
            NotificationCenter.default.post(name: .alasShowFindReplace, object: EditorFindRequest.showFind)
        case "editor-hover":
            let markdown = """
            ```swift
            func tax(on amount: Decimal, for customer: String) -> Decimal
            ```

            ---

            Tax owed on `amount` for one customer. Rates come from the rule set for the customer's region, \
            and reverse-charge customers always return zero.

            - Parameters:
              - amount: the taxable subtotal
              - customer: the customer name as printed on the invoice
            """
            let result = render(markdown, state: state)
            hover.show(
                result: result, size: HoverFeatureTesting.computePreferredSize(for: result), theme: theme,
                anchor: anchor, in: textView, onWillPresentMermaidViewer: {}
            )
        case "editor-completion":
            let rows: [CompletionPopupRow] = [
                ("tax", "(on: Decimal, for: String) -> Decimal", 2, CompletionCandidateSource.lsp),
                ("taxExempt", "Bool", 5, .lsp),
                ("taxRegion", "String", 5, .lsp),
                ("taxRate(for:)", "(String) -> Decimal", 2, .lsp),
                ("target", "String", 6, .buffer),
            ].map { CompletionPopupRow(id: UUID(), label: $0.0, detail: $0.1, kind: $0.2, source: $0.3) }
            let documentation = render(
                "**tax(on:for:)**\n\nTax owed on an amount for one customer.\n\n```swift\nrules.tax(on: subtotal, for: customer)\n```",
                state: state
            )
            completion.show(
                rows: rows, selection: 0, documentation: documentation, theme: theme,
                anchor: anchor, in: textView, onChoose: { _ in }
            )
        case "editor-definitions":
            let entries = [
                DefinitionPickerEntry(displayPath: "TaxRules.swift:14", snippet: "func tax(on amount: Decimal, for customer: String) -> Decimal {"),
                DefinitionPickerEntry(displayPath: "TaxRules+Regions.swift:42", snippet: "extension TaxRules { func tax(on amount: Decimal, region: Region) -> Decimal {"),
                DefinitionPickerEntry(displayPath: "InvoiceTests.swift:31", snippet: "let tax = rules.tax(on: 100, for: \"Acme\")"),
            ]
            present(
                DefinitionPicker(entries: entries, onChoose: { _ in }),
                size: NSSize(width: 380, height: max(60, min(320, 24 + entries.count * 36))),
                behavior: .applicationDefined, anchor: anchor, in: textView
            )
        case "editor-rename":
            let model = RenameNameModel(name: "subtotal")
            present(
                RenameNameView(model: model, cancel: {}, submit: {}),
                size: nil, behavior: .applicationDefined,
                anchor: textView.symbolAnchorRect(for: range(of: "subtotal", in: textView)) ?? anchor, in: textView
            )
        case "editor-code-actions":
            let actions = [
                codeAction("Add missing 'import Foundation'", kind: "quickfix", preferred: true),
                codeAction("Extract to local variable", kind: "refactor.extract"),
                codeAction("Convert 'reduce' to a 'for' loop", kind: "refactor.rewrite"),
                codeAction("Wrap in 'Decimal(string:)'", kind: "quickfix", disabled: "Requires a string literal"),
            ]
            let model = CodeActionPickerModel(actions: actions)
            present(
                CodeActionPicker(model: model, select: { _ in }, organizeImports: {}, cancel: {}),
                size: nil, behavior: .applicationDefined,
                anchor: textView.symbolAnchorRect(for: range(of: "subtotal", in: textView)) ?? anchor, in: textView
            )
        case "editor-edit-preview":
            guard let window = textView.window, let plan = editPlan(state: state) else { return }
            let model = WorkspaceEditPreviewModel(plan: plan) { _ in .applied(UUID()) }
            _ = await editPresentation.present(model, parent: window, forcePreview: true)
        case "editor-lsp-status":
            showStatusGallery(state: state, over: textView)
        default:
            break
        }
    }

    private static func render(_ markdown: String, state: AppState) -> MarkdownRenderResult {
        MarkdownRenderer().render(
            document: Document(parsing: markdown),
            theme: state.themeStore.current,
            monospacedFontFamily: state.config.code.fontFamily,
            monospacedFontSize: state.config.code.fontSize,
            baseDirectory: URL(fileURLWithPath: "/"),
            mermaidProfile: .compact
        )
    }

    private static func present<Content: View>(
        _ content: Content, size: NSSize?, behavior: NSPopover.Behavior, anchor: NSRect, in view: NSView
    ) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = behavior
        if let size { popover.contentSize = size }
        popover.contentViewController = NSHostingController(rootView: content)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        Self.popover = popover
    }

    private static func codeAction(_ title: String, kind: String, preferred: Bool = false, disabled: String? = nil) -> LSPCodeAction {
        var wire: [String: LSPJSONValue] = ["title": .string(title), "kind": .string(kind)]
        if preferred { wire["isPreferred"] = .bool(true) }
        if let disabled { wire["disabled"] = .object(["reason": .string(disabled)]) }
        // The wire value always has a title, so decoding cannot fail.
        return try! LSPCodeAction(wireValue: .object(wire))
    }

    private static func editPlan(state: AppState) -> WorkspaceEditPlan? {
        guard let id = state.selectedWorktreeId else { return nil }
        let invoice = EditorDocumentID(host: nil, worktreeID: id, uri: "file:///demo/src/billing/Invoice.swift")
        let rules = EditorDocumentID(host: nil, worktreeID: id, uri: "file:///demo/src/billing/TaxRules.swift")
        let invoiceText = "var subtotal: Decimal {\n    lines.reduce(0) { $0 + Decimal($1.quantity) * $1.unitPrice }\n}\n\nfunc total(applying rules: TaxRules) -> Decimal {\n    subtotal + rules.tax(on: subtotal, for: customer)\n}\n"
        let rulesText = "struct TaxRules {\n    func tax(on amount: Decimal, for customer: String) -> Decimal {\n        amount * rate(for: customer)\n    }\n}\n"
        func edit(_ line: Int, _ from: Int, _ to: Int, _ text: String) -> LSPTextEdit {
            LSPTextEdit(range: .init(start: .init(line: line, character: from), end: .init(line: line, character: to)), newText: text)
        }
        let edits: [LSPDocumentChange] = [
            .textDocument(document: .init(uri: invoice.uri, version: nil), edits: [
                edit(0, 4, 12, "netTotal"), edit(5, 4, 12, "netTotal"), edit(5, 29, 37, "netTotal"),
            ]),
            .textDocument(document: .init(uri: rules.uri, version: nil), edits: [edit(1, 9, 12, "taxOwed")]),
        ]
        let context = EditorRequestContext(
            document: invoice, version: 1, serverGeneration: UUID(),
            range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0))
        )
        return try? WorkspaceEditPlanner.plan(
            edit: .init(documentChanges: edits), context: context,
            snapshots: [
                invoice: .init(document: invoice, content: Data(invoiceText.utf8), bufferVersion: 1, isOpen: true),
                rules: .init(document: rules, content: Data(rulesText.utf8)),
            ]
        )
    }

    // MARK: - LSP status

    /// Pills and popover bodies for each server state, in a panel over the editor.
    private static func showStatusGallery(state: AppState, over textView: NSView) {
        let ready = LSPServerStatus(language: "swift", command: "sourcekit-lsp", root: "/demo/lantern", remoteHost: nil)
        ready.markInitialized()
        let indexing = LSPServerStatus(language: "typescript", command: "typescript-language-server", root: "/demo/lantern/web", remoteHost: nil)
        indexing.markInitialized()
        indexing.applyProgress([
            .init(token: "index", title: "Indexing project", message: "src/web/routes.ts", percentage: 62),
            .init(token: "types", title: "Loading type definitions", message: nil, percentage: nil),
        ])
        let crashed = LSPServerStatus(language: "python", command: "pyright-langserver", root: "/demo/lantern/tools", remoteHost: nil)
        crashed.recordInitializeFailure("Could not find a Python environment.")
        let chips: [LSPServerChipModel] = [
            .serving(ready), .serving(indexing), .serving(crashed),
            .unavailable(language: "go", reason: .notInstalled),
        ]
        let content = StatusGallery(chips: chips, appState: state)
            .environment(\.theme, state.themeStore.current)
            .environment(\.designScale, .resolved(for: state.config.density))
        show(panel: content, size: NSSize(width: 700, height: 700), over: textView)
    }

    private struct StatusGallery: View {
        let chips: [LSPServerChipModel]
        let appState: AppState
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text("Toolbar").font(.system(size: 11)).foregroundColor(theme.color("fg-muted"))
                    LSPServerChipStrip(chips: Array(chips.prefix(3)), appState: appState)
                    LSPServerChipStrip(chips: chips + chips, appState: appState)
                    EditorLSPStatusBadge(
                        status: .ready(language: "swift", command: "sourcekit-lsp"), serverStatus: nil,
                        availableLanguages: { [] }, openFilesUsingLanguage: 2,
                        onRestart: {}, onOverride: { _ in }, onOpenSettings: {}, onInstall: {}
                    )
                }
                LazyVGrid(columns: [GridItem(.fixed(300), spacing: 12, alignment: .topLeading), GridItem(.fixed(300), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                    ForEach(chips) { chip in
                        LSPServerChipPopoverBody(model: chip, appState: appState, dismiss: {})
                            .padding(10).frame(width: 300, alignment: .topLeading)
                            .background(theme.color("bg-2"))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                Text("Language override").font(.system(size: 11)).foregroundColor(theme.color("fg-muted"))
                EditorLSPStatusOverridePicker(
                    availableLanguages: [("swift", "Swift"), ("typescript", "TypeScript"), ("python", "Python"), ("rust", "Rust")],
                    onPick: { _ in }, onOpenSettings: {}
                )
                .padding(10).frame(width: 280, height: 150)
                .background(theme.color("bg-2"))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.color("bg-1"))
        }
    }

    // MARK: - Banners

    private static func showBanners(state: AppState, blocked: Bool) async {
        guard let id = state.selectedWorktreeId else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alas-design-capture-lsp", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = blocked ? "gleam" : "ex"
        let file = directory.appendingPathComponent("billing.\(ext)")
        let original = "defmodule Billing do\n  def total(lines), do: Enum.sum(lines)\nend\n"
        try? original.write(to: file, atomically: true, encoding: .utf8)

        var servers = state.config.code.languageServers.filter { !$0.extensions.contains(ext) }
        if blocked {
            let binary = directory.appendingPathComponent("gleam-language-server")
            try? "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            let value = "0081;5f3e0000;Safari;"
            _ = value.withCString { setxattr(binary.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
            servers.append(LanguageServerConfig(
                language: "gleam", extensions: ["gleam"], command: binary.path, args: [], env: [:],
                rootMarkers: ["gleam.toml"], enabled: true
            ))
        } else {
            servers.append(LanguageServerConfig(
                language: "elixir", extensions: ["ex"], command: "elixir-ls-alas-design-demo", args: [], env: [:],
                rootMarkers: ["mix.exs"], enabled: true
            ))
            state.config.code.userDefinedRecipes["elixir"] = [
                InstallRecipe(installer: .brew, package: "elixir-ls"),
                InstallRecipe(installer: .npm, package: "elixir-ls"),
            ]
        }
        state.config.code.languageServers = servers
        state.config.code.dismissedInstallNudges.removeAll()

        _ = state.tabs.openExternalEditor(
            worktreeId: id, absoluteURL: file, revealLine: nil, revealCharacter: nil, editable: true
        )
        guard !blocked else { return }
        // A dirty buffer plus a different file on disk raises the conflict banner.
        let deadline = Date().addingTimeInterval(20)
        var textView: CodeTextView?
        while Date() < deadline, textView == nil {
            try? await Task.sleep(for: .milliseconds(200))
            if let view = codeTextView(), view.string.contains("defmodule") { textView = view }
        }
        guard let textView else { return }
        textView.insertText("# Reviewed by finance\n", replacementRange: NSRange(location: 0, length: 0))
        try? await Task.sleep(for: .milliseconds(800))
        try? (original + "\ndefp round(value), do: Float.round(value, 2)\n").write(to: file, atomically: false, encoding: .utf8)
    }

    // MARK: - Mermaid

    private static func showMermaidViewer(state: AppState) async {
        state.config.markdown.defaultViewMode = .preview
        openRelative("docs/architecture.md", state: state)
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else { return }
        let source = """
        flowchart LR
            Client[Client] --> API[Billing API]
            API --> Ledger[(Ledger)]
            API --> Tax{Tax rules}
            Tax -->|EU| VAT[VAT service]
            Tax -->|US| Sales[Sales tax]
            Ledger --> Export[CSV export]
        """
        MermaidDiagramViewerController.shared.show(source: source, theme: state.themeStore.current, from: window)
    }

    // MARK: - Panels

    /// A borderless child window over the editor area, for galleries of views
    /// that are normally reached by clicking.
    private static func show<Content: View>(panel content: Content, size: NSSize, over view: NSView) {
        guard let window = view.window else { return }
        galleryPanel?.parent?.removeChildWindow(galleryPanel!)
        galleryPanel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: content)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        panel.setFrame(NSRect(x: frame.minX + 24, y: frame.maxY - size.height - 24, width: size.width, height: size.height), display: true)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        galleryPanel = panel
    }
}
#endif
