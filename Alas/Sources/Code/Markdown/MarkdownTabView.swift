import SwiftUI
import AppKit

struct MarkdownTabView: View {
    let worktreePath: URL
    let worktreeId: String
    let tabId: TabID
    let relativePath: String
    let externalAbsolutePath: String?
    var externalEditable: Bool = false
    let originatingRelativePath: String?
    let revealLine: Int?
    var revealEndLine: Int? = nil
    let revealCharacter: Int?
    let revealRevision: Int?
    @Bindable var appState: AppState
    let onRevealInFiles: (String) -> Void
    @Environment(\.theme) var theme

    @State private var renderCache = MarkdownPreviewCache<MarkdownRenderResult>()
    @State private var debounceTask: Task<Void, Never>?
    @State private var mermaidPreviewSource = ""

    // Editor/preview divider drag: transient during the drag, committed to
    // the tab store (and disk) once on drag end.
    @State private var transientEditorWidth: CGFloat?
    @State private var editorDragStartWidth: CGFloat?

    private var renderIdentity: MarkdownRenderIdentity {
        MarkdownRenderIdentity(
            worktreePath: worktreePath.standardizedFileURL.path,
            tabId: tabId,
            relativePath: relativePath,
            externalAbsolutePath: externalAbsolutePath
        )
    }

    private var resolvedMode: MarkdownViewMode {
        appState.tabs.editorTabState(worktreeId: worktreeId, tabId: tabId)?.markdownViewMode
            ?? appState.config.markdown.defaultViewMode
    }

    private var splitFraction: Double {
        appState.tabs.editorTabState(worktreeId: worktreeId, tabId: tabId)?.markdownSplitFraction ?? 0.5
    }

    private var isStandaloneMermaid: Bool {
        MarkdownFileType.isStandaloneMermaid(
            relativePath: externalAbsolutePath ?? relativePath
        )
    }

    private var buffer: EditorBuffer {
        if let abs = externalAbsolutePath {
            return appState.tabs.externalBuffer(
                worktreeId: worktreeId,
                tabId: tabId,
                absoluteURL: URL(fileURLWithPath: abs),
                worktreeRoot: worktreePath,
                originatingFileURL: originatingRelativePath.map { worktreePath.appendingPathComponent($0) },
                language: "markdown",
                editable: externalEditable
            )
        } else {
            return appState.tabs.buffer(
                worktreeId: worktreeId,
                tabId: tabId,
                worktreeRoot: worktreePath,
                relativePath: relativePath
            )
        }
    }

    private var baseDirectory: URL {
        if let abs = externalAbsolutePath {
            return URL(fileURLWithPath: abs).deletingLastPathComponent()
        }
        return worktreePath.appendingPathComponent(relativePath).deletingLastPathComponent()
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                if externalAbsolutePath == nil {
                    EditorConflictBanner(buffer: buffer)
                }
                bodyView
            }
            .background(theme.color("bg-1"))

            // Hidden zero-size shortcut button. The button only exists when
            // this view is in the hierarchy, which only happens for markdown
            // tabs that are the active tab — so the shortcut is implicitly
            // scoped to markdown tabs without explicit isEnabled gating.
            Button(action: cycleMode) { Color.clear }
                .frame(width: 0, height: 0)
                .keyboardShortcut(appState.shortcut(for: .toggleMarkdownPreview))
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear { scheduleRender(immediate: true) }
        .onChange(of: renderIdentity) { _, _ in
            invalidateRender()
            scheduleRender(immediate: true)
        }
        .onChange(of: buffer.editGeneration) { _, _ in scheduleRender(immediate: false) }
        // Re-render when the live theme or code font settings change — the
        // renderer captures those when invoked, so a stale `renderResult`
        // would otherwise keep the previous colors/fonts until the next edit.
        // Watching `theme` directly catches every input that produces a new
        // theme value (themeId, accent, matchSystemTheme, system appearance),
        // not just config.themeId.
        .onChange(of: theme) { _, _ in scheduleRender(immediate: true) }
        .onChange(of: appState.config.code.fontFamily) { _, _ in scheduleRender(immediate: true) }
        .onChange(of: appState.config.code.fontSize) { _, _ in scheduleRender(immediate: true) }
        // Render kicks in when the user switches out of editor-only mode —
        // editor mode skips rendering to avoid parsing+rendering the whole
        // buffer on every keystroke when the preview isn't visible.
        .onChange(of: resolvedMode) { _, _ in scheduleRender(immediate: true) }
    }

    private func cycleMode() {
        appState.tabs.setMarkdownViewMode(
            worktreeId: worktreeId,
            tabId: tabId,
            mode: resolvedMode.next()
        )
    }

    @ViewBuilder
    private var bodyView: some View {
        switch resolvedMode {
        case .editor:
            codeEditor
        case .preview:
            preview
        case .split:
            GeometryReader { proxy in
                let leftWidth: CGFloat = transientEditorWidth ?? max(120, proxy.size.width * splitFraction)
                HStack(spacing: 0) {
                    codeEditor.frame(width: leftWidth)
                    DragHandle(
                        axis: .horizontal,
                        onDragChanged: { translation in
                            let total = proxy.size.width
                            guard total > 240 else { return }
                            let start: CGFloat = editorDragStartWidth ?? leftWidth
                            editorDragStartWidth = start
                            transientEditorWidth = CGFloat(PaneDragMath.resolvedWidth(
                                startWidth: Double(start),
                                translation: Double(translation),
                                min: max(120, Double(total) * 0.1),
                                max: min(Double(total) - 120, Double(total) * 0.9)
                            ))
                        },
                        onDragEnded: {
                            let total = proxy.size.width
                            if let width = transientEditorWidth, total > 0 {
                                appState.tabs.setMarkdownSplitFraction(
                                    worktreeId: worktreeId, tabId: tabId,
                                    fraction: Double(width / total)
                                )
                            }
                            transientEditorWidth = nil
                            editorDragStartWidth = nil
                        }
                    )
                    preview
                }
            }
        }
    }

    private var codeEditor: some View {
        CodeEditorView(
            worktreeId: worktreeId,
            worktreeRoot: worktreePath,
            relativePath: relativePath,
            tabId: tabId,
            revealLine: revealLine,
            revealEndLine: revealEndLine,
            revealCharacter: revealCharacter,
            revealRevision: revealRevision,
            appState: appState,
            externalAbsolutePath: externalAbsolutePath,
            externalEditable: externalEditable,
            originatingRelativePath: originatingRelativePath,
            fontFamily: appState.config.code.fontFamily,
            fontSize: appState.config.code.fontSize,
            showLineNumbers: appState.config.code.showLineNumbers
        )
    }

    @ViewBuilder
    private var preview: some View {
        if isStandaloneMermaid {
            MermaidDiagramBlockView(source: mermaidPreviewSource, profile: .full)
        } else if let renderResult = renderCache.value(for: renderIdentity) {
            MarkdownPreviewView(result: renderResult, onLinkClick: handleLinkClick)
        } else {
            Color.clear.onAppear { scheduleRender(immediate: true) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            breadcrumbText
            Spacer()
            Seg(value: Binding(
                get: { resolvedMode },
                set: { newMode in
                    appState.tabs.setMarkdownViewMode(worktreeId: worktreeId, tabId: tabId, mode: newMode)
                }
            ), systemImageOptions: [
                (MarkdownViewMode.editor, "pencil"),
                (MarkdownViewMode.split, "rectangle.split.2x1"),
                (MarkdownViewMode.preview, "eye"),
            ])
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var breadcrumbText: some View {
        let components = relativePath.split(separator: "/")
        let lastIndex = components.count - 1
        return HStack(spacing: 6) {
            if components.isEmpty {
                Text("").font(.system(size: 11, design: .monospaced))
            } else {
                ForEach(Array(components.enumerated()), id: \.offset) { (i, comp) in
                    let pathPrefix = components[0...i].joined(separator: "/")
                    Text(String(comp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(i == lastIndex ? theme.color("fg") : theme.color("fg-muted"))
                        .onTapGesture { onRevealInFiles(String(pathPrefix)) }
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() }
                            else { NSCursor.pointingHand.pop() }
                        }
                    if i < lastIndex {
                        Text("/").foregroundColor(theme.color("fg-faint"))
                    }
                }
            }
        }
    }

    private func scheduleRender(immediate: Bool) {
        // No preview is visible in editor-only mode, so skip parsing and
        // rendering entirely. Switching out of editor mode triggers
        // scheduleRender via .onChange(of: resolvedMode).
        guard resolvedMode != .editor else {
            debounceTask?.cancel()
            return
        }
        debounceTask?.cancel()
        let renderIdentity = self.renderIdentity
        let isStandaloneMermaid = self.isStandaloneMermaid
        if !isStandaloneMermaid {
            renderCache.beginRender(for: renderIdentity)
        }
        let buffer = self.buffer
        let theme = self.theme
        let fontFamily = appState.config.code.fontFamily
        let fontSize = appState.config.code.fontSize
        let baseDir = baseDirectory
        // External tabs have no worktree root context, so root-relative
        // paths (`/foo.md`) fall back to system-absolute resolution.
        let worktreeRootOrNil: URL? = externalAbsolutePath == nil ? worktreePath : nil
        debounceTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            let source = buffer.storage.string
            if isStandaloneMermaid {
                mermaidPreviewSource = source
                return
            }
            let parsed = MarkdownParser.parse(source)
            let result = MarkdownRenderer().render(
                document: parsed.document,
                frontmatter: parsed.frontmatter,
                theme: theme,
                monospacedFontFamily: fontFamily,
                monospacedFontSize: fontSize,
                baseDirectory: baseDir,
                worktreeRoot: worktreeRootOrNil
            )
            if Task.isCancelled { return }
            renderCache.storeCompletedRender(result, for: renderIdentity)
        }
    }

    private func invalidateRender() {
        debounceTask?.cancel()
        renderCache.invalidate()
    }

    private func handleLinkClick(_ url: URL) {
        // Anchor-only forms like "#some-heading": dispatch via NotificationCenter.
        // Task 17 wires the observer on MarkdownPreviewController.
        if url.absoluteString.hasPrefix("#") {
            let slug = String(url.absoluteString.dropFirst())
            NotificationCenter.default.post(
                name: .markdownScrollToAnchor,
                object: nil,
                userInfo: ["slug": slug, "tabId": tabId]
            )
            return
        }
        if url.scheme == nil, let fragment = url.fragment, url.host == nil, url.path.isEmpty {
            NotificationCenter.default.post(
                name: .markdownScrollToAnchor,
                object: nil,
                userInfo: ["slug": fragment, "tabId": tabId]
            )
            return
        }
        // Relative file links (no scheme + non-empty path). A path that
        // begins with `/` in an in-worktree document is root-relative to
        // the worktree (e.g. `[link](/README.md)` should land at the repo
        // root). External markdown previews have no worktree-rooted view,
        // so a leading `/` there is genuinely system-absolute and we leave
        // it alone — otherwise `[notes](/Users/me/notes.md)` would be
        // rewritten to `<worktree>/Users/me/notes.md`.
        if url.scheme == nil {
            let path = url.path
            let isInWorktree = externalAbsolutePath == nil
            let candidate: URL
            if path.hasPrefix("/"), isInWorktree {
                candidate = worktreePath.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
            } else if path.hasPrefix("/") {
                candidate = URL(fileURLWithPath: path).standardizedFileURL
            } else {
                candidate = baseDirectory.appendingPathComponent(path).standardizedFileURL
            }
            let worktreeRootPath = worktreePath.standardizedFileURL.path
            if candidate.path.hasPrefix(worktreeRootPath + "/") {
                let relative = String(candidate.path.dropFirst(worktreeRootPath.count + 1))
                appState.openMarkdownLink(
                    worktreeId: worktreeId,
                    worktreeRoot: worktreePath,
                    relativePath: relative
                )
                return
            }
            // Outside the worktree (or external-tab previews where there is
            // no in-worktree containment): hand the RESOLVED candidate to
            // NSWorkspace so neighboring files open via the system handler.
            // Falling through with the raw `url` would try to open
            // "other.md" as if it were system-absolute.
            NSWorkspace.shared.open(candidate)
            return
        }
        NSWorkspace.shared.open(url)
    }
}

extension Notification.Name {
    static let markdownScrollToAnchor = Notification.Name("io.nlopez.alas.markdown.scrollToAnchor")
}

struct MarkdownRenderIdentity: Equatable, Sendable {
    let worktreePath: String
    let tabId: TabID
    let relativePath: String
    let externalAbsolutePath: String?
}

struct MarkdownPreviewCache<Value> {
    private var activeRenderIdentity: MarkdownRenderIdentity?
    private var identity: MarkdownRenderIdentity?
    private var value: Value?

    init() {}

    func value(for currentIdentity: MarkdownRenderIdentity) -> Value? {
        identity == currentIdentity ? value : nil
    }

    mutating func beginRender(for identity: MarkdownRenderIdentity) {
        activeRenderIdentity = identity
    }

    @discardableResult
    mutating func storeCompletedRender(_ value: Value, for identity: MarkdownRenderIdentity) -> Bool {
        guard activeRenderIdentity == identity else { return false }
        self.identity = identity
        self.value = value
        return true
    }

    mutating func invalidate() {
        activeRenderIdentity = nil
        identity = nil
        value = nil
    }
}
